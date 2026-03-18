#!/usr/bin/env bash
# olane-copass__stop.sh — Stop hook for Copass.
# 1. If Claude's last message looks like a plan:
#    a. Scores it via `olane cosync score`
#    b. For high-scoring terms (>=50%), fetches learning requests
#       to provide Copass's known context for key entities
#    c. Blocks the stop so Claude shows scores and validates its plan
# 2. Ingests the session transcript via olane CLI.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/olane-copass__common.sh"

_read_event
_check_enabled

# ── Extract fields ─────────────────────────────────────────────────────
SESSION_ID="$(_jq '.session_id')"
TRANSCRIPT_PATH="$(_jq '.transcript_path')"
LAST_MSG="$(_jq '.last_assistant_message')"
STOP_HOOK_ACTIVE="$(_jq '.stop_hook_active')"

_log "INFO" "Stop: session=${SESSION_ID} stop_hook_active=${STOP_HOOK_ACTIVE}"

# ── Plan detection + cosync scoring ────────────────────────────────────
# Only run on first stop (stop_hook_active=false) to prevent infinite loops.
if [ "${STOP_HOOK_ACTIVE}" != "true" ] && [ -n "${LAST_MSG}" ]; then

    IS_PLAN=false
    if echo "${LAST_MSG}" | grep -qiE '(^#+\s*(plan|approach|strategy|steps|implementation)|step\s+[0-9]|phase\s+[0-9]|1\.\s|^\s*-\s.*\n\s*-\s|here.s (my|the|a) plan|i.ll proceed|proposed approach|before (we|i) (start|begin|proceed)|let me outline)'; then
        IS_PLAN=true
    fi

    if [ "${IS_PLAN}" = "true" ]; then
        _log "INFO" "Stop: plan detected, scoring via cosync"

        PLAN_TEXT="$(_truncate "${LAST_MSG}" 2000)"

        # ── Step 1: Get cosync scores ────────────────────────────────
        SCORE_RESPONSE="$(_olane_cosync_score "${PLAN_TEXT}")" || {
            _log "WARN" "Stop: olane cosync score failed"
            SCORE_RESPONSE=""
        }

        if [ -n "${SCORE_RESPONSE}" ]; then
            AGG_SCORE="$(echo "${SCORE_RESPONSE}" | jq -r '.score // empty' 2>/dev/null || true)"

            if [ -n "${AGG_SCORE}" ]; then
                AGG_INT="$(_normalize_score "${AGG_SCORE}")"
                AGG_BAR="$(_progress_bar "${AGG_INT}")"

                # Build scores display
                SCORES_MSG="━━ Copass Scores ━━"

                TERM_COUNT="$(echo "${SCORE_RESPONSE}" | jq -r '.terms // [] | length' 2>/dev/null || echo 0)"
                HIGH_TERMS=""

                if [ "${TERM_COUNT}" -gt 0 ]; then
                    SCORES_MSG="${SCORES_MSG}\n"
                    for (( i=0; i<TERM_COUNT; i++ )); do
                        TERM_NAME="$(echo "${SCORE_RESPONSE}" | jq -r ".terms[${i}].term // .terms[${i}].name // \"term_${i}\"" 2>/dev/null || true)"
                        TERM_SCORE="$(echo "${SCORE_RESPONSE}" | jq -r ".terms[${i}].score // empty" 2>/dev/null || true)"
                        if [ -n "${TERM_SCORE}" ]; then
                            TERM_INT="$(_normalize_score "${TERM_SCORE}")"
                            TERM_BAR="$(_progress_bar "${TERM_INT}" 12)"
                            SCORES_MSG="${SCORES_MSG}\n  ${TERM_NAME}: ${TERM_BAR} ${TERM_INT}%"

                            # Track high-scoring terms (>=50%) for learning requests
                            if [ "${TERM_INT}" -ge 50 ]; then
                                if [ -n "${HIGH_TERMS}" ]; then
                                    HIGH_TERMS="${HIGH_TERMS}|${TERM_NAME}|${TERM_INT}"
                                else
                                    HIGH_TERMS="${TERM_NAME}|${TERM_INT}"
                                fi
                            fi
                        fi
                    done
                fi

                SCORES_MSG="${SCORES_MSG}\n\n  Total: ${AGG_BAR} ${AGG_INT}%"

                # ── Step 2: Get learning requests for high-score terms ───
                LEARNING_MSG=""

                if [ -n "${HIGH_TERMS}" ]; then
                    _log "INFO" "Stop: fetching learning requests for high-score terms"

                    # Parse HIGH_TERMS (format: "term1|score1|term2|score2|...")
                    IFS='|' read -ra TERM_PARTS <<< "${HIGH_TERMS}"
                    idx=0
                    while [ ${idx} -lt ${#TERM_PARTS[@]} ]; do
                        T_NAME="${TERM_PARTS[${idx}]}"
                        T_SCORE="${TERM_PARTS[$(( idx + 1 ))]}"
                        idx=$(( idx + 2 ))

                        LEARNING_RESPONSE="$(_olane_learning_requests "${T_NAME}")" || {
                            _log "WARN" "Stop: learning request failed for '${T_NAME}'"
                            continue
                        }

                        LEARNING_CONTEXT=""
                        if [ -n "${LEARNING_RESPONSE}" ] && command -v jq >/dev/null 2>&1; then
                            LEARNING_CONTEXT="$(echo "${LEARNING_RESPONSE}" | jq -r '.context // .summary // .content // empty' 2>/dev/null || true)"
                        fi

                        if [ -n "${LEARNING_CONTEXT}" ]; then
                            LEARNING_CONTEXT_TRUNC="$(_truncate "${LEARNING_CONTEXT}" 500)"
                            LEARNING_MSG="${LEARNING_MSG}\n\n**${T_NAME}** (${T_SCORE}%):\n> ${LEARNING_CONTEXT_TRUNC}"
                        fi
                    done
                fi

                _log "INFO" "Stop: cosync=${AGG_INT}% (${TERM_COUNT} terms) — blocking stop to inject scores"

                # ── Step 3: Build the block reason ───────────────────────
                REASON="Output the following Copass Scores exactly as-is in a code block. Do not modify, summarize, or re-explain the plan.\n\n\`\`\`\n${SCORES_MSG}\n\`\`\`"

                if [ -n "${LEARNING_MSG}" ]; then
                    REASON="${REASON}\n\nCopass has the following context for the key entities in this plan:${LEARNING_MSG}\n\nUse this context to validate your plan. For any items Copass scored low on, confirm your understanding with the user since Copass does not have strong context for those."
                fi

                REASON_ESC="$(_json_escape "${REASON}")"
                _respond "{\"decision\":\"block\",\"reason\":\"${REASON_ESC}\"}"
                exit 0
            fi
        fi
    fi
fi

# ── Ingest transcript via olane CLI ────────────────────────────────────
if [ -n "${TRANSCRIPT_PATH}" ] && [ -f "${TRANSCRIPT_PATH}" ]; then
    _log "INFO" "Ingesting transcript: ${TRANSCRIPT_PATH}"
    _olane_ingest_file_async "${TRANSCRIPT_PATH}" "agent_transcript" \
        --additional-context "session_id=${SESSION_ID}"
else
    _log "DEBUG" "No transcript file to ingest (path=${TRANSCRIPT_PATH})"
fi

# ── Respond ────────────────────────────────────────────────────────────
_respond '{"continue": true}'
