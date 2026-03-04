#!/bin/bash
# rite workflow - Notification Hook
# Sends notifications to configured channels

set -euo pipefail

# Notifications are best-effort; exit gracefully if jq is not available
command -v jq >/dev/null 2>&1 || exit 0

# Read CWD from stdin JSON (consistent with other hooks).
# CWD is provided by the Claude Code runtime and is already an absolute path;
# realpath normalization is unnecessary and would add a portability concern.
INPUT=$(cat) || INPUT=""
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
    exit 0
fi

CONFIG_FILE="$CWD/rite-config.yml"
if [ ! -f "$CONFIG_FILE" ]; then
    exit 0
fi

# Arguments
EVENT_TYPE="${1:-}"    # pr_created, pr_ready, issue_closed, etc.
EVENT_DATA="${2:-}"    # Reserved for future use (JSON data about the event).
                       # Validation will be added when consumers are introduced.

# Check if notifications are enabled
# This is a placeholder - actual implementation would parse YAML

# Webhook URL validation: only ^https:// prefix is checked. A host whitelist is
# intentionally not implemented because webhook URLs are configured by the project
# owner in rite-config.yml (a trusted source). SSRF risk is mitigated by:
# 1. URLs come from a committed config file, not user input at runtime
# 2. curl -sf suppresses error output and fails silently on HTTP errors
# 3. Notifications are best-effort (|| true) — failures are silent

send_slack() {
    local webhook_url="$1"
    local message="$2"

    if [ -n "$webhook_url" ] && [[ "$webhook_url" =~ ^https:// ]]; then
        curl -sf --connect-timeout 5 --max-time 10 -X POST "$webhook_url" \
            -H 'Content-type: application/json' \
            -d "$(jq -n --arg text "$message" '{text: $text}')" > /dev/null || true
    fi
}

send_discord() {
    local webhook_url="$1"
    local message="$2"

    if [ -n "$webhook_url" ] && [[ "$webhook_url" =~ ^https:// ]]; then
        curl -sf --connect-timeout 5 --max-time 10 -X POST "$webhook_url" \
            -H 'Content-type: application/json' \
            -d "$(jq -n --arg content "$message" '{content: $content}')" > /dev/null || true
    fi
}

send_teams() {
    local webhook_url="$1"
    local message="$2"

    if [ -n "$webhook_url" ] && [[ "$webhook_url" =~ ^https:// ]]; then
        curl -sf --connect-timeout 5 --max-time 10 -X POST "$webhook_url" \
            -H 'Content-type: application/json' \
            -d "$(jq -n --arg text "$message" '{text: $text}')" > /dev/null || true
    fi
}

# Main notification logic — echo-only stubs. The send_* functions above are
# defined for when rite-config.yml webhook parsing is implemented; until then
# each branch simply logs the event type.
case "$EVENT_TYPE" in
    pr_created)
        echo "rite: Notification for PR created"
        ;;
    pr_ready)
        echo "rite: Notification for PR ready for review"
        ;;
    issue_closed)
        echo "rite: Notification for Issue closed"
        ;;
    *)
        # Unknown event type, skip
        ;;
esac
