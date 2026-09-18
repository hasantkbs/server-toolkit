#!/usr/bin/env bash
# status.sh - minimal shared status/alert contract for dashboard-style
# commands (used by `info`; available for a future TUI/config/plugin layer
# to reuse without needing to change how individual modules print today).
#
# Deliberately small: this is a data shape and two rendering helpers, not a
# framework. It does not change how any existing bin/*-info command builds
# or prints its own ALERTS section - those are untouched. A caller collects
# alerts into a plain bash array (its own "alerts=()") and uses add_alert/
# render_alerts to populate and print it consistently.
#
# Status values a module/check can be in:
#   OK       - checked, nothing wrong
#   WARN     - checked, an objective threshold/condition was exceeded
#   ERROR    - checked, a hard failure (e.g. a required daemon is down)
#   UNKNOWN  - could not be checked (tool/permission/data unavailable) -
#              never treated as a problem on its own
#
# An alert is one line: "severity|source|message" (source is the
# module/check name, e.g. "docker", "services", "logs").

STATUS_OK="OK"
STATUS_WARN="WARN"
STATUS_ERROR="ERROR"
STATUS_UNKNOWN="UNKNOWN"

# Appends one alert to the named array (a plain bash array the caller
# already declared, e.g. `alerts=()`).
# Usage: add_alert alerts WARN docker "Docker daemon is unavailable"
add_alert() {
    local -n _add_alert_arr="$1"
    local severity="$2" source="$3" message="$4"
    _add_alert_arr+=("${severity}|${source}|${message}")
}

# Prints the glyph for a severity, reusing common.sh's status_indicator
# (ok/warn/bad) where it already fits.
alert_glyph() {
    case "${1:-}" in
        "$STATUS_OK") status_indicator ok ;;
        "$STATUS_WARN"|"$STATUS_ERROR") status_indicator warn ;;
        "$STATUS_UNKNOWN") printf '-' ;;
        *) printf '-' ;;
    esac
}

# Prints every alert in the named array as "glyph message" (source is used
# for filtering/future consumers, not shown inline - callers already know
# which section they're in from the surrounding output), or a single
# "✓ <ok_message>" line when the array is empty.
render_alerts() {
    local -n _render_alerts_arr="$1"
    local ok_message="${2:-No active alerts}"

    if [[ "${#_render_alerts_arr[@]}" -eq 0 ]]; then
        printf '%s %s\n' "$(status_indicator ok)" "$ok_message"
        return
    fi

    local entry severity source message
    for entry in "${_render_alerts_arr[@]}"; do
        IFS='|' read -r severity source message <<<"$entry"
        printf '%s %s\n' "$(alert_glyph "$severity")" "$message"
    done
}
