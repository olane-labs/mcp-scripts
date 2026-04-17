#!/usr/bin/env bash
# olane-copass__user_prompt_submit.sh
# UserPromptSubmit hook: reads the user's prompt from stdin, calls
# `copass discover` to surface related context, and injects the result
# into the conversation.
#
# stdout is BOTH visible to the user AND added as Claude context, so keep
# it tight. stderr -> logging only.

set -euo pipefail

# -- Ensure copass CLI exists ----------------------------------------
if ! command -v copass >/dev/null 2>&1; then
    echo "[Copass] copass CLI not found - install with: npm i -g @olane/o-cli"
    exit 0
fi

# -- jq is required for JSON parsing ---------------------------------
if ! command -v jq >/dev/null 2>&1; then
    echo "[Copass] jq not found - skipping ontology context injection"
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
RESPONSE="$(copass discover "${PROMPT}" "${PROJECT_ARGS[@]}" --json 2>/dev/null || true)"
if [ -z "${RESPONSE}" ]; then
    echo "[Copass] Discover failed - proceeding without ontology context"
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
    echo "[Copass] Discover returned unexpected payload - skipping"
    exit 0
fi

if [ "${COUNT}" = "0" ] || [ -z "${COUNT}" ]; then
    echo "[Copass] No related context found - continuing without ontology hints"
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
    echo "[Copass] No related context found - continuing without ontology hints"
    exit 0
fi

# -- Header + hint from response (with fallbacks) --------------------
HEADER="$(printf '%s' "${RESPONSE}" | jq -r '.header // empty' 2>/dev/null || true)"
HINT="$(printf '%s' "${RESPONSE}" | jq -r '.next_steps // empty' 2>/dev/null || true)"
if [ -z "${HINT}" ]; then
    HINT="Pass canonical_ids to \`copass interpret '[[\"cid1\",\"cid2\"]]'\` for a deeper brief."
fi

# -- Output (visible to user + injected as context) ------------------
if [ -n "${HEADER}" ]; then
    echo "[Copass] ${HEADER}"
else
    echo "[Copass] ${COUNT} related context item(s) discovered."
fi
echo ""
echo "${MENU}"
echo ""
echo "[Copass] ${HINT}"
