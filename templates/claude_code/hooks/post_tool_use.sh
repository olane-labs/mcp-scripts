#!/usr/bin/env bash
# post_tool_use.sh — PostToolUse hook for Copass.
# Only captures code mutations (Edit, Write, NotebookEdit).
# Everything else is covered by the transcript upload in stop.sh.


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/_common.sh"

_read_event
_check_enabled

# ── Only fire for code mutation tools ─────────────────────────────────
TOOL_NAME="$(_jq '.tool_name')"

case "${TOOL_NAME}" in
    Edit|Write|NotebookEdit)
        ;; # continue
    *)
        _respond '{"continue": true}'
        exit 0
        ;;
esac

_log "INFO" "PostToolUse: tool=${TOOL_NAME}"

# ── Build tool-specific observation (semantic fields only) ────────────
case "${TOOL_NAME}" in
    Edit)
        FILE_PATH="$(_jq '.tool_input.file_path')"
        OLD_STRING="$(_truncate "$(_jq '.tool_input.old_string')" 500)"
        NEW_STRING="$(_truncate "$(_jq '.tool_input.new_string')" 500)"
        FILE_PATH_ESC="$(_json_escape "${FILE_PATH}")"
        OLD_STRING_ESC="$(_json_escape "${OLD_STRING}")"
        NEW_STRING_ESC="$(_json_escape "${NEW_STRING}")"
        OBSERVATION="{\"tool\":\"Edit\",\"file\":\"${FILE_PATH_ESC}\",\"old\":\"${OLD_STRING_ESC}\",\"new\":\"${NEW_STRING_ESC}\"}"
        ;;
    Write)
        FILE_PATH="$(_jq '.tool_input.file_path')"
        FILE_PATH_ESC="$(_json_escape "${FILE_PATH}")"
        OBSERVATION="{\"tool\":\"Write\",\"file\":\"${FILE_PATH_ESC}\"}"
        ;;
    NotebookEdit)
        NB_PATH="$(_jq '.tool_input.notebook_path')"
        NB_PATH_ESC="$(_json_escape "${NB_PATH}")"
        OBSERVATION="{\"tool\":\"NotebookEdit\",\"file\":\"${NB_PATH_ESC}\"}"
        ;;
esac

# ── Send as text extraction (no source_id — avoids hash pollution) ────
OBSERVATION_ESC="$(_json_escape "${OBSERVATION}")"
PAYLOAD="{\"text\":\"${OBSERVATION_ESC}\",\"source_type\":\"agent_observation\",\"client_type\":\"claude_code\"}"
if [ -n "${OLANE_PROJECT_ID}" ]; then
    PAYLOAD="{\"text\":\"${OBSERVATION_ESC}\",\"source_type\":\"agent_observation\",\"client_type\":\"claude_code\",\"project_id\":\"${OLANE_PROJECT_ID}\"}"
fi

_api_post_async "/api/v1/extract" "${PAYLOAD}" 5

# ── Respond ────────────────────────────────────────────────────────────
_respond '{"continue": true}'
