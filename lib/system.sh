#!/usr/bin/env bash
# system.sh - system/network/docker/security data collection for `info`
#
# Intended to be sourced after common.sh. All functions are read-only and
# rely on /proc, /sys, and machine-readable command output where possible.

get_hostname() {
    safe_run hostname || printf 'N/A'
}

get_os_pretty_name() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        local pretty_name
        pretty_name="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}")"
        if [[ -n "$pretty_name" ]]; then
            printf '%s' "$pretty_name"
            return
        fi
    fi
    printf 'N/A'
}

get_kernel_version() {
    safe_run uname -r || printf 'N/A'
}

get_uptime_human() {
    local seconds
    if [[ -r /proc/uptime ]]; then
        seconds="$(cut -d' ' -f1 /proc/uptime)"
        seconds="${seconds%%.*}"
    fi

    if ! [[ "${seconds:-}" =~ ^[0-9]+$ ]]; then
        printf 'N/A'
        return
    fi

    local days=$(( seconds / 86400 ))
    local hours=$(( (seconds % 86400) / 3600 ))
    local mins=$(( (seconds % 3600) / 60 ))
    local out=""

    (( days > 0 )) && out+="${days}d "
    (( days > 0 || hours > 0 )) && out+="${hours}h "
    out+="${mins}m"

    printf '%s' "$out"
}

get_load_average() {
    if [[ -r /proc/loadavg ]]; then
        local one five fifteen _rest
        read -r one five fifteen _rest < /proc/loadavg
        printf '%s, %s, %s' "$one" "$five" "$fifteen"
        return
    fi
    printf 'N/A'
}

get_cpu_model() {
    if [[ -r /proc/cpuinfo ]]; then
        local model
        model="$(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2-)"
        model="${model#"${model%%[![:space:]]*}"}" # trim leading whitespace
        if [[ -n "$model" ]]; then
            printf '%s' "$model"
            return
        fi
    fi
    printf 'N/A'
}

# Prints "<cores>c/<threads>t" (falls back to threads-only if core count is unknown).
get_cpu_topology() {
    local threads cores
    threads="$(safe_run nproc --all)" || threads="N/A"

    if [[ -r /proc/cpuinfo ]]; then
        cores="$(grep -m1 '^cpu cores' /proc/cpuinfo | cut -d: -f2- | tr -d '[:space:]')"
    fi

    if [[ -z "${cores:-}" ]]; then
        cores="$threads"
    fi

    printf '%sc/%st' "$cores" "$threads"
}

# Prints "used total percent" (bytes, bytes, "NN%") for RAM.
get_ram_stats() {
    if ! command_exists free; then
        printf 'N/A N/A N/A'
        return
    fi
    local line total used
    line="$(free -b | grep '^Mem:')" || { printf 'N/A N/A N/A'; return; }
    read -r _ total used _ <<<"$line"
    printf '%s %s %s' "$used" "$total" "$(format_percent "$used" "$total")"
}

# Prints "used total percent" (bytes, bytes, "NN%") for swap.
get_swap_stats() {
    if ! command_exists free; then
        printf 'N/A N/A N/A'
        return
    fi
    local line total used
    line="$(free -b | grep '^Swap:')" || { printf 'N/A N/A N/A'; return; }
    read -r _ total used _ <<<"$line"
    if [[ "$total" -eq 0 ]]; then
        printf '%s %s N/A' "$used" "$total"
        return
    fi
    printf '%s %s %s' "$used" "$total" "$(format_percent "$used" "$total")"
}

# Prints "used total percent" (bytes, bytes, "NN%") for the root filesystem.
get_disk_stats() {
    local line size used pcent
    line="$(df -B1 --output=size,used,pcent / 2>/dev/null | tail -n1)" || { printf 'N/A N/A N/A'; return; }
    read -r size used pcent <<<"$line"
    if [[ -z "${size:-}" || -z "${used:-}" ]]; then
        printf 'N/A N/A N/A'
        return
    fi
    printf '%s %s %s' "$used" "$size" "$pcent"
}

# Detects the interface carrying the default route. Time-bounded like
# every other single-shot external-tool check in this codebase - a wedged
# `ip` must never hang a caller (bin/info, bin/tui) indefinitely.
get_primary_interface() {
    if command_exists ip && command_exists jq && command_exists timeout; then
        local iface
        iface="$(timeout 3 ip -j route show default 2>/dev/null | jq -r '.[0].dev // empty')"
        if [[ -n "$iface" ]]; then
            printf '%s' "$iface"
            return
        fi
    fi
    printf ''
}

get_interface_state() {
    local iface="$1"
    [[ -z "$iface" ]] && { printf 'N/A'; return; }
    if [[ -r "/sys/class/net/${iface}/operstate" ]]; then
        cat "/sys/class/net/${iface}/operstate" 2>/dev/null || printf 'N/A'
        return
    fi
    printf 'N/A'
}

get_link_speed() {
    local iface="$1"
    [[ -z "$iface" ]] && { printf 'N/A'; return; }
    local speed_file="/sys/class/net/${iface}/speed"
    local speed
    if [[ -r "$speed_file" ]] && speed="$(cat "$speed_file" 2>/dev/null)" && [[ "$speed" =~ ^[0-9]+$ ]]; then
        printf '%s Mbps' "$speed"
        return
    fi
    printf 'N/A'
}

