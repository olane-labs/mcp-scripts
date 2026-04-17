#!/usr/bin/env bash
# olane-copass__user_prompt_submit.sh
# UserPromptSubmit hook: reads the user's prompt from stdin, calls
# `copass discover` to surface related context, and emits a JSON hook
# result so the menu is rendered inline to the user AND added to Claude's
# context window.
#
# Output contract (Claude Code hooks JSON):
#   systemMessage                      -> rendered inline, visible to user
#   hookSpecificOutput.additionalContext -> injected into Claude's context
#   suppressOutput: true               -> hide raw stdout from transcript
#
# stderr -> logging only.

set -euo pipefail

# -- Emit a JSON hook result -----------------------------------------
# $1 = visible message (systemMessage)
# $2 = optional additional context (hookSpecificOutput.additionalContext)
emit_json() {
    local msg="$1"
    local ctx="${2:-}"
    if [ -n "${ctx}" ]; then
        jq -n --arg msg "${msg}" --arg ctx "${ctx}" '{
            continue: true,
            suppressOutput: true,
            systemMessage: $msg,
            hookSpecificOutput: {
                hookEventName: "UserPromptSubmit",
                additionalContext: $ctx
            }
        }'
    else
        jq -n --arg msg "${msg}" '{
            continue: true,
            suppressOutput: true,
            systemMessage: $msg
        }'
    fi
}

# -- jq is required for JSON parsing AND JSON output -----------------
if ! command -v jq >/dev/null 2>&1; then
    echo "[Copass] jq not found - ontology context injection disabled"
    exit 0
fi

# -- Ensure copass CLI exists ----------------------------------------
if ! command -v copass >/dev/null 2>&1; then
    emit_json "[Copass] copass CLI not found - install with: npm i -g @olane/o-cli"
    exit 0
fi

# -- Read event from stdin -------------------------------------------
EVENT="$(cat || true)"
if [ -z "${EVENT}" ]; then
    exit 0
fi

# -- Extract the user prompt -----------------------------------------
PROMPT="$(printf '%s' "${EVENT}" | jq -r '.prompt // empty' 2>/dev/null || true)"
if [ -z "${PROMPT}" ]; then
    exit 0
fi

# -- Optional project_id from .olane/config.json ---------------------
PROJECT_ARGS=()
CONFIG_FILE=".olane/config.json"
if [ -f "${CONFIG_FILE}" ]; then
    PID="$(jq -r '.project_id // empty' "${CONFIG_FILE}" 2>/dev/null || true)"
    if [ -n "${PID}" ]; then
        PROJECT_ARGS=(--project-id "${PID}")
    fi
fi

# -- Discover related context ----------------------------------------
RESPONSE="$(copass discover "${PROMPT}" ${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"} --json 2>/dev/null || true)"
if [ -z "${RESPONSE}" ]; then
    emit_json "[Copass] Discover failed - proceeding without ontology context"
    exit 0
fi

# -- Validate JSON + extract item count ------------------------------
COUNT="$(printf '%s' "${RESPONSE}" | jq -r '
    if type == "object" and (.items | type) == "array"
    then (.count // (.items | length))
    else "invalid"
    end
' 2>/dev/null || echo "invalid")"

if [ "${COUNT}" = "invalid" ]; then
    emit_json "[Copass] Discover returned unexpected payload - skipping"
    exit 0
fi

if [ "${COUNT}" = "0" ] || [ -z "${COUNT}" ]; then
    emit_json "[Copass] No related context found"
    exit 0
fi

# -- Format the menu -------------------------------------------------
# Each item renders as:
#   [NN%] summary
#         canonical_ids: a, b, c
MENU="$(printf '%s' "${RESPONSE}" | jq -r '
    (.items // [])[]
    | (
        "  [" +
        ( if (.score | type) == "number"
          then ((.score * 100) | floor | tostring) + "%"
          else "--"
          end ) +
        "] " +
        ( .summary // "(no summary)" )
      ) as $head
    | (
        if ((.canonical_ids // []) | length) > 0
        then "\n        canonical_ids: " + ((.canonical_ids // []) | join(", "))
        else ""
        end
      ) as $tail
    | $head + $tail
' 2>/dev/null || true)"

if [ -z "${MENU}" ]; then
    emit_json "[Copass] No related context found"
    exit 0
fi

# -- Header + hint from response (with fallbacks) --------------------
HEADER="$(printf '%s' "${RESPONSE}" | jq -r '.header // empty' 2>/dev/null || true)"
HINT="$(printf '%s' "${RESPONSE}" | jq -r '.next_steps // empty' 2>/dev/null || true)"
if [ -z "${HINT}" ]; then
    HINT="Pass canonical_ids to \`copass interpret '[[\"cid1\",\"cid2\"]]'\` for a deeper brief."
fi

if [ -n "${HEADER}" ]; then
    TITLE="[Copass] ${HEADER}"
else
    TITLE="[Copass] ${COUNT} related context item(s) discovered."
fi

# -- Render a hierarchical tree for the user (compact view) ----------
# Pure local compute on the same RESPONSE JSON — no extra backend call.
# Falls back to the flat MENU if render-tree is unavailable or fails.
TREE="$(printf '%s' "${RESPONSE}" | copass render-tree 2>/dev/null || true)"

# User-visible: just a compact header + the tree. Strips the verbose prose
# that the server returns (response.header / response.next_steps) because
# that content is written to teach the agent how to use the data, not the
# user. The agent still gets the full verbose version in additionalContext.
if [ -n "${TREE}" ]; then
    VISIBLE="[Copass] Related Ontology Graph

${TREE}"
else
    VISIBLE="[Copass] Related Ontology Graph

${MENU}"
fi

# Agent context: keep the server header/next_steps (the teaching prose) plus
# the flat list with canonical_ids so interpret() can consume them directly.
CONTEXT="${TITLE}

${MENU}

[Copass] ${HINT}"

emit_json "${VISIBLE}" "${CONTEXT}"
