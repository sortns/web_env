#!/bin/bash
### source: https://github.com/ReconXSecurityHQ/highlight

### ANSI collors: https://ansi.gabebanks.net

# For Debian it doesn't really work without:
# apt install gawk

hl() {
    # Detect available awk version and force gawk if present
    if command -v gawk >/dev/null 2>&1; then
        AWK_CMD="gawk"
        AWK_TYPE="gawk"
    elif command -v nawk >/dev/null 2>&1; then
        AWK_CMD="nawk"
        AWK_TYPE="nawk"
    else
        AWK_CMD="awk"
        AWK_TYPE="mawk"  # Defaulting to mawk if awk is found but gawk isn't
    fi

    # Define ANSI colors using `tput`
    RESET=$(tput sgr0)
    CYAN=$(tput setaf 6)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    MAGENTA=$(tput setaf 5)
    RED=$(tput setaf 1)
    BLUE=$(tput setaf 4)

    # Corrected STRIP_ANSI regex to prevent `sed` errors
    STRIP_ANSI='s/\x1B\[[0-9;]*[mK]//g; s/\x1B\(B//g; s/\x1B\][0-9;]*//g'

    # Check if input is provided
    if [ -t 0 ] && [ $# -eq 0 ]; then
        echo "Usage: "
        echo "1. highlight < file"
        echo "2. <command> | highlight"
        return 1
    fi

    # Remove all existing ANSI colors before processing
    sed -E "$STRIP_ANSI" | "$AWK_CMD" -v RESET="$RESET" -v CYAN="$CYAN" -v GREEN="$GREEN" \
      -v YELLOW="$YELLOW" -v MAGENTA="$MAGENTA" -v RED="$RED" -v BLUE="$BLUE" '
    {
        # Highlight IPv4 addresses
        gsub(/([0-9]{1,3}\.){3}[0-9]{1,3}/, RED "&" RESET);

        # IPv6 Handling: Use full regex in gawk, simplified regex otherwise
        if ("'$AWK_TYPE'" == "gawk") {
            gsub(/([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{1,4}/, MAGENTA "&" RESET);
        } else {
            gsub(/[0-9a-fA-F:]+/, MAGENTA "&" RESET);
        }

        # Highlight MAC addresses
        gsub(/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/, YELLOW "&" RESET);

        # Highlight netmask
        gsub(/netmask [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/, YELLOW "&" RESET);

        # Highlight URLs
        gsub(/(https?|ftp|sftp|ssh|telnet|file|git):\/\/[a-zA-Z0-9._-]+/, CYAN "&" RESET);

        # Highlight domains
        gsub(/([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,6}/, MAGENTA "&" RESET);

        # Highlight ports (common formats)
        gsub(/[0-9]+\/(tcp|udp)/, RED "&" RESET);

        # Highlight words followed by a colon (e.g., "Title: something")
        gsub(/[a-zA-Z0-9_-]+:/, CYAN "&" RESET);

        # Highlight text inside parentheses
        gsub(/\([^)]*\)/, YELLOW "&" RESET);

        # Highlight HTML Tags (basic highlight)
        gsub(/<[^<>]+>/, RED "&" RESET);
        gsub(/ [a-zA-Z-]+="[^"]*"/, GREEN "&" RESET);
        gsub(/"[^"]*"/, YELLOW "&" RESET);

        print;
    }'
}
