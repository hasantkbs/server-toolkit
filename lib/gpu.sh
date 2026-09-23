#!/usr/bin/env bash
# gpu.sh - NVIDIA GPU detection and metrics for `gpu-info` and `info`
#
# Intended to be sourced after common.sh. Never assumes CUDA is installed;
# only relies on the nvidia-smi CLI tool.

GPU_QUERY_FIELDS="index,name,driver_version,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit"

# Time-bounded like every other single-shot external-tool check in this
# codebase (see lib/logs.sh's journalctl calls) - a wedged/misbehaving
# nvidia-smi must never hang a caller (bin/gpu-info, bin/tui) indefinitely.
gpu_available() {
    command_exists nvidia-smi || return 1
    command_exists timeout || return 1
    timeout 3 nvidia-smi -L >/dev/null 2>&1
}

# One CSV line per GPU: index,name,driver,util,mem_used,mem_total,temp,power_draw,power_limit
get_gpu_list() {
    if ! gpu_available; then
        return 1
    fi
    timeout 3 nvidia-smi --query-gpu="$GPU_QUERY_FIELDS" --format=csv,noheader,nounits 2>/dev/null
}

# One CSV line per compute process: pid,process_name,used_memory
get_gpu_processes() {
    if ! gpu_available; then
        return 1
    fi
    timeout 3 nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null
}

# Normalizes an nvidia-smi field: numeric values pass through trimmed,
# anything else (e.g. "[Not Supported]", "[N/A]") becomes "N/A".
gpu_clean_field() {
    local val="$1"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        printf '%s' "$val"
    else
        printf 'N/A'
    fi
}

gpu_trim() {
    local val="$1"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    printf '%s' "$val"
}
