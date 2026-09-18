#!/usr/bin/env bash
# security.sh - security posture data collection for `security-info`
#
# Intended to be sourced after common.sh, lib/services.sh (for
# get_unit_properties/extract_prop/unit_exists) and lib/network.sh (for
# get_listening_ports). Strictly read-only: `ufw status`, `fail2ban.service`
# status via systemd, socket-based listener enumeration, and one bounded
# journalctl read. Nothing here ever changes a firewall rule, jail, service
# state, or file permission.

# ------------------------------------------------------------------- UFW ---

ufw_installed() {
    command_exists ufw
}

# Raw `ufw status verbose` output, or empty (return 1) if unavailable,
# uninstalled, or inaccessible (e.g. permission denied as non-root).
get_ufw_status_raw() {
    ufw_installed || return 1
    local out rc=0
    out="$(ufw status verbose 2>/dev/null)" || rc=$?
    [[ "$rc" -ne 0 ]] && return 1
    [[ -z "$out" ]] && return 1
    [[ "$out" == *"need to be root"* ]] && return 1
    printf '%s\n' "$out"
}

# Parses `ufw status verbose` text into "status|default_in|default_out|logging".
# Any field that can't be found is "N/A".
parse_ufw_status() {
    local raw="$1"
    local status logging default_line default_in default_out

    status="$(awk -F': *' '/^Status:/{print $2; exit}' <<<"$raw")"
    logging="$(awk '/^Logging:/{print; exit}' <<<"$raw" | sed -E 's/.*\(([^)]+)\).*/\1/')"
    default_line="$(awk '/^Default:/{print; exit}' <<<"$raw")"
    default_in="$(sed -E 's/^Default:[[:space:]]*([a-z]+)[[:space:]]*\(incoming\).*/\1/' <<<"$default_line")"
    default_out="$(sed -E 's/.*,[[:space:]]*([a-z]+)[[:space:]]*\(outgoing\).*/\1/' <<<"$default_line")"

    [[ "$default_in" == "$default_line" ]] && default_in=""
    [[ "$default_out" == "$default_line" ]] && default_out=""

    printf '%s|%s|%s|%s' "${status:-N/A}" "${default_in:-N/A}" "${default_out:-N/A}" "${logging:-N/A}"
}

# ------------------------------------------------------------------- SSH ---

# Prints "ssh.service" or "sshd.service", whichever actually exists on this
# host (checked in that order), or empty if neither is installed.
find_ssh_unit() {
    local candidate props
    for candidate in ssh.service sshd.service; do
        props="$(get_unit_properties "$candidate" "LoadState")" || props=""
        if [[ -n "$props" ]] && unit_exists "$props"; then
            printf '%s' "$candidate"
            return
        fi
    done
    printf ''
}

# Attempts to determine SSH's actual listening port: first from live
# sockets (process name "sshd", visible when running with enough
# privilege), falling back to sshd_config's Port directive (defaulting to
# 22, SSH's own documented default, only when the config is readable and
# sets no explicit override). Prints empty if neither is determinable.
detect_ssh_port() {
    local listen_lines port
    if listen_lines="$(get_listening_ports)" && [[ -n "$listen_lines" ]]; then
        port="$(awk -F'|' '$3=="sshd"{print $2; exit}' <<<"$listen_lines")"
        [[ -n "$port" ]] && { printf '%s' "$port"; return; }
    fi

    [[ -r /etc/ssh/sshd_config ]] || { printf ''; return; }

    local -a files=(/etc/ssh/sshd_config)
    local f
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -r "$f" ]] && files+=("$f")
    done

    port="$(awk 'tolower($1)=="port"{p=$2} END{if (p!="") print p}' "${files[@]}" 2>/dev/null)"
    printf '%s' "${port:-22}"
}

# True if the given port number appears among any currently listening TCP
# sockets (any bind address).
is_port_listening() {
    local port="$1"
    [[ -z "$port" ]] && return 1
    local listen_lines
    listen_lines="$(get_listening_ports)" || return 1
    [[ -z "$listen_lines" ]] && return 1
    awk -F'|' -v p="$port" '$2==p{found=1} END{exit !found}' <<<"$listen_lines"
}

# ---------------------------------------------------------- AUTHENTICATION ---

# Prints the count of failed-authentication journal lines in the last 24
# hours, or returns 1 if journalctl is unavailable, times out, or errors
# (callers should show N/A in that case - 0 is only printed for a genuine,
# successfully-checked zero count). Bounded by --since and a hard timeout;
# never scans the full journal.
get_recent_auth_failures() {
    command_exists journalctl || return 1
    command_exists timeout || return 1

    local out rc=0
    out="$(timeout 3 journalctl --since "24 hours ago" \
        -g "Failed password|authentication failure|Invalid user" \
        --no-pager -o cat 2>/dev/null)" || rc=$?

    [[ "$rc" -ne 0 ]] && return 1
    [[ -z "$out" ]] && { printf '0'; return 0; }
    wc -l <<<"$out" | tr -d '[:space:]'
}

# --------------------------------------------------------------- FAIL2BAN ---

# Prints "installed|status": installed is yes/no; status is the
# fail2ban.service ActiveState, or N/A if that can't be determined.
# "Installed" is yes if either the fail2ban-client CLI or the
# fail2ban.service unit exists - no fail2ban-client command is ever
# invoked with a state-changing subcommand.
get_fail2ban_status() {
    local has_cli=0
    command_exists fail2ban-client && has_cli=1

    local props="" unit_present=0
    props="$(get_unit_properties "fail2ban.service" "LoadState,ActiveState")" || props=""
    if [[ -n "$props" ]] && unit_exists "$props"; then
        unit_present=1
    fi

    if [[ "$has_cli" -eq 0 && "$unit_present" -eq 0 ]]; then
        printf 'no|N/A'
        return
    fi

    local active="N/A"
    if [[ "$unit_present" -eq 1 ]]; then
        active="$(extract_prop "$props" ActiveState)"
    fi
    printf 'yes|%s' "${active:-N/A}"
}
