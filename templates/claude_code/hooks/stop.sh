#!/usr/bin/env bash
# stop.sh — Stop hook for Copass.
# Uploads the session transcript to the extraction pipeline.
# Event type: agent_turn_ended | Timeout budget: < 1s

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"

_read_event
_check_enabled

# ── Extract fields ─────────────────────────────────────────────────────
SESSION_ID="$(_jq '.session_id')"
TRANSCRIPT_PATH="$(_jq '.transcript_path')"

_log "INFO" "Stop: session=${SESSION_ID} transcript=${TRANSCRIPT_PATH}"

# ── Upload transcript for extraction ──────────────────────────────────
if [ -n "${TRANSCRIPT_PATH}" ] && [ -f "${TRANSCRIPT_PATH}" ]; then
    _log "INFO" "Uploading transcript: ${TRANSCRIPT_PATH}"
    _api_upload_file_async "/api/v1/extract/file" "${TRANSCRIPT_PATH}" \
        "source_type=agent_transcript" \
        "source_id=${SESSION_ID}"
else
    _log "DEBUG" "No transcript file to upload (path=${TRANSCRIPT_PATH})"
fi

# ── Respond ────────────────────────────────────────────────────────────
_respond '{"continue": true}'
