#!/usr/bin/env bash
# network.sh - network data collection for `network-info`
#
# Intended to be sourced after common.sh and system.sh (reuses
# get_primary_interface / get_interface_state / get_link_speed /
# get_ipv4_address from system.sh). All commands are single-shot,
# read-only, and rely on /proc/net/dev, ip -j, and ss where possible.

# Prints the interface's MAC address, or "N/A".
get_mac_address() {
    local iface="$1"
    [[ -z "$iface" ]] && { printf 'N/A'; return; }
    if [[ -r "/sys/class/net/${iface}/address" ]]; then
        cat "/sys/class/net/${iface}/address" 2>/dev/null && return
    fi
    printf 'N/A'
}

# Prints the interface's global-scope IPv6 address if present, falling back
# to any IPv6 address (e.g. link-local); empty if none / tools unavailable /
# the call times out. Time-bounded like every other single-shot
# external-tool check in this codebase (see lib/logs.sh's journalctl calls)
# - a wedged `ip` must never hang a caller (bin/network-info, bin/tui)
# indefinitely.
get_ipv6_address() {
    local iface="$1"
    [[ -z "$iface" ]] && { printf ''; return; }
    if ! command_exists ip || ! command_exists jq || ! command_exists timeout; then
        printf ''
        return
    fi
    local addr_json
    addr_json="$(timeout 3 ip -j -6 addr show dev "$iface" 2>/dev/null)" || { printf ''; return; }
    local addr
    addr="$(jq -r '[.[0].addr_info[]? | select(.scope=="global")][0].local // empty' <<<"$addr_json" 2>/dev/null)"
    if [[ -z "$addr" ]]; then
        addr="$(jq -r '.[0].addr_info[0].local // empty' <<<"$addr_json" 2>/dev/null)"
    fi
    printf '%s' "$addr"
}

# One line per non-loopback, non-Docker interface: name|state|ipv4|speed
# ("physical/primary" interfaces, i.e. everything except lo, docker0, br-*
# and veth* — the same interfaces a plain `ip link` on bare metal would show).
get_physical_interface_lines() {
    command_exists ip || return 1
    command_exists jq || return 1
    command_exists timeout || return 1
    local names
    names="$(timeout 3 ip -j link show 2>/dev/null | jq -r '
        .[] | select(.ifname != "lo")
            | select(.ifname != "docker0")
            | select(.ifname | startswith("br-") | not)
            | select(.ifname | startswith("veth") | not)
            | .ifname
    ')" || return 1
    [[ -z "$names" ]] && return 1

    local name state ipv4 speed
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        state="$(get_interface_state "$name")"
        ipv4="$(get_ipv4_address "$name")"
        speed="$(get_link_speed "$name")"
        printf '%s|%s|%s|%s\n' "$name" "$state" "${ipv4:-N/A}" "$speed"
    done <<<"$names"
}

# One line per Docker bridge interface (docker0 and br-*): name|state
get_docker_link_lines() {
    command_exists ip || return 1
    command_exists jq || return 1
    command_exists timeout || return 1
    local out
    out="$(timeout 3 ip -j link show 2>/dev/null | jq -r '
        .[] | select(.ifname == "docker0" or (.ifname | startswith("br-")))
            | [.ifname, .operstate] | join("|")
    ')" || return 1
    [[ -z "$out" ]] && return 1
    printf '%s\n' "$out"
}

# Prints "rx_bytes rx_packets rx_errs rx_drop tx_bytes tx_packets tx_errs tx_drop"
# for the given interface from /proc/net/dev. Returns 1 if not found.
get_interface_traffic() {
    local iface="$1"
    [[ -z "$iface" ]] && return 1
    [[ -r /proc/net/dev ]] || return 1
    awk -F: -v ifc="$iface" '
        {
            name = $1
            gsub(/^[ \t]+|[ \t]+$/, "", name)
            if (name == ifc) {
                n = split($2, f, " ")
                print f[1], f[2], f[3], f[4], f[9], f[10], f[11], f[12]
                found = 1
            }
        }
        END { if (!found) exit 1 }
    ' /proc/net/dev
}

# True if a default route exists.
has_default_route() {
    [[ -n "$(get_primary_interface)" ]]
}

# DNS resolution check: one lookup, short timeout, decoupled from the
# internet-reachability check below.
check_dns() {
    command_exists getent || return 1
    if command_exists timeout; then
        timeout 2 getent ahosts example.com >/dev/null 2>&1
    else
        getent ahosts example.com >/dev/null 2>&1
    fi
}

# Internet-reachability check: a single ICMP packet to a well-known anycast
# address, by IP (not hostname) so this is independent of DNS working.
check_internet() {
    command_exists ping || return 1
    if command_exists timeout; then
        timeout 3 ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1
    else
        ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1
    fi
}

# One line per listening TCP socket: bind|port|process|category
# category is PUBLIC (0.0.0.0, [::], or any other non-loopback bind) or
# LOCAL (127.0.0.0/8 or ::1). Process name is "-" when it can't be
# determined (typically insufficient permission to inspect another user's
# socket) rather than failing the whole command.
get_listening_ports() {
    command_exists ss || return 1
    command_exists timeout || return 1
    local raw
    raw="$(timeout 3 ss -H -tlnp 2>/dev/null)" || return 1
    [[ -z "$raw" ]] && return 1

    local line local_addr bind port proc_field proc_name category
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local_addr="$(awk '{print $4}' <<<"$line")"
        [[ -z "$local_addr" ]] && continue
        bind="${local_addr%:*}"
        port="${local_addr##*:}"

        proc_field="$(awk '{print $6}' <<<"$line")"
        if [[ "$proc_field" =~ \(\(\"([^\"]+)\" ]]; then
            proc_name="${BASH_REMATCH[1]}"
        else
            proc_name="-"
        fi

        case "$bind" in
            0.0.0.0|'[::]') category="PUBLIC" ;;
            127.*|'[::1]') category="LOCAL" ;;
            *) category="PUBLIC" ;;
        esac

        printf '%s|%s|%s|%s\n' "$bind" "$port" "$proc_name" "$category"
    done <<<"$raw"
}

# One line per observed TCP connection state: STATE|count (states with zero
# occurrences are simply absent).
get_connection_state_counts() {
    command_exists ss || return 1
    command_exists timeout || return 1
    local raw
    raw="$(timeout 3 ss -H -tan 2>/dev/null)" || return 1
    [[ -z "$raw" ]] && return 1
    awk '{ print $1 }' <<<"$raw" | sort | uniq -c | awk '{ print $2"|"$1 }'
}

# Normalizes ss's short state name to the conventional TCP state name.
network_normalize_tcp_state() {
    case "${1:-}" in
        ESTAB) printf 'ESTABLISHED' ;;
        *) printf '%s' "${1:-}" ;;
    esac
}
