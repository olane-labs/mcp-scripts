#!/usr/bin/env bash
# olane-copass__stop.sh
# Stop hook: scores plans via cosync before Claude stops,
# and ingests the assistant's response asynchronously.
#
# stdout → JSON response for Claude Code (ONLY output channel)
# stderr → logging

set -euo pipefail

# ── Ensure olane CLI exists ──────────────────────────────────────────
if ! command -v olane >/dev/null 2>&1; then
    echo '{"continue": true}'
    exit 0
fi

# ── Read event from stdin ────────────────────────────────────────────
EVENT="$(cat)"
if [ -z "${EVENT}" ]; then
    echo '{"continue": true}'
    exit 0
fi

# ── Extract fields ───────────────────────────────────────────────────
jq_field() { echo "${EVENT}" | jq -r "$1 // empty" 2>/dev/null || true; }

SESSION_ID="$(jq_field '.session_id')"
LAST_MSG="$(jq_field '.last_assistant_message')"
STOP_HOOK_ACTIVE="$(jq_field '.stop_hook_active')"

# ── Project ID (optional) ───────────────────────────────────────────
PROJECT_ARGS=()
CONFIG_FILE=".olane/config.json"
if [ -f "${CONFIG_FILE}" ] && command -v jq >/dev/null 2>&1; then
    PID="$(jq -r '.project_id // empty' "${CONFIG_FILE}" 2>/dev/null || true)"
    if [ -n "${PID}" ]; then
        PROJECT_ARGS=(--project-id "${PID}")
    fi
fi

# ── JSON helpers ─────────────────────────────────────────────────────
json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo "${str}"
}

normalize_score() {
    echo "$1" | awk '{ if ($1 <= 1.0 && $1 >= 0.0) printf "%d", $1 * 100; else printf "%d", $1; }'
}

progress_bar() {
    local score="$1" width="${2:-20}" bar=""
    local filled=$(( score * width / 100 ))
    local empty=$(( width - filled ))
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty; i++ )); do bar+="░"; done
    echo "${bar}"
}

truncate_str() {
    local str="$1" max="${2:-2000}"
    if [ "${#str}" -gt "${max}" ]; then echo "${str:0:${max}}..."; else echo "${str}"; fi
}

# ── Plan detection + cosync scoring (first stop only) ────────────────
if [ "${STOP_HOOK_ACTIVE}" != "true" ] && [ -n "${LAST_MSG}" ]; then

    if echo "${LAST_MSG}" | grep -qiE '(^#+\s*(plan|approach|strategy|steps|implementation)|step\s+[0-9]|phase\s+[0-9]|1\.\s|^\s*-\s.*\n\s*-\s|here.s (my|the|a) plan|i.ll proceed|proposed approach|before (we|i) (start|begin|proceed)|let me outline)'; then

        PLAN_TEXT="$(truncate_str "${LAST_MSG}" 2000)"

        SCORE_RESPONSE="$(olane copass score "${PLAN_TEXT}" "${PROJECT_ARGS[@]}" --json 2>/dev/null)" || SCORE_RESPONSE=""

        if [ -n "${SCORE_RESPONSE}" ]; then
            AGG_SCORE="$(echo "${SCORE_RESPONSE}" | jq -r '.score // empty' 2>/dev/null || true)"

            if [ -n "${AGG_SCORE}" ]; then
                AGG_INT="$(normalize_score "${AGG_SCORE}")"
                AGG_BAR="$(progress_bar "${AGG_INT}")"

                SCORES_MSG="━━ Copass Scores ━━"
                TERM_COUNT="$(echo "${SCORE_RESPONSE}" | jq -r '.terms // [] | length' 2>/dev/null || echo 0)"
                HIGH_TERMS=""

                if [ "${TERM_COUNT}" -gt 0 ]; then
                    SCORES_MSG="${SCORES_MSG}\n"
                    for (( i=0; i<TERM_COUNT; i++ )); do
                        TERM_NAME="$(echo "${SCORE_RESPONSE}" | jq -r ".terms[${i}].term // .terms[${i}].name // \"term_${i}\"" 2>/dev/null || true)"
                        TERM_SCORE="$(echo "${SCORE_RESPONSE}" | jq -r ".terms[${i}].score // empty" 2>/dev/null || true)"
                        if [ -n "${TERM_SCORE}" ]; then
                            TERM_INT="$(normalize_score "${TERM_SCORE}")"
                            TERM_BAR="$(progress_bar "${TERM_INT}" 12)"
                            SCORES_MSG="${SCORES_MSG}\n  ${TERM_NAME}: ${TERM_BAR} ${TERM_INT}%"
                            if [ "${TERM_INT}" -ge 50 ]; then
                                HIGH_TERMS="${HIGH_TERMS:+${HIGH_TERMS}|}${TERM_NAME}|${TERM_INT}"
                            fi
                        fi
                    done
                fi

                SCORES_MSG="${SCORES_MSG}\n\n  Total: ${AGG_BAR} ${AGG_INT}%"

                # Fetch learning context for high-scoring terms
                LEARNING_MSG=""
                if [ -n "${HIGH_TERMS}" ]; then
                    IFS='|' read -ra TERM_PARTS <<< "${HIGH_TERMS}"
                    idx=0
                    while [ ${idx} -lt ${#TERM_PARTS[@]} ]; do
                        T_NAME="${TERM_PARTS[${idx}]}"
                        T_SCORE="${TERM_PARTS[$(( idx + 1 ))]}"
                        idx=$(( idx + 2 ))

                        LR="$(olane copass context --text-input "${T_NAME}" "${PROJECT_ARGS[@]}" --json 2>/dev/null)" || continue
                        LC="$(echo "${LR}" | jq -r '.context // .summary // .content // empty' 2>/dev/null || true)"
                        if [ -n "${LC}" ]; then
                            LC_TRUNC="$(truncate_str "${LC}" 500)"
                            LEARNING_MSG="${LEARNING_MSG}\n\n**${T_NAME}** (${T_SCORE}%):\n> ${LC_TRUNC}"
                        fi
                    done
                fi

                REASON="Output the following Copass Scores exactly as-is in a code block. Do not modify, summarize, or re-explain the plan.\n\n\`\`\`\n${SCORES_MSG}\n\`\`\`"
                if [ -n "${LEARNING_MSG}" ]; then
                    REASON="${REASON}\n\nCopass has the following context for the key entities in this plan:${LEARNING_MSG}\n\nUse this context to validate your plan. For any items Copass scored low on, confirm your understanding with the user since Copass does not have strong context for those."
                fi

                REASON_ESC="$(json_escape "${REASON}")"
                echo "{\"decision\":\"block\",\"reason\":\"${REASON_ESC}\"}"
                exit 0
            fi
        fi
    fi
fi

# ── Ingest assistant response asynchronously ─────────────────────────
if [ -n "${LAST_MSG}" ]; then
    (
        echo "${LAST_MSG}" | olane ingest text \
            --source-type "agent_transcript" \
            "${PROJECT_ARGS[@]}" \
            --json 2>/dev/null || true
    ) &
    disown 2>/dev/null || true
fi

echo '{"continue": true}'
