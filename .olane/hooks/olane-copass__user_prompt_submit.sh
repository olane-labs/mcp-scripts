#!/usr/bin/env bash
# olane-copass__user_prompt_submit.sh — UserPromptSubmit hook for Copass.
# Captures the user's prompt, queries the context layer via olane CLI,
# and injects enriched context back into Claude's conversation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/olane-copass__common.sh"

_read_event
_check_enabled

# ── Extract the user's prompt ────────────────────────────────────────
PROMPT="$(_jq '.prompt')"

if [ -z "${PROMPT}" ]; then
    _log "WARN" "UserPromptSubmit: empty prompt"
    exit 0
fi

_log "INFO" "UserPromptSubmit: prompt_length=${#PROMPT}"

# ── Query context layer via olane CLI ────────────────────────────────
RESPONSE="$(_olane_context_query "${PROMPT}")" || {
    _log "WARN" "UserPromptSubmit: olane copass question failed"
    # Still ingest the prompt asynchronously
    _olane_ingest_text_async "${PROMPT}" "user_prompt"
    exit 0
}

# ── Parse context response ───────────────────────────────────────────
CONTEXT=""
if [ -n "${RESPONSE}" ] && command -v jq >/dev/null 2>&1; then
    CONTEXT="$(echo "${RESPONSE}" | jq -r '.context // empty' 2>/dev/null || true)"
fi

if [ -z "${CONTEXT}" ]; then
    _log "DEBUG" "UserPromptSubmit: no context returned"
    exit 0
fi

_log "INFO" "UserPromptSubmit: injecting context (length=${#CONTEXT})"

# ── Return enriched context to Claude ────────────────────────────────
CONTEXT_ESC="$(_json_escape "${CONTEXT}")"
cat <<ENDJSON
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"${CONTEXT_ESC}"}}
ENDJSON
