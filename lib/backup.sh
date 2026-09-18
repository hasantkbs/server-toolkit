#!/usr/bin/env bash
# backup.sh - generic, read-only backup discovery/status for `backup-info`
#
# Intended to be sourced after common.sh and lib/services.sh (for
# systemd_available/get_unit_properties/extract_prop). Strictly read-only
# and observation-only: no backup/restore/delete/copy/compress/dump/export
# operation of any kind, and no command discovered in cron/systemd
# configuration is ever executed.
#
# This module is deliberately generic: it does not assume any specific
# backup directory, database, Docker volume, application, host, or
# filename. It only recognizes a small set of FHS/OS-level conventions
# (e.g. /var/backups) and keyword-based discovery (backup/snapshot/dump in
# a unit or cron job name), never anything specific to one server. A future
# sprint may add user-defined backup sources on top of this same "backup
# entry" shape without changing it.
#
# A "backup entry" discovered here is represented as a pipe-delimited row:
#   name|source|location|last_epoch|status_hint|metadata
# where status_hint is the freshness classification computed by the caller
# (this module only supplies data, not policy/thresholds).

BACKUP_KEYWORD_PATTERN='backup|snapshot|dump'

# Colon-separated list of local candidate directories, overridable via
# $BACKUP_LOCAL_CANDIDATES_OVERRIDE (mainly so tests can point discovery at
# an isolated temp directory instead of this host's real /var/backups).
# With no override, the default is just the one FHS-standard location.
if [[ -n "${BACKUP_LOCAL_CANDIDATES_OVERRIDE:-}" ]]; then
    IFS=':' read -ra BACKUP_LOCAL_CANDIDATES <<<"$BACKUP_LOCAL_CANDIDATES_OVERRIDE"
else
    BACKUP_LOCAL_CANDIDATES=(/var/backups)
fi

# ------------------------------------------------------------ TIME/AGE ---

# Converts a systemd-style timestamp string (e.g. from LastTriggerUSec) to
# a Unix epoch. Prints nothing and returns 1 for empty/unparseable input.
backup_timestamp_to_epoch() {
    local ts="${1:-}"
    [[ -z "$ts" ]] && return 1
    LC_ALL=C date -d "$ts" +%s 2>/dev/null
}

# Given a Unix epoch, prints "duration|hours": duration is a human
# "Xd Xh Xm" string, hours is the integer elapsed hours (floored). For an
# empty, non-numeric, or future epoch - a timestamp we cannot reliably
# interpret - prints "N/A|" (empty hours) rather than guessing or treating
# it as stale.
backup_age_from_epoch() {
    local epoch="${1:-}"
    if [[ -z "$epoch" ]] || ! [[ "$epoch" =~ ^[0-9]+$ ]]; then
        printf 'N/A|'
        return
    fi
    local now
    now="$(date +%s)"
    if [[ "$epoch" -gt "$now" ]]; then
        printf 'N/A|'
        return
    fi
    local seconds=$(( now - epoch )) days hours mins hrs_total out=""
    days=$(( seconds / 86400 ))
    hours=$(( (seconds % 86400) / 3600 ))
    mins=$(( (seconds % 3600) / 60 ))
    hrs_total=$(( seconds / 3600 ))
    (( days > 0 )) && out+="${days}d "
    (( days > 0 || hours > 0 )) && out+="${hours}h "
    out+="${mins}m"
    printf '%s|%s' "$out" "$hrs_total"
}

# ------------------------------------------------------- SYSTEMD TIMERS ---

# One line per systemd timer whose UNIT NAME contains a backup-related
# keyword (backup/snapshot/dump, case-insensitive): unit|load|active|sub|description
# This is an observation only - a name match is not proof the timer
# performs a real backup, and its unit is never started/stopped/executed.
# Returns 1 if systemd is unavailable or no matching timer exists.
get_backup_related_timers() {
    systemd_available || return 1
    local lines
    lines="$(LC_ALL=C systemctl list-units --type=timer --all --no-legend --no-pager --plain 2>/dev/null | awk '
        {
            unit=$1; load=$2; active=$3; substate=$4
            $1=$2=$3=$4=""
            gsub(/^ +/, "")
            print unit"|"load"|"active"|"substate"|"$0
        }
    ')" || true
    [[ -z "$lines" ]] && return 1

    local matched
    matched="$(grep -iE "^[^|]*(${BACKUP_KEYWORD_PATTERN})[^|]*\|" <<<"$lines")" || true
    [[ -z "$matched" ]] && return 1
    printf '%s\n' "$matched"
}

# --------------------------------------------------------------- CRON ---

