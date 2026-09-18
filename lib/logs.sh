#!/usr/bin/env bash
# logs.sh - bounded journal/log health summary for `logs-info`
#
# Intended to be sourced after common.sh. Strictly read-only: every call is
# a single, time-window-bounded, timeout-wrapped `journalctl` read (never
# --vacuum-*/--rotate/--flush, never a write). Journal message text is
# treated as plain data - only ever printed, never evaluated or executed.
#
# Four separate journalctl calls are used (errors, warnings, recent events,
# kernel events) rather than one, because each needs an incompatible
# combination of flags: the two counts use the cheap `-o cat | wc -l` form
# with different `-p` priority ranges, recent events needs structured `-o
# json` (to get priority/unit/timestamp fields, not just message text), and
# the kernel count additionally needs `-k` to restrict to the kernel
# transport. Each call is independently bounded by --since and a hard
# timeout, so a hang in one never blocks the others indefinitely.

# Default recent-log time window, expressed the way journalctl's --since
# accepts it.
LOGS_DEFAULT_SINCE="24 hours ago"

journalctl_available() {
    command_exists journalctl || return 1
    if command_exists timeout; then
        timeout 2 journalctl --version >/dev/null 2>&1
    else
        journalctl --version >/dev/null 2>&1
    fi
}

# Prints the count of journal entries within `since` whose priority falls in
# `priority_range` (a journalctl -p value, e.g. "err..emerg" or
# "warning..warning"). Returns 1 (caller should show N/A) if journalctl is
# unavailable, times out, or errors; a genuine zero-match result prints "0".
get_journal_level_count() {
    local priority_range="$1" since="${2:-$LOGS_DEFAULT_SINCE}" timeout_secs="${3:-2}"
    command_exists journalctl || return 1
    command_exists timeout || return 1

    local out rc=0
    out="$(timeout "$timeout_secs" journalctl --since "$since" -p "$priority_range" \
        --no-pager -o cat 2>/dev/null)" || rc=$?

    [[ "$rc" -ne 0 ]] && return 1
    [[ -z "$out" ]] && { printf '0'; return 0; }
    wc -l <<<"$out" | tr -d '[:space:]'
}

# Prints the count of kernel-sourced (-k) journal entries within `since` at
# warning level or more severe. Returns 1 (N/A) if journalctl/the kernel
# log is unavailable (including permission-denied), times out, or errors.
get_kernel_event_count() {
    local since="${1:-$LOGS_DEFAULT_SINCE}" timeout_secs="${2:-2}"
    command_exists journalctl || return 1
    command_exists timeout || return 1

    local out rc=0
    out="$(timeout "$timeout_secs" journalctl -k --since "$since" -p warning..emerg \
        --no-pager -o cat 2>/dev/null)" || rc=$?

    [[ "$rc" -ne 0 ]] && return 1
    [[ -z "$out" ]] && { printf '0'; return 0; }
    wc -l <<<"$out" | tr -d '[:space:]'
}

# One line per recent warning-or-worse journal entry, pipe-delimited:
# timestamp|unit|priority|message (message has embedded newlines/tabs
# collapsed to spaces so it can never break line-based parsing). Defensively
# re-capped to at most `max_n` lines in bash (on top of journalctl's own -n
# tail-style limiting), so a misbehaving source can never make this
# unbounded. Formatted entirely within a single jq process (no per-event
# subprocess). Returns 1 if journalctl/jq is unavailable, times out, or the
# journalctl query itself errors; a jq parse failure on malformed input
# (e.g. one bad line among otherwise-valid ones) is not fatal - whatever jq
# managed to parse before/around it is still returned, with a 0 (success)
# status, since journalctl itself already succeeded at that point.
get_recent_journal_events() {
    local since="${1:-$LOGS_DEFAULT_SINCE}" max_n="${2:-10}" timeout_secs="${3:-3}"
    command_exists journalctl || return 1
    command_exists jq || return 1
    command_exists timeout || return 1

    local raw rc=0
    raw="$(timeout "$timeout_secs" journalctl --since "$since" -p warning..emerg \
        -n "$max_n" --no-pager -o json 2>/dev/null)" || rc=$?

    [[ "$rc" -ne 0 ]] && return 1
    [[ -z "$raw" ]] && return 0

    local parsed jq_rc=0
    parsed="$(jq -r '
        ( (.MESSAGE // "") | if type == "array" then "(binary data)" else tostring end ) as $msg
        | ((.__REALTIME_TIMESTAMP // "0") | tonumber / 1000000 | floor) as $epoch
        | ((.PRIORITY // "7") | tonumber) as $prio
        | (["emerg","alert","crit","err","warning","notice","info","debug"][$prio] // "-") as $prioname
        | [
            ($epoch | strftime("%Y-%m-%d %H:%M:%S")),
            (._SYSTEMD_UNIT // .SYSLOG_IDENTIFIER // "-"),
            $prioname,
            ($msg | gsub("[\n\r\t]"; " "))
          ] | join("|")
    ' <<<"$raw" 2>/dev/null)" || jq_rc=$?

    if [[ -z "$parsed" ]]; then
        # jq produced nothing: distinguish "genuinely nothing to report" (jq
        # itself ran fine) from "jq is broken/unusable" (report N/A instead
        # of silently claiming a quiet window).
        [[ "$jq_rc" -ne 0 ]] && return 1
        return 0
    fi
    awk -v n="$max_n" 'NR<=n' <<<"$parsed"
    return 0
}

# Truncates text to at most max_len characters, appending "..." when
# shortened, for safe/bounded terminal display. Pure string manipulation -
# no subprocess.
truncate_text() {
    local text="${1:-}" max_len="${2:-80}"
    if [[ "${#text}" -gt "$max_len" ]]; then
        printf '%s...' "${text:0:$((max_len - 3))}"
    else
        printf '%s' "$text"
    fi
}
