#!/usr/bin/env bash
# olane-copass__user_prompt_submit.sh
# UserPromptSubmit hook: reads the user's prompt from stdin,
# queries Copass via olane CLI, and injects context into the conversation.
#
# stdout → JSON response for Claude Code (ONLY output channel)
# stderr → logging

set -euo pipefail

# ── Ensure olane CLI exists ──────────────────────────────────────────
if ! command -v olane >/dev/null 2>&1; then
    echo '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"[Copass] olane CLI not found — install with: npm i -g @olane/o-cli"}}'
    exit 0
fi

# ── Read event from stdin ────────────────────────────────────────────
EVENT="$(cat)"
if [ -z "${EVENT}" ]; then
    exit 0
fi

# ── Extract prompt ───────────────────────────────────────────────────
PROMPT="$(echo "${EVENT}" | jq -r '.prompt // empty' 2>/dev/null || true)"
if [ -z "${PROMPT}" ]; then
    exit 0
fi

# ── Project ID (optional) ───────────────────────────────────────────
PROJECT_ARGS=()
CONFIG_FILE=".olane/config.json"
if [ -f "${CONFIG_FILE}" ] && command -v jq >/dev/null 2>&1; then
    PID="$(jq -r '.project_id // empty' "${CONFIG_FILE}" 2>/dev/null || true)"
    if [ -n "${PID}" ]; then
        PROJECT_ARGS=(--project-id "${PID}")
    fi
fi

# ── Query Copass ─────────────────────────────────────────────────────
RESPONSE="$(olane copass question "${PROMPT}" "${PROJECT_ARGS[@]}" --json 2>/dev/null)" || {
    echo '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"[Copass] Query failed — proceeding without ontology context"}}'
    exit 0
}

# ── Extract context from response ────────────────────────────────────
CONTEXT="$(echo "${RESPONSE}" | jq -r '.summary // empty' 2>/dev/null || true)"
if [ -z "${CONTEXT}" ]; then
    exit 0
fi

# ── Escape for JSON and return ───────────────────────────────────────
CONTEXT_ESC="$(echo "${CONTEXT}" | jq -Rs '.' 2>/dev/null)"
# jq -Rs wraps in quotes, so strip them for embedding
CONTEXT_ESC="${CONTEXT_ESC:1:${#CONTEXT_ESC}-2}"

cat <<ENDJSON
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"${CONTEXT_ESC}"}}
ENDJSON