# Internal: parses one crontab-style line. `skip_fields` is 5 for a user
# crontab (min hour dom mon dow command...) or 6 for a system-style
# crontab/cron.d file (min hour dom mon dow user command...). On a
# backup-related match, sets $REPLY to "schedule|command_summary|source"
# and returns 0; otherwise returns 1. The command summary is only ever the
# base name of the first token (the executable) - arguments, redirections,
# and anything after them (a common place for secrets/paths to leak) are
# never included or displayed.
_backup_parse_cron_line() {
    local line="$1" skip_fields="$2" source_label="$3"
    REPLY=""
    [[ -z "$line" ]] && return 1
    [[ "$line" =~ ^[[:space:]]*# ]] && return 1
    [[ "$line" =~ ^[[:space:]]*$ ]] && return 1
    [[ "$line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*= ]] && return 1

    local -a fields
    read -ra fields <<<"$line"
    [[ "${#fields[@]}" -le "$skip_fields" ]] && return 1

    local schedule="${fields[0]} ${fields[1]} ${fields[2]} ${fields[3]} ${fields[4]}"
    local command="${fields[*]:$skip_fields}"
    grep -qiE "${BACKUP_KEYWORD_PATTERN}" <<<"$command" || return 1

    local first_token="${fields[$skip_fields]}"
    local summary="${first_token##*/}"

    REPLY="${schedule}|${summary}|${source_label}"
    return 0
}

# One line per backup-related cron entry found: schedule|command_summary|source
# Reads the invoking user's own crontab (`crontab -l`) plus /etc/crontab and
# /etc/cron.d/* when readable - standard, generic cron locations, not
# anything specific to one application. Never executes anything found.
# Returns 1 if crontab is unavailable or nothing matches.
get_backup_related_cron_entries() {
    local out="" line

    if command_exists crontab; then
        local user_cron
        user_cron="$(crontab -l 2>/dev/null)" || true
        if [[ -n "$user_cron" ]]; then
            while IFS= read -r line; do
                _backup_parse_cron_line "$line" 5 "user crontab" && out+="${REPLY}"$'\n'
            done <<<"$user_cron"
        fi
    fi

    if [[ -r /etc/crontab ]]; then
        while IFS= read -r line; do
            _backup_parse_cron_line "$line" 6 "/etc/crontab" && out+="${REPLY}"$'\n'
        done < /etc/crontab
    fi

    local f
    for f in /etc/cron.d/*; do
        [[ -f "$f" && -r "$f" ]] || continue
        while IFS= read -r line; do
            _backup_parse_cron_line "$line" 6 "${f}" && out+="${REPLY}"$'\n'
        done < "$f"
    done

    [[ -z "$out" ]] && return 1
    printf '%s' "$out"
}

# ---------------------------------------------------------- LOCAL FILES ---

# One line per candidate backup directory that actually contains files:
# directory|newest_filename|mtime_epoch
# Only checks a small, fixed set of generic/FHS-standard locations
# (/var/backups, and the invoking user's own ~/backups or ~/.backups) -
# never a whole-filesystem scan, never anything specific to one server.
# Each check is a single, depth-limited (-maxdepth 2), time-bounded,
# symlink-excluding `find` call - never one process per file. Returns 1 if
# no candidate directory exists or none contain any files.
get_local_backup_candidates() {
    local timeout_secs="${1:-3}"
    command_exists find || return 1

    local -a candidates=("${BACKUP_LOCAL_CANDIDATES[@]}")
    [[ -n "${HOME:-}" ]] && candidates+=("${HOME}/backups" "${HOME}/.backups")

    local dir results=""
    for dir in "${candidates[@]}"; do
        [[ -d "$dir" ]] || continue

        local raw
        if command_exists timeout; then
            raw="$(timeout "$timeout_secs" find "$dir" -maxdepth 2 -type f -not -type l \
                -printf '%T@|%p\n' 2>/dev/null)" || true
        else
            raw="$(find "$dir" -maxdepth 2 -type f -not -type l -printf '%T@|%p\n' 2>/dev/null)" || true
        fi
        [[ -z "$raw" ]] && continue

        local newest mtime path
        newest="$(sort -t'|' -k1,1 -rn <<<"$raw" | awk -F'|' 'NR==1')"
        [[ -z "$newest" ]] && continue
        IFS='|' read -r mtime path <<<"$newest"
        mtime="${mtime%%.*}"

        results+="${dir}|${path##*/}|${mtime}"$'\n'
    done

    [[ -z "$results" ]] && return 1
    printf '%s' "$results"
}