# Time-bounded - see get_primary_interface.
get_ipv4_address() {
    local iface="$1"
    [[ -z "$iface" ]] && { printf ''; return; }
    if command_exists ip && command_exists jq && command_exists timeout; then
        timeout 3 ip -j -4 addr show dev "$iface" 2>/dev/null | jq -r '.[0].addr_info[0].local // empty'
        return
    fi
    printf ''
}

# Prints the Docker server version, or empty if the daemon is unreachable.
# Time-bounded like every other single-shot external-tool check in this
# codebase (see lib/logs.sh's journalctl calls, and the same convention
# already applied to lib/docker.sh/services.sh/security.sh/gpu.sh/network.sh)
# - a wedged Docker daemon must never hang a caller (bin/info, bin/tui)
# indefinitely.
get_docker_version() {
    command_exists timeout || { printf ''; return; }
    safe_run timeout 3 docker version --format '{{.Server.Version}}' || printf ''
}

# Prints "running total" container counts, or empty if the daemon is
# unreachable or the call times out.
get_docker_container_counts() {
    command_exists timeout || { printf ''; return; }
    local json
    if ! json="$(timeout 3 docker info --format '{{json .}}' 2>/dev/null)"; then
        printf ''
        return
    fi
    local running total
    running="$(jq -r '.ContainersRunning // 0' <<<"$json" 2>/dev/null)"
    total="$(jq -r '.Containers // 0' <<<"$json" 2>/dev/null)"
    printf '%s %s' "${running:-0}" "${total:-0}"
}

# Prints the count of containers reporting a healthy healthcheck, or empty
# string if no containers report health information at all (or docker is
# unavailable / the call times out).
get_docker_healthy_count() {
    command_exists timeout || { printf ''; return; }
    local statuses
    if ! statuses="$(timeout 3 docker ps --format '{{.Status}}' 2>/dev/null)"; then
        printf ''
        return
    fi
    [[ -z "$statuses" ]] && { printf ''; return; }

    local with_health healthy
    with_health="$(grep -c '(health' <<<"$statuses" || true)"
    healthy="$(grep -c '(healthy)' <<<"$statuses" || true)"

    if [[ "${with_health:-0}" -gt 0 ]]; then
        printf '%s' "${healthy:-0}"
    else
        printf ''
    fi
}

# Prints the count of containers currently reporting an unhealthy
# healthcheck (0 if docker is unavailable or the call times out).
get_docker_unhealthy_count() {
    command_exists timeout || { printf '0'; return; }
    local statuses
    if ! statuses="$(timeout 3 docker ps --format '{{.Status}}' 2>/dev/null)"; then
        printf '0'
        return
    fi
    [[ -z "$statuses" ]] && { printf '0'; return; }
    grep -c '(unhealthy)' <<<"$statuses" || true
}

# Prints "NAME CPU% MEM" for the top N containers by CPU usage, one per
# line. Time-bounded - see get_docker_version.
get_top_containers() {
    local n="${1:-2}"
    command_exists timeout || return 1
    local raw
    if ! raw="$(timeout 5 docker stats --no-stream --format '{{.Name}}	{{.CPUPerc}}	{{.MemUsage}}' 2>/dev/null)"; then
        return 1
    fi
    [[ -z "$raw" ]] && return 1

    printf '%s\n' "$raw" \
        | awk -F'\t' '{ cpu=$2; gsub("%","",cpu); print cpu"\t"$0 }' \
        | sort -t $'\t' -k1,1 -rn \
        | cut -f2- \
        | awk -F'\t' -v n="$n" 'NR<=n { split($3,mem," / "); print $1"\t"$2"\t"mem[1] }'
}

# Time-bounded like every other single-shot external-tool check in this
# codebase - a wedged ufw must never hang a caller (bin/info, bin/tui)
# indefinitely.
get_ufw_status() {
    if ! command_exists ufw; then
        printf ''
        return
    fi
    if ! command_exists timeout; then
        printf ''
        return
    fi
    local out
    if ! out="$(timeout 3 ufw status 2>/dev/null)"; then
        printf 'N/A'
        return
    fi
    if [[ "$out" == *"Status: active"* ]]; then
        printf 'active'
    elif [[ "$out" == *"Status: inactive"* ]]; then
        printf 'inactive'
    else
        printf 'N/A'
    fi
}

# Time-bounded - see get_ufw_status. Currently unused by any bin/* entry
# point, but fixed for consistency with every other systemctl/docker/ufw/ip
# call in this file rather than leaving an unbounded call dormant here.
get_failed_units_count() {
    if ! command_exists systemctl; then
        printf 'N/A'
        return
    fi
    if ! command_exists timeout; then
        printf 'N/A'
        return
    fi
    local out
    out="$(timeout 3 systemctl --failed --no-legend --no-pager 2>/dev/null)" || { printf 'N/A'; return; }
    if [[ -z "$out" ]]; then
        printf '0'
    else
        wc -l <<<"$out" | tr -d '[:space:]'
    fi
}

get_reboot_required() {
    [[ -f /var/run/reboot-required ]] && printf 'yes' || printf 'no'
}
