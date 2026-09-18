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

# -------------------------------------------------------------- loading ---

# shellcheck disable=SC2034 # written here, read via config_get below
declare -gA CONFIG=()
CONFIG_LOADED=0

# Parses one "KEY=VALUE" line. Prints "KEY<TAB>VALUE" and returns success
# for a recognizable line; returns failure (prints nothing) for a blank
# line, a comment, or anything that doesn't match the KEY=VALUE shape -
# callers skip those rather than treating them as an error, so one
# malformed line never breaks the rest of the file. Pure string
# extraction: VALUE is never evaluated, expanded, or executed.
_config_parse_line() {
    local line="$1" key value
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && return 1
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || return 1
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ "$value" == \"*\" && "${#value}" -ge 2 ]]; then
        value="${value:1:-1}"
    elif [[ "$value" == \'*\' && "${#value}" -ge 2 ]]; then
        value="${value:1:-1}"
    fi
    printf '%s\t%s\n' "$key" "$value"
}

# A config file is only trusted if it's owned by the user running the
# toolkit and isn't writable by group or other - the same principle as a
# tool refusing a world-writable known_hosts/config. Follows symlinks
# (via -L) so a "safe-looking" symlink can't point at someone else's file.
_config_permissions_safe() {
    local path="$1" owner mode
    read -r owner mode < <(stat -L -c '%u %a' -- "$path" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [[ "$owner" == "$(id -u)" ]] || return 1
    local group_bit="${mode: -2:1}" other_bit="${mode: -1}"
    (( (group_bit & 2) == 0 )) || return 1
    (( (other_bit & 2) == 0 )) || return 1
    return 0
}

# Populates the CONFIG associative array from the resolved config path.
# Idempotent per-process (a no-op after the first call) so repeated
# config_get calls don't re-read the file. Never fails the caller: on any
# problem (missing file, unsafe permissions, unreadable, unsupported
# version) it just leaves CONFIG empty and returns 0, so config_get's
# default-fallback path takes over uniformly for every key.
load_config() {
    [[ "$CONFIG_LOADED" -eq 1 ]] && return 0
    CONFIG_LOADED=1

    local path
    path="$(config_path)"
    [[ -f "$path" ]] || return 0

    if ! _config_permissions_safe "$path"; then
        printf 'server-toolkit: config at %s is not owned by you or is writable by others - ignoring it and using defaults\n' "$path" >&2
        return 0
    fi

    local content
    if ! content="$(cat -- "$path" 2>/dev/null)"; then
        printf 'server-toolkit: config at %s could not be read - using defaults\n' "$path" >&2
        return 0
    fi

    local line parsed key value version_seen=""
    while IFS= read -r line; do
        parsed="$(_config_parse_line "$line")" || continue
        key="${parsed%%$'\t'*}"
        value="${parsed#*$'\t'}"
        [[ "$key" == "CONFIG_VERSION" ]] && version_seen="$value"
        CONFIG["$key"]="$value"
    done <<<"$content"

    if [[ -n "$version_seen" ]] && [[ "$version_seen" != "$CONFIG_SUPPORTED_VERSION" ]]; then
        printf 'server-toolkit: config declares CONFIG_VERSION=%s, this build supports %s - ignoring config and using defaults\n' \
            "$version_seen" "$CONFIG_SUPPORTED_VERSION" >&2
        CONFIG=()
    fi
}

# Looks up KEY, falling back to DEFAULT when the key is absent, empty, or
# fails validation for TYPE (default "string"). ENUM is the
# pipe-separated allowed-value list, used only when TYPE is "enum".
# Loads the config on first call; every bin/* entry point is expected to
# call this rather than reading the CONFIG array directly.
config_get() {
    local key="$1" default="$2" type="${3:-string}" enum="${4:-}"
    load_config

    local value="${CONFIG[$key]:-}"
    if [[ -z "$value" ]]; then
        printf '%s' "$default"
        return
    fi

    if config_validate "$value" "$type" "$enum"; then
        printf '%s' "$value"
    else
        printf 'server-toolkit: config key %s=%q is invalid for type "%s" - using default %q\n' \
            "$key" "$value" "$type" "$default" >&2
        printf '%s' "$default"
    fi
}
