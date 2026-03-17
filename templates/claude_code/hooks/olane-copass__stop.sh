#!/usr/bin/env bash
# olane-copass__stop.sh — Stop hook for Copass.
# 1. If Claude's last message looks like a plan, scores it via
#    `olane cosync score` and blocks the stop so Claude appends
#    the Copass Scores to its response.
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

    # Detect plan-like content by looking for common plan indicators
    IS_PLAN=false
    if echo "${LAST_MSG}" | grep -qiE '(^#+\s*(plan|approach|strategy|steps|implementation)|step\s+[0-9]|phase\s+[0-9]|1\.\s|^\s*-\s.*\n\s*-\s|here.s (my|the|a) plan|i.ll proceed|proposed approach|before (we|i) (start|begin|proceed)|let me outline)'; then
        IS_PLAN=true
    fi

    if [ "${IS_PLAN}" = "true" ]; then
        _log "INFO" "Stop: plan detected, scoring via cosync"

        # Truncate to keep the cosync query reasonable
        PLAN_TEXT="$(_truncate "${LAST_MSG}" 2000)"

        SCORE_RESPONSE="$(_olane_cosync_score "${PLAN_TEXT}")" || {
            _log "WARN" "Stop: olane cosync score failed"
            SCORE_RESPONSE=""
        }

        if [ -n "${SCORE_RESPONSE}" ]; then
            AGG_SCORE="$(echo "${SCORE_RESPONSE}" | jq -r '.score // empty' 2>/dev/null || true)"

            if [ -n "${AGG_SCORE}" ]; then
                AGG_INT="$(_normalize_score "${AGG_SCORE}")"
                AGG_BAR="$(_progress_bar "${AGG_INT}")"

                # Build the scores display
                SCORES_MSG="━━ Copass Scores ━━"

                TERM_COUNT="$(echo "${SCORE_RESPONSE}" | jq -r '.terms // [] | length' 2>/dev/null || echo 0)"
                if [ "${TERM_COUNT}" -gt 0 ]; then
                    SCORES_MSG="${SCORES_MSG}\n"
                    for (( i=0; i<TERM_COUNT; i++ )); do
                        TERM_NAME="$(echo "${SCORE_RESPONSE}" | jq -r ".terms[${i}].term // .terms[${i}].name // \"term_${i}\"" 2>/dev/null || true)"
                        TERM_SCORE="$(echo "${SCORE_RESPONSE}" | jq -r ".terms[${i}].score // empty" 2>/dev/null || true)"
                        if [ -n "${TERM_SCORE}" ]; then
                            TERM_INT="$(_normalize_score "${TERM_SCORE}")"
                            TERM_BAR="$(_progress_bar "${TERM_INT}" 12)"
                            SCORES_MSG="${SCORES_MSG}\n  ${TERM_NAME}: ${TERM_BAR} ${TERM_INT}%"
                        fi
                    done
                fi

                SCORES_MSG="${SCORES_MSG}\n\n  Total: ${AGG_BAR} ${AGG_INT}%"

                _log "INFO" "Stop: cosync=${AGG_INT}% (${TERM_COUNT} terms) — blocking stop to inject scores"

                # Block the stop so Claude continues and shows the scores
                REASON="Output the following Copass Scores exactly as-is in a code block. Do not modify, summarize, or re-explain the plan. Just output the scores:\n\n\`\`\`\n${SCORES_MSG}\n\`\`\`"
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
        --source-id "${SESSION_ID}"
else
    _log "DEBUG" "No transcript file to ingest (path=${TRANSCRIPT_PATH})"
fi

# ── Respond ────────────────────────────────────────────────────────────
_respond '{"continue": true}'
