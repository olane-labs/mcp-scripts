#!/usr/bin/env bash
# olane-copass__stop.sh — Stop hook for Copass.
# Ingests the session transcript via olane CLI, which handles
# cleaning, encryption, and upload internally.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/olane-copass__common.sh"

_read_event
_check_enabled

# ── Extract fields ─────────────────────────────────────────────────────
SESSION_ID="$(_jq '.session_id')"
TRANSCRIPT_PATH="$(_jq '.transcript_path')"

_log "INFO" "Stop: session=${SESSION_ID} transcript=${TRANSCRIPT_PATH}"

# ── Ingest transcript via olane CLI ────────────────────────────────────
if [ -n "${TRANSCRIPT_PATH}" ] && [ -f "${TRANSCRIPT_PATH}" ]; then
    _log "INFO" "Ingesting transcript: ${TRANSCRIPT_PATH}"
    _olane_ingest_file_async "${TRANSCRIPT_PATH}" "agent_transcript" \
        --source-id "${SESSION_ID}"
else
    _log "DEBUG" "No transcript file to ingest (path=${TRANSCRIPT_PATH})"
fi

# ── Respond ────────────────────────────────────────────────────────────
_respond '{"continue": true}'
