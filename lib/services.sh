#!/usr/bin/env bash
# services.sh - systemd service data collection for `services-info`
#
# Intended to be sourced after common.sh. Strictly read-only: every call
# here queries state (list-units, list-unit-files, show, is-system-running,
# a single bounded journalctl read) and never starts/stops/restarts/
# enables/disables/masks a unit. All parsing uses systemd's
# machine-oriented flags (--plain --no-legend --no-pager, `show -p Key`)
# under LC_ALL=C so output isn't locale-dependent.

# True if systemctl exists and actually responds.
systemd_available() {
    command_exists systemctl && systemctl --version >/dev/null 2>&1
}

# Prints the running systemd version number (e.g. "255"), or "N/A".
get_systemd_version() {
    local out
    out="$(systemctl --version 2>/dev/null | head -n1 | awk '{print $2}')" || true
    printf '%s' "${out:-N/A}"
}

# Prints systemd's own overall state: running | degraded | maintenance |
# starting | stopping | offline | N/A. `is-system-running` legitimately
# exits nonzero for several of these non-error states, so its exit code is
# ignored here.
get_systemd_running_state() {
    local out
    out="$(systemctl is-system-running 2>/dev/null)" || true
    printf '%s' "${out:-N/A}"
}

# One line per currently-loaded service unit (active or inactive):
# unit|load|active|sub|description
get_all_service_units() {
    LC_ALL=C systemctl list-units --type=service --all --no-legend --no-pager --plain 2>/dev/null | \
        awk '{
            unit=$1; load=$2; active=$3; substate=$4
            $1=$2=$3=$4=""
            gsub(/^ +/, "")
            print unit"|"load"|"active"|"substate"|"$0
        }'
}

# One line per currently failed service unit: unit|load|active|sub|description
get_failed_service_units() {
    LC_ALL=C systemctl list-units --type=service --failed --no-legend --no-pager --plain 2>/dev/null | \
        awk '{
            unit=$1; load=$2; active=$3; substate=$4
            $1=$2=$3=$4=""
            gsub(/^ +/, "")
            print unit"|"load"|"active"|"substate"|"$0
        }'
}

# Raw `systemctl show <unit> -p <props>` output (Key=Value lines) for one
# unit. `props` is a comma-separated systemd property list. Prints nothing
# useful for a nonexistent unit beyond LoadState=not-found (systemd itself
# handles that case without erroring).
get_unit_properties() {
    local unit="$1" props="$2"
    [[ -z "$unit" ]] && return 1
    LC_ALL=C systemctl show "$unit" --no-pager -p "$props" 2>/dev/null
}

# Extracts one Key=Value line's value from `get_unit_properties` output.
# Prints empty string if the key is absent.
extract_prop() {
    local kv_text="$1" key="$2"
    awk -F= -v k="$key" '$1==k { sub(/^[^=]*=/, ""); print; exit }' <<<"$kv_text"
}

# True if a unit exists at all (as opposed to LoadState=not-found).
unit_exists() {
    local kv_text="$1"
    [[ "$(extract_prop "$kv_text" LoadState)" != "not-found" ]]
}

# Formats a MainPID value: the numeric PID, or "N/A" for 0/empty/non-numeric
# (systemd reports MainPID=0 for units with no running main process).
format_service_pid() {
    local pid="${1:-}"
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 0 ]]; then
        printf '%s' "$pid"
    else
        printf 'N/A'
    fi
}

# Formats an NRestarts-style value: the count as-is, or "N/A" if the
# property is absent/non-numeric (older systemd, or not applicable).
format_restart_count() {
    local count="${1:-}"
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        printf '%s' "$count"
    else
        printf 'N/A'
    fi
}

# Converts a systemd timestamp (e.g. an ActiveEnterTimestamp value) into a
# human "Xd Xh Xm" duration since then. Prints "N/A" for empty, unparseable,
# or future timestamps rather than guessing.
format_service_uptime() {
    local ts="${1:-}"
    [[ -z "$ts" ]] && { printf 'N/A'; return; }

    local epoch
    epoch="$(LC_ALL=C date -d "$ts" +%s 2>/dev/null)" || { printf 'N/A'; return; }
    [[ -z "$epoch" ]] && { printf 'N/A'; return; }

    local now
    now="$(date +%s)"
    if [[ "$epoch" -gt "$now" ]]; then
        printf 'N/A'
        return
    fi

    local seconds=$(( now - epoch )) days hours mins out=""
    days=$(( seconds / 86400 ))
    hours=$(( (seconds % 86400) / 3600 ))
    mins=$(( (seconds % 3600) / 60 ))
    (( days > 0 )) && out+="${days}d "
    (( days > 0 || hours > 0 )) && out+="${hours}h "
    out+="${mins}m"
    printf '%s' "$out"
}

# Prints a short, bounded, time-limited excerpt of a unit's recent journal
# (plain message text only, oldest of the last N lines first). Returns 1 if
# journalctl is unavailable, times out, or has nothing to show — callers
# should treat that as "no journal excerpt available", not an error.
get_unit_journal_excerpt() {
    local unit="$1" lines="${2:-3}" timeout_secs="${3:-3}"
    command_exists journalctl || return 1
    command_exists timeout || return 1
    local out
    out="$(timeout "$timeout_secs" journalctl -u "$unit" -n "$lines" --no-pager -o cat 2>/dev/null)" || true
    [[ -z "$out" ]] && return 1
    printf '%s\n' "$out"
}
