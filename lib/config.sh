#!/usr/bin/env bash
# config.sh - minimal, safe configuration loader for server-toolkit
#
# Design contract (short version; docs/config.md has the user-facing one):
#   - Config is plain `KEY=VALUE` text, read with bash string/regex
#     operations only. It is never `source`d, `eval`ed, or executed as a
#     script - a value containing `$(...)`, backticks, `;`, or any other
#     shell metacharacter is inert text, nothing more.
#   - Absent, unreadable, or unsafe-permission config -> every lookup
#     falls back to the caller-supplied default. A missing or broken
#     config file is never a hard error for the rest of the toolkit.
#   - This file only ever reads the config path. It never creates,
#     writes, or modifies anything on disk.
#
# Usage (from a bin/* entry point, after sourcing common.sh):
#   source "${LIB_DIR}/config.sh"
#   RAM_ALERT_PCT="$(config_get RAM_ALERT_PCT 90 percentage)"

# Highest CONFIG_VERSION this build understands. A config declaring a
# higher (or otherwise non-matching) version is treated as unusable for
# this build - the whole file is ignored in favor of defaults, rather
# than guessing which keys are still safe to read from an unknown format.
CONFIG_SUPPORTED_VERSION=1

# Sub-directory name under the config root. The project's final name
# isn't locked in yet (see CLAUDE.md) - when it is, this is the one
# constant to change.
CONFIG_APP_NAME="server-toolkit"

# Directory holding the config file. TOOLKIT_CONFIG_DIR overrides it
# entirely; otherwise XDG_CONFIG_HOME (falling back to ~/.config) plus
# CONFIG_APP_NAME. Purely a path computation - never touches the
# filesystem, never creates anything.
config_dir() {
    if [[ -n "${TOOLKIT_CONFIG_DIR:-}" ]]; then
        printf '%s' "${TOOLKIT_CONFIG_DIR}"
        return
    fi
    printf '%s/%s' "${XDG_CONFIG_HOME:-${HOME}/.config}" "$CONFIG_APP_NAME"
}

# Full path to the config file itself (may or may not exist).
config_path() {
    printf '%s/config' "$(config_dir)"
}

# ---------------------------------------------------------- validators ---
# Each takes one value (plus, for "enum" via config_validate, an allowed
# list) and reports valid/invalid via exit status only. They print
# nothing and never touch the filesystem or run other commands.

config_is_integer() {
    [[ "${1:-}" =~ ^-?[0-9]+$ ]]
}

config_is_positive_integer() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [[ "$1" -gt 0 ]]
}

config_is_percentage() {
    [[ "${1:-}" =~ ^[0-9]+$ ]] && [[ "$1" -ge 0 ]] && [[ "$1" -le 100 ]]
}

config_is_boolean() {
    [[ "${1:-}" == "true" || "${1:-}" == "false" ]]
}

config_is_enum() {
    local value="$1" allowed="${2:-}" choice
    local -a choices
    IFS='|' read -r -a choices <<<"$allowed"
    for choice in "${choices[@]}"; do
        [[ "$value" == "$choice" ]] && return 0
    done
    return 1
}

config_is_string() {
    [[ -n "${1:-}" ]]
}

# Validate $1 against type $2 (integer|positive_integer|percentage|
# boolean|enum|string), with $3 as the pipe-separated allowed list when
# $2 is "enum". An unrecognized type is treated as always-invalid, not
# always-valid, so a typo'd type name can't silently disable validation.
config_validate() {
    local value="$1" type="$2" extra="${3:-}"
    case "$type" in
        integer) config_is_integer "$value" ;;
        positive_integer) config_is_positive_integer "$value" ;;
        percentage) config_is_percentage "$value" ;;
        boolean) config_is_boolean "$value" ;;
        enum) config_is_enum "$value" "$extra" ;;
        string) config_is_string "$value" ;;
        *) return 1 ;;
    esac
}
