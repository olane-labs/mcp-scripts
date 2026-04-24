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
#   - summary
#         canonical_ids: a, b, c
MENU="$(printf '%s' "${RESPONSE}" | jq -r '
    (.items // [])[]
    | ("  - " + ( .summary // "(no summary)" )) as $head
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

# -- Header + hint (locally authored, server prose is ignored) -------
# We override the server's `header` / `next_steps` because that prose
# refers to bare tool verbs like `interpret` / `search`. The actual MCP
# tool ids are `mcp__copass__interpret` / `mcp__copass__search`, and
# they are deferred — their schemas must be fetched via `ToolSearch`
# (`select:mcp__copass__interpret,mcp__copass__search`) before the
# tools can be called. The copy below tells the agent exactly that.
TITLE="[Copass] ## Discover: Relevant Context

Candidate context from the user's knowledge graph that isn't in your current window. The items below are labels, not content — treat them as an index you must open before citing them.

**How to use this response:**
1. Scan for items that look relevant to the user's current question. Items are unranked — judge relevance from the title and path alone.
2. Before answering from any item, call \`mcp__copass__interpret\` with its \`canonical_ids\` tuple to read the actual content. A title alone is not evidence — do not describe or rely on an item without interpreting it first. Batch multiple items into a single \`mcp__copass__interpret\` call.
3. Use \`mcp__copass__search\` as a fallback when nothing in the menu looks obviously relevant but the question still implies the graph holds the answer.
4. Skip this menu entirely when the user's question is already answerable from conversation or code in your context.

**Tool access:** \`mcp__copass__interpret\` and \`mcp__copass__search\` are deferred MCP tools — their schemas are not preloaded. Before the first call in this turn, run \`ToolSearch\` with \`select:mcp__copass__interpret,mcp__copass__search\` to load them. After that, call them like any other tool."

HINT="If any item above plausibly relates to the user's question, call \`mcp__copass__interpret\` on those canonical_ids before responding — titles are not evidence. \`mcp__copass__interpret\` accepts multiple tuples in one call, so batch them: \`mcp__copass__interpret(items=[[<canonical_ids from item 1>], [<canonical_ids from item 2>], ...])\`. Fall back to \`mcp__copass__search\` only when no item looks relevant but the question still seems to need graph context. Skip both when the conversation already has what you need. Remember: load schemas via \`ToolSearch\` first if you have not already this turn."

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
