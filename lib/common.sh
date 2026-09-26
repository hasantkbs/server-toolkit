#!/usr/bin/env bash
# common.sh - shared helpers for server-toolkit
#
# Intended to be sourced by bin/* entry points, not executed directly.

# Return success if the given command is available on PATH.
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Prints server-toolkit's canonical version string, read from the single
# place it's literally assigned (bin/server-toolkit's own TOOLKIT_VERSION
# line - see that file's comment). install.sh reads the same line itself,
# with its own copy of this exact grep/sed pair, since it must stay
# dependency-free from lib/*.sh; any other bin/* script that needs to
# display a version (e.g. bin/tui) should call this function instead of
# defining a second, independently-maintained version constant, so the
# two can never silently drift apart again. Returns non-zero (prints
# nothing) if bin/server-toolkit can't be found relative to this file.
toolkit_version() {
    local self_lib_dir bin_dir version
    self_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)" || return 1
    bin_dir="$(cd -- "${self_lib_dir}/../bin" >/dev/null 2>&1 && pwd -P)" || return 1
    version="$(grep -m1 '^TOOLKIT_VERSION=' "${bin_dir}/server-toolkit" 2>/dev/null | sed -E 's/^TOOLKIT_VERSION="([^"]*)"$/\1/')"
    [[ -n "$version" ]] || return 1
    printf '%s' "$version"
}

# Run a command and print its stdout; on failure print nothing and return 1.
# Usage: if out="$(safe_run some_cmd --flag)"; then ... fi
safe_run() {
    local out
    if out="$("$@" 2>/dev/null)"; then
        printf '%s' "$out"
        return 0
    fi
    return 1
}

# Convert an integer byte count into a human-readable string (KiB/MiB/GiB/...).
# Non-numeric input yields "N/A".
bytes_to_human() {
    local bytes="${1:-}"
    local -a units=(B KiB MiB GiB TiB PiB)
    local i=0
    local value

    if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        printf 'N/A'
        return
    fi

    value="$bytes"
    while (( value >= 1024 && i < ${#units[@]} - 1 )); do
        value=$(( value / 1024 ))
        (( i++ ))
    done

    printf '%d%s' "$value" "${units[$i]}"
}

# Integer percentage of numerator/denominator, e.g. format_percent 40 200 -> "20%".
# Returns "N/A" for non-numeric or zero-denominator input.
format_percent() {
    local numerator="${1:-}"
    local denominator="${2:-}"

    if ! [[ "$numerator" =~ ^[0-9]+$ ]] || ! [[ "$denominator" =~ ^[0-9]+$ ]] || [[ "$denominator" -eq 0 ]]; then
        printf 'N/A'
        return
    fi

    printf '%d%%' $(( numerator * 100 / denominator ))
}

# Print a single-character status glyph for a keyword: ok | warn | bad | (anything else).
status_indicator() {
    case "${1:-}" in
        ok) printf '\xe2\x9c\x93' ;;   # ✓
        warn) printf '\xe2\x9a\xa0' ;; # ⚠
        bad) printf '\xe2\x9c\x97' ;;  # ✗
        *) printf '-' ;;
    esac
}

# Terminal width, defaulting to 80 when not attached to a tty / unknown.
term_width() {
    local cols
    cols="$(tput cols 2>/dev/null)" || cols=""
    if [[ "$cols" =~ ^[0-9]+$ ]]; then
        printf '%d' "$cols"
    else
        printf '80'
    fi
}

# Print a horizontal rule made of the given character (default '─'), capped at 60 columns.
print_rule() {
    local char="${1:-─}"
    local width
    width="$(term_width)"
    (( width > 60 )) && width=60
    local line="" i
    for (( i = 0; i < width; i++ )); do
        line+="$char"
    done
    printf '%s\n' "$line"
}

# Print a section title followed by a rule.
print_header() {
    printf '%s\n' "$1"
    print_rule
}

# Print a label/value row with the label left-padded to a fixed column width.
# Usage: kv "Label" "value" [width]
kv() {
    local label="$1"
    local value="$2"
    local width="${3:-20}"
    printf '%-*s%s\n' "$width" "$label" "$value"
}
