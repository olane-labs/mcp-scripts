#!/usr/bin/env bash
# notification.sh — Notification hook for Copass.
# Captures task milestone events.
# Omits session_id/timestamp/user_id for dedup hash stability.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"

_read_event
_check_enabled

# ── Extract fields ─────────────────────────────────────────────────────
MESSAGE="$(_jq '.message')"

_log "INFO" "Notification: message=${MESSAGE}"

# ── Build payload (semantic fields only) ──────────────────────────────
MESSAGE_ESC="$(_json_escape "${MESSAGE}")"
OBSERVATION="{\"event_type\":\"agent_notification\",\"message\":\"${MESSAGE_ESC}\"}"

# ── Send as text extraction ───────────────────────────────────────────
OBSERVATION_ESC="$(_json_escape "${OBSERVATION}")"
PAYLOAD="{\"text\":\"${OBSERVATION_ESC}\",\"source_type\":\"agent_observation\",\"client_type\":\"claude_code\"}"
if [ -n "${OLANE_PROJECT_ID}" ]; then
    PAYLOAD="{\"text\":\"${OBSERVATION_ESC}\",\"source_type\":\"agent_observation\",\"client_type\":\"claude_code\",\"project_id\":\"${OLANE_PROJECT_ID}\"}"
fi

_api_post_async "/api/v1/extract" "${PAYLOAD}" 5

# ── Respond ────────────────────────────────────────────────────────────
_respond '{"continue": true}'
