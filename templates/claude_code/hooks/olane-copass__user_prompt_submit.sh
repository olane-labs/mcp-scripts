#!/usr/bin/env bash
# olane-copass__user_prompt_submit.sh
# UserPromptSubmit hook: reads the user's prompt from stdin,
# queries Copass via olane CLI, and injects context into the conversation.
#
# Plain text stdout is both visible to the user AND added as context.
# stderr → logging only

set -euo pipefail

# ── Ensure olane CLI exists ──────────────────────────────────────────
if ! command -v olane >/dev/null 2>&1; then
    echo "[Copass] olane CLI not found — install with: npm i -g @olane/o-cli"
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
    echo "[Copass] Query failed — proceeding without ontology context"
    exit 0
}

# ── Extract context from response ────────────────────────────────────
CONTEXT="$(echo "${RESPONSE}" | jq -r '.summary // empty' 2>/dev/null || true)"
if [ -z "${CONTEXT}" ]; then
    echo "[Copass] No context found for this query"
    exit 0
fi

# ── Output as plain text (visible to user + added as context) ────────
echo "[Copass] Context loaded"
echo ""
echo "${CONTEXT}"
