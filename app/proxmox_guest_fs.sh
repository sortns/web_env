#!/usr/bin/env bash
# proxmox_guest_fs — check / repair guest filesystems of a STOPPED Proxmox VM (qm) or CT (pct) from the host.
# Run: proxmox_guest_fs.sh -h

set -uo pipefail

usage() {
  printf '%s\n' \
    '🩺 proxmox_guest_fs — check / repair guest filesystems of a STOPPED Proxmox VM (qm) or CT (pct) from the host' \
    '' \
    '📖 Usage:' \
    '  proxmox_guest_fs check  ID' \
    '  proxmox_guest_fs repair ID [--allow-zero-log] [--no-snapshot] [--start]' \
    '  proxmox_guest_fs -h | --help' \
    '' \
    '📝 Modes:' \
    '  check             Attach disks, replay journals (mount/umount), run read-only checks.' \
    '                    Nothing is repaired, but journal replay itself writes to the guest FS' \
    '                    (same as a normal boot would).' \
    '  repair            Take a PVE snapshot (qm/pct snapshot) first, then repair.' \
    '' \
    '⚙️  Options (repair):' \
    '  --allow-zero-log  Allow "xfs_repair -L" when the XFS log cannot be replayed' \
    '                    (loses the last metadata changes).' \
    '  --no-snapshot     Proceed even if the storage cannot snapshot (NO rollback possible).' \
    '  --start           Start the guest if every filesystem ends up clean.' \
    '' \
    '💾 Supported:' \
    '  Storages:  anything "pvesm path" resolves to a block device (LVM, LVM-thin, ZFS zvol),' \
    '             raw files, qcow2/vmdk (qemu-nbd), Ceph RBD (rbd map).' \
    '  Layout:    partitions, guest LVM (activated by VG UUID).' \
    '  FS:        xfs, ext2/3/4, vfat (repair); btrfs (read-only check only).' \
    '             NTFS, LUKS, ZFS subvols: skipped.' \
    '' \
    '🌱 Env:' \
    '  XFS_REPAIR_ALT    Newer xfs_repair used if the system one crashes.' \
    '                    Default: /root/xfsprogs/repair/xfs_repair' \
    '' \
    '📂 Logs: /root/fsrepair/ID/YYYYmmdd-HHMMSS/ (summary.txt + per-device logs)' \
    '' \
    '💡 Examples:' \
    '  proxmox_guest_fs check 101' \
    '  proxmox_guest_fs repair 101 --start' \
    '  proxmox_guest_fs repair 205 --allow-zero-log' \
    '' \
    '⚠️  Run as root on the node that owns the guest; the guest must be stopped.'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi

MODE=${1:-}; ID=${2:-}
if (( $# >= 2 )); then shift 2; else set --; fi
ALLOW_L=0; NOSNAP=0; START=0
for a in "$@"; do
  case $a in
    --allow-zero-log) ALLOW_L=1 ;;
    --no-snapshot)    NOSNAP=1 ;;
    --start)          START=1 ;;
    *) echo "❌ unknown option: $a"; echo "ℹ️  Run: proxmox_guest_fs -h"; exit 2 ;;
  esac
done
if [[ ! $MODE =~ ^(check|repair)$ || ! $ID =~ ^[0-9]+$ ]]; then
  usage; exit 2
fi
[ "$(id -u)" = 0 ] || { echo "❌ run as root"; exit 1; }

XFS_ALT=${XFS_REPAIR_ALT:-/root/xfsprogs/repair/xfs_repair}
LOG=/root/fsrepair/$ID/$(date +%Y%m%d-%H%M%S); mkdir -p "$LOG"
MNT=$(mktemp -d /mnt/fsrepair.XXXXXX)
LOOPS=(); NBDS=(); RBDS=(); GVG_UUIDS=(); TOPDEVS=(); FSDEVS=()
OK=1; RET=""

