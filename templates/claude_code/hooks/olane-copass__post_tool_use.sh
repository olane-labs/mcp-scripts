#!/usr/bin/env bash
# olane-copass__post_tool_use.sh — PostToolUse hook for Copass.
# Captures code mutations (Edit, Write, NotebookEdit) via olane CLI.
# Matcher in settings_hooks.json filters to these tools.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/olane-copass__common.sh"

_read_event
_check_enabled

TOOL_NAME="$(_jq '.tool_name')"

_log "INFO" "PostToolUse: tool=${TOOL_NAME}"

# ── Build tool-specific observation (semantic fields only) ────────────
case "${TOOL_NAME}" in
    Edit)
        FILE_PATH="$(_jq '.tool_input.file_path')"
        OLD_STRING="$(_truncate "$(_jq '.tool_input.old_string')" 500)"
        NEW_STRING="$(_truncate "$(_jq '.tool_input.new_string')" 500)"
        OBSERVATION="{\"tool\":\"Edit\",\"file\":\"${FILE_PATH}\",\"old\":\"${OLD_STRING}\",\"new\":\"${NEW_STRING}\"}"
        ;;
    Write)
        FILE_PATH="$(_jq '.tool_input.file_path')"
        OBSERVATION="{\"tool\":\"Write\",\"file\":\"${FILE_PATH}\"}"
        ;;
    NotebookEdit)
        NB_PATH="$(_jq '.tool_input.notebook_path')"
        OBSERVATION="{\"tool\":\"NotebookEdit\",\"file\":\"${NB_PATH}\"}"
        ;;
    *)
        _respond '{"continue": true}'
        exit 0
        ;;
esac

# ── Ingest observation via olane CLI (async) ─────────────────────────
_olane_ingest_text_async "${OBSERVATION}" "agent_observation"

# ── Respond ────────────────────────────────────────────────────────────
_respond '{"continue": true}'
