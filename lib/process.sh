#!/usr/bin/env bash
# process.sh - process inspection data collection for `process-info`
#
# Intended to be sourced after common.sh. Strictly read-only and
# observation-only: a single bounded `ps` snapshot is taken and then
# sliced/sorted/counted locally (awk/sort), with no per-PID subprocess
# spawning and no state-changing command of any kind. Process command text
# obtained from `ps` is treated as plain data - it is only ever printed,
# never evaluated or executed.

ps_available() {
    command_exists ps
}

# The exact ps invocation used for the snapshot below, defined once so the
# self-exclusion filter can never drift out of sync with it.
_PROCESS_SNAPSHOT_PS_ARGS="pid=,ppid=,user=,pcpu=,pmem=,stat=,args="

# One line per process, pipe-delimited: pid|ppid|user|cpu|mem|stat|command
# A single `ps -eo ...` snapshot; the row for the `ps` invocation itself is
# excluded by matching its own known command text. (PID/PPID-based matching
# was tried and abandoned: bash's forking behavior for a substitution
# followed by `|| ...` is not stable enough across shells/versions to
# predict which PID will actually be ps's parent, so matching the exact
# command line - which we control precisely - is the reliable approach.)
# Returns 1 if `ps` is unavailable or produces no output at all.
get_process_snapshot() {
    ps_available || return 1
    local raw
    raw="$(ps -eo "$_PROCESS_SNAPSHOT_PS_ARGS" 2>/dev/null)" || true
    [[ -z "$raw" ]] && return 1
    awk -v self_cmd="ps -eo ${_PROCESS_SNAPSHOT_PS_ARGS}" '
        {
            pid=$1; ppid=$2; user=$3; cpu=$4; mem=$5; stat=$6
            $1=$2=$3=$4=$5=$6=""
            sub(/^ +/, "")
            if (index($0, self_cmd) == 1) next
            print pid"|"ppid"|"user"|"cpu"|"mem"|"stat"|"$0
        }
    ' <<<"$raw"
}

# Prints "total running sleeping stopped zombie" counts from snapshot text
# (as produced by get_process_snapshot). A row with an unrecognized/missing
# STAT value still counts toward total but not toward any of the four
# buckets, so bucket counts can legitimately sum to less than total.
count_process_states() {
    local snapshot="${1:-}"
    if [[ -z "$snapshot" ]]; then
        printf '0 0 0 0 0'
        return
    fi
    awk -F'|' '
        {
            total++
            s = substr($6, 1, 1)
            if (s == "R") running++
            else if (s == "S" || s == "D" || s == "I") sleeping++
            else if (s == "T" || s == "t") stopped++
            else if (s == "Z") zombie++
        }
        END { printf "%d %d %d %d %d", total+0, running+0, sleeping+0, stopped+0, zombie+0 }
    ' <<<"$snapshot"
}

# Top N snapshot rows sorted descending by a 1-based numeric pipe-delimited
# field (4=cpu, 5=mem), still in the pid|ppid|user|cpu|mem|stat|command
# format. Uses `sort` then an awk NR<=n cutoff (not `head`) so the full
# `sort` output is always consumed and no SIGPIPE/pipefail surprises occur.
top_n_by_field() {
    local snapshot="${1:-}" field="$2" n="${3:-5}"
    [[ -z "$snapshot" ]] && return 1
    sort -t'|' -k"${field}","${field}" -rn <<<"$snapshot" | awk -F'|' -v n="$n" 'NR<=n'
}

# Counts snapshot rows whose given 1-based numeric field is >= threshold.
# Malformed/non-numeric values are treated as 0 (never counted).
count_above_threshold() {
    local snapshot="${1:-}" field="$2" threshold="$3"
    if [[ -z "$snapshot" ]]; then
        printf '0'
        return
    fi
    awk -F'|' -v f="$field" -v t="$threshold" '
        { val = $f + 0; if (val >= t) c++ }
        END { printf "%d", c+0 }
    ' <<<"$snapshot"
}

# Splits system.sh's get_load_average() output (e.g. "0.21, 0.23, 0.14", or
# "N/A" when /proc/loadavg is unavailable) into one|five|fifteen. Any part
# that can't be parsed is reported as "N/A" rather than guessed.
parse_load_average() {
    local raw="${1:-}"
    if [[ -z "$raw" || "$raw" == "N/A" ]]; then
        printf 'N/A|N/A|N/A'
        return
    fi
    local one five fifteen
    IFS=',' read -r one five fifteen <<<"$raw"
    one="$(tr -d '[:space:]' <<<"${one:-}")"
    five="$(tr -d '[:space:]' <<<"${five:-}")"
    fifteen="$(tr -d '[:space:]' <<<"${fifteen:-}")"
    printf '%s|%s|%s' "${one:-N/A}" "${five:-N/A}" "${fifteen:-N/A}"
}