say() { echo "$*" | tee -a "$LOG/summary.txt"; }

cleanup() {
  mountpoint -q "$MNT" && umount "$MNT"
  rmdir "$MNT" 2>/dev/null
  local x
  for x in "${GVG_UUIDS[@]}"; do vgchange -an --select "vg_uuid=$x" >/dev/null 2>&1; done
  for x in "${LOOPS[@]}"; do losetup -d "$x" 2>/dev/null; done
  for x in "${NBDS[@]}";  do qemu-nbd -d "$x" >/dev/null 2>&1; done
  for x in "${RBDS[@]}";  do rbd unmap "$x" 2>/dev/null; done
  GVG_UUIDS=(); LOOPS=(); NBDS=(); RBDS=()
}
trap cleanup EXIT

# ---------- guest type & state ----------
if qm config "$ID" >/dev/null 2>&1; then
  T=qm;  DISKRE='^(scsi|virtio|sata|ide)[0-9]+:'
elif pct config "$ID" >/dev/null 2>&1; then
  T=pct; DISKRE='^(rootfs|mp[0-9]+):'
else
  echo "❌ no VM/CT with id $ID"; exit 1
fi
if [ "$($T status "$ID" | awk '{print $2}')" != stopped ]; then
  echo "⛔ $T $ID is running — shut it down first:  $T shutdown $ID"; exit 1
fi
say "#### $T $ID  mode=$MODE  logs=$LOG"

# ---------- snapshot ----------
if [ "$MODE" = repair ] && [ $NOSNAP = 0 ]; then
  SNAP=fsrepair_$(date +%Y%m%d_%H%M%S)
  if $T snapshot "$ID" "$SNAP" --description "before proxmox_guest_fs" >"$LOG/snapshot.log" 2>&1; then
    say "📸 snapshot: $SNAP   rollback: $T rollback $ID $SNAP   drop: $T delsnapshot $ID $SNAP"
  else
    echo "❌ snapshot failed (see $LOG/snapshot.log). Use --no-snapshot to proceed WITHOUT rollback."; exit 1
  fi
fi

