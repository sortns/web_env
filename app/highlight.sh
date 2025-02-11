#!/bin/bash
### source: https://github.com/ReconXSecurityHQ/highlight

### ANSI collors: https://ansi.gabebanks.net

# For Debian it doesn't really work without:
# apt install gawk

hl() {
    # Detect available awk version; prefer gawk if available
    if command -v gawk >/dev/null 2>&1; then
        AWK_CMD="gawk"
        AWK_TYPE="gawk"
    elif command -v nawk >/dev/null 2>&1; then
        AWK_CMD="nawk"
        AWK_TYPE="nawk"
    else
        AWK_CMD="awk"
        AWK_TYPE="mawk"  # Defaulting to mawk if gawk isn't available
    fi

    # Define ANSI colors using tput
    RESET=$(tput sgr0)
    CYAN=$(tput setaf 6)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    MAGENTA=$(tput setaf 5)
    RED=$(tput setaf 1)
    BLUE=$(tput setaf 4)

    # Use a literal escape character (instead of \x1B) in the regex.
    ESC=$'\033'
    # The STRIP_ANSI regex now:
    #  • removes CSI sequences: ESC [ ... ending in m or K,
    #  • removes charset reset sequences: ESC (B,
    #  • removes OSC sequences: ESC ] ...,
    #  • and also strips any stray literal "(B"
    STRIP_ANSI="s/${ESC}\[[0-9;]*[mK]//g; s/${ESC}\(B//g; s/${ESC}\][0-9;]*//g; s/\(B//g"

    # Check if input is provided
    if [ -t 0 ] && [ $# -eq 0 ]; then
        echo "Usage:"
        echo "  highlight < file"
        echo "  <command> | highlight"
        return 1
    fi

    # Remove all ANSI codes before processing.
    sed -E "$STRIP_ANSI" | "$AWK_CMD" \
        -v RESET="$RESET" -v CYAN="$CYAN" -v GREEN="$GREEN" \
        -v YELLOW="$YELLOW" -v MAGENTA="$MAGENTA" -v RED="$RED" -v BLUE="$BLUE" '
    {
        # Highlight IPv4 addresses
        gsub(/([0-9]{1,3}\.){3}[0-9]{1,3}/, RED "&" RESET);

        # IPv6 Handling: Use full regex in gawk; otherwise simplified version
        if ("'"$AWK_TYPE"'" == "gawk") {
            gsub(/([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{1,4}/, MAGENTA "&" RESET);
        } else {
            gsub(/[0-9a-fA-F:]+/, MAGENTA "&" RESET);
        }

        # Highlight MAC addresses
        gsub(/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/, YELLOW "&" RESET);

        # Highlight netmask lines
        gsub(/netmask [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/, YELLOW "&" RESET);

        # Highlight URLs
        gsub(/(https?|ftp|sftp|ssh|telnet|file|git):\/\/[a-zA-Z0-9._-]+/, CYAN "&" RESET);

        # Highlight domains
        gsub(/([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,6}/, MAGENTA "&" RESET);

        # Highlight ports (common formats)
        gsub(/[0-9]+\/(tcp|udp)/, RED "&" RESET);

        # (The original functionality that highlighted words ending with a colon has been removed.)

        # Highlight text inside parentheses
        gsub(/\([^)]*\)/, YELLOW "&" RESET);

        # Highlight HTML tags (basic highlighting)
        gsub(/<[^<>]+>/, RED "&" RESET);
        gsub(/ [a-zA-Z-]+="[^"]*"/, GREEN "&" RESET);
        gsub(/"[^"]*"/, YELLOW "&" RESET);

        print;
    }'
}
