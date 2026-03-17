#!/usr/bin/env bash
# olane-copass__notification.sh — Notification hook for Copass.
# Captures task milestone events via olane CLI.
# Not in active settings — kept for optional use.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/olane-copass__common.sh"

_read_event
_check_enabled

MESSAGE="$(_jq '.message')"

_log "INFO" "Notification: message=${MESSAGE}"

OBSERVATION="{\"event_type\":\"agent_notification\",\"message\":\"${MESSAGE}\"}"

_olane_ingest_text_async "${OBSERVATION}" "agent_observation"

_respond '{"continue": true}'