# ---------- attach disks ----------
attach() {  # $1 = volid ; sets RET to a block device ; rc 0 ok, 1 error, 2 skip
  local v=$1 p n img
  p=$(pvesm path "$v" 2>/dev/null) || { say "!! cannot resolve $v"; return 1; }
  if [[ $p == rbd:* ]]; then
    img=${p#rbd:}; img=${img%%:*}
    p=$(rbd map "$img" 2>>"$LOG/attach.err") || { say "!! rbd map $img failed"; return 1; }
    RBDS+=("$p")
  fi
  [[ $p == /dev/* && ! -e $p ]] && lvchange -ay "${p#/dev/}" >/dev/null 2>&1
  if [ -d "$p" ]; then say "skip $v: directory/subvol ($p) — no fsck needed (ZFS: use zpool scrub)"; return 2; fi
  if [[ -f $p && $p =~ \.(qcow2|vmdk)$ ]]; then
    modprobe nbd max_part=16 2>/dev/null
    for n in /dev/nbd{0..15}; do
      [ "$(cat /sys/block/${n#/dev/}/size 2>/dev/null)" = 0 ] && break
    done
    qemu-nbd -c "$n" -f "${p##*.}" "$p" 2>>"$LOG/attach.err" || { say "!! qemu-nbd $p failed"; return 1; }
    NBDS+=("$n"); RET=$n; return 0
  fi
  if [ -b "$p" ] || [ -f "$p" ]; then
    RET=$(losetup -fP --show "$p" 2>>"$LOG/attach.err") || { say "!! losetup $p failed"; return 1; }
    LOOPS+=("$RET"); return 0
  fi
  say "!! $v -> $p: not a block device or file"; return 1
}

while IFS= read -r line; do
  key=${line%%:*}; val=${line#*: }; volid=${val%%,*}
  [[ $val == *media=cdrom* || $volid == none ]] && continue
  [[ $volid == /* ]] && { say "skip $key: bind mount $volid"; continue; }
  attach "$volid"; rc=$?
  [ $rc = 1 ] && { OK=0; continue; }
  [ $rc = 2 ] && continue
  say "attached $key ($volid) -> $RET"; TOPDEVS+=("$RET")
done < <($T config "$ID" | grep -E "$DISKRE")

[ ${#TOPDEVS[@]} -eq 0 ] && { say "nothing to check"; exit $(( OK ? 0 : 1 )); }

udevadm settle 2>/dev/null; sleep 1
for d in "${TOPDEVS[@]}"; do
  FSDEVS+=("$d")
  for p in "$d"p*; do [ -b "$p" ] && FSDEVS+=("$p"); done
done

# ---------- guest LVM (by UUID, all disks already attached) ----------
vgscan >/dev/null 2>&1
mapfile -t UUIDS < <(pvs --noheadings -o vg_uuid "${FSDEVS[@]}" 2>/dev/null | awk 'NF{print $1}' | sort -u)
for u in "${UUIDS[@]}"; do
  name=$(vgs --noheadings -o vg_name --select "vg_uuid=$u" 2>/dev/null | awk '{print $1}')
  same=$(vgs --noheadings -o vg_name 2>/dev/null | awk -v n="$name" '$1==n' | wc -l)
  if [ "$same" -gt 1 ]; then
    say "!! guest VG '$name' collides with an existing VG on the host — skipped (detach others or vgimportclone)"; OK=0; continue
  fi
  if vgchange -ay --select "vg_uuid=$u" >>"$LOG/lvm.log" 2>&1; then
    GVG_UUIDS+=("$u"); say "guest VG: $name"
    mapfile -t -O "${#FSDEVS[@]}" FSDEVS < <(lvs --noheadings -o lv_path --select "vg_uuid=$u" | awk 'NF{print $1}')
  else
    say "!! cannot activate guest VG $name (partial? see $LOG/lvm.log)"; OK=0
  fi
done

# ---------- helpers ----------
xprob() { xfs_repair -n "$1" 2>&1 | grep -ciE 'would|mismatch|corrupt|disconnected inode [0-9]|bad '; }

lfcount() {  # $1 dev, $2 fs
  local opt=ro; [ "$2" = xfs ] && opt=ro,nouuid
  if mount -o "$opt" "$1" "$MNT" 2>/dev/null; then
    find "$MNT/lost+found" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l; umount "$MNT"
  else echo "n/a"; fi
}

xrun() {  # $1 dev, $2 extra flag ; retries on crash/fatal
  local d=$1 fl=$2 b rc; b=$(basename "$d")
  xfs_repair $fl "$d" >"$LOG/xfs_$b.log" 2>&1; rc=$?
  if [ $rc -ne 0 ] || grep -q 'fatal error' "$LOG/xfs_$b.log"; then
    say "    xfs_repair rc=$rc, retry with -P"
    xfs_repair -P $fl "$d" >"$LOG/xfs_${b}_P.log" 2>&1; rc=$?
    if { [ $rc -ne 0 ] || grep -q 'fatal error' "$LOG/xfs_${b}_P.log"; } && [ -x "$XFS_ALT" ]; then
      say "    still failing, retry with $XFS_ALT"
      "$XFS_ALT" -P $fl "$d" >"$LOG/xfs_${b}_alt.log" 2>&1; rc=$?
    fi
  fi
  return $rc
}

do_xfs() {
  local d=$1 b n mounted=1; b=$(basename "$d")
  if mount -o nouuid "$d" "$MNT" 2>"$LOG/mount_$b.err"; then umount "$MNT"
  else mounted=0; dmesg | tail -20 >"$LOG/dmesg_$b.txt"; fi
  n=$(xprob "$d")
  if [ $mounted = 1 ] && [ "$n" = 0 ]; then say "=== $d xfs: clean"; return; fi
  say "=== $d xfs: mount=$([ $mounted = 1 ] && echo ok || echo FAILED) problems=$n"
  if [ $mounted = 0 ] && [ "$n" = 0 ]; then
    say "    mount fails but metadata looks clean — NOT touching it. See $LOG/mount_$b.err, $LOG/dmesg_$b.txt"
    say "    (unsupported XFS features on host kernel? duplicate UUID? external log?)"; OK=0; return
  fi
  [ "$MODE" = check ] && { OK=0; return; }
  local fl=""
  if [ $mounted = 0 ]; then
    [ $ALLOW_L = 1 ] || { say "    log cannot be replayed — rerun with --allow-zero-log to use xfs_repair -L"; OK=0; return; }
    fl=-L
  fi
  xrun "$d" "$fl"
  n=$(xprob "$d")
  if [ "$n" = 0 ]; then say "    FIXED, lost+found: $(lfcount "$d" xfs)"
  else say "    STILL BROKEN: $n problems, logs in $LOG"; OK=0; fi
}

do_ext() {
  local d=$1 b rc; b=$(basename "$d")
  mount "$d" "$MNT" 2>/dev/null && umount "$MNT"      # journal replay
  e2fsck -fn "$d" >"$LOG/fsck_${b}_n.log" 2>&1; rc=$?
  if [ $rc = 0 ]; then say "=== $d $2: clean"; return; fi
  say "=== $d $2: e2fsck -n rc=$rc"
  [ "$MODE" = check ] && { OK=0; return; }
  e2fsck -fy "$d" >"$LOG/fsck_$b.log" 2>&1; rc=$?
  if e2fsck -fn "$d" >/dev/null 2>&1; then say "    FIXED (rc=$rc), lost+found: $(lfcount "$d" ext)"
  else say "    STILL BROKEN (rc=$rc), log: $LOG/fsck_$b.log"; OK=0; fi
}

do_vfat() {
  local d=$1 b rc; b=$(basename "$d")
  command -v fsck.vfat >/dev/null || { say "=== $d vfat: skipped (dosfstools missing)"; return; }
  fsck.vfat -n "$d" >"$LOG/vfat_${b}_n.log" 2>&1; rc=$?
  if [ $rc = 0 ]; then say "=== $d vfat: clean"; return; fi
  say "=== $d vfat: rc=$rc"
  [ "$MODE" = check ] && { OK=0; return; }
  fsck.vfat -a "$d" >"$LOG/vfat_$b.log" 2>&1
  fsck.vfat -n "$d" >/dev/null 2>&1 && say "    FIXED" || { say "    STILL BROKEN"; OK=0; }
}

# ---------- main ----------
for dev in "${FSDEVS[@]}"; do
  fs=$(blkid -s TYPE -o value "$dev" 2>/dev/null)
  case $fs in
    xfs)            do_xfs "$dev" ;;
    ext2|ext3|ext4) do_ext "$dev" "$fs" ;;
    vfat)           do_vfat "$dev" ;;
    btrfs)          btrfs check --readonly "$dev" >"$LOG/btrfs_$(basename "$dev").log" 2>&1 \
                      && say "=== $dev btrfs: clean" || { say "=== $dev btrfs: ERRORS (read-only check only, repair manually)"; OK=0; } ;;
    ""|swap|LVM2_member) ;;
    *)              say "=== $dev $fs: skipped" ;;
  esac
done

cleanup; trap - EXIT
if [ $OK = 1 ]; then
  say "#### ✅ $T $ID: ALL CLEAN"
  [ $START = 1 ] && $T start "$ID" && say "▶️  started $ID"
  exit 0
else
  say "#### ❌ $T $ID: PROBLEMS — guest left stopped. Logs: $LOG"
  exit 1
fi
