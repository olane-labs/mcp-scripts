#!/usr/bin/env bash
# olane-copass__permission_request.sh — PermissionRequest hook for Copass.
# Calls `olane cosync score` for the requested action and displays
# per-term breakdown + aggregate cosync score via systemMessage.
#
# Does NOT auto-approve or auto-deny — the user always decides.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/olane-copass__common.sh"

_read_event
_check_enabled

# ── Extract permission request details ───────────────────────────────
TOOL_NAME="$(_jq '.tool_name')"
TOOL_INPUT="$(echo "${HOOK_EVENT}" | jq -c '.tool_input // {}' 2>/dev/null || echo '{}')"

if [ -z "${TOOL_NAME}" ]; then
    exit 0
fi

_log "INFO" "PermissionRequest: tool=${TOOL_NAME}"

# ── Build a concise description of the request ──────────────────────
DESCRIPTION=""
case "${TOOL_NAME}" in
    Bash)
        CMD="$(echo "${TOOL_INPUT}" | jq -r '.command // empty' 2>/dev/null || true)"
        DESC="$(echo "${TOOL_INPUT}" | jq -r '.description // empty' 2>/dev/null || true)"
        DESCRIPTION="${DESC:-${CMD}}"
        ;;
    Edit)
        FPATH="$(echo "${TOOL_INPUT}" | jq -r '.file_path // empty' 2>/dev/null || true)"
        DESCRIPTION="Edit ${FPATH}"
        ;;
    Write)
        FPATH="$(echo "${TOOL_INPUT}" | jq -r '.file_path // empty' 2>/dev/null || true)"
        DESCRIPTION="Write ${FPATH}"
        ;;
    mcp__*)
        CLEAN_NAME="$(echo "${TOOL_NAME}" | sed 's/^mcp__//;s/__/\//')"
        DESCRIPTION="MCP: ${CLEAN_NAME}"
        ;;
    *)
        DESCRIPTION="${TOOL_NAME}"
        ;;
esac

# ── Get cosync score via olane CLI ───────────────────────────────────
SCORE_RESPONSE="$(_olane_cosync_score "${DESCRIPTION}")" || {
    _log "WARN" "PermissionRequest: olane cosync score failed"
    exit 0
}

if [ -z "${SCORE_RESPONSE}" ]; then
    _log "DEBUG" "PermissionRequest: empty cosync response"
    exit 0
fi

# ── Parse aggregate score ────────────────────────────────────────────
AGG_SCORE="$(echo "${SCORE_RESPONSE}" | jq -r '.score // empty' 2>/dev/null || true)"

if [ -z "${AGG_SCORE}" ]; then
    _log "DEBUG" "PermissionRequest: no cosync score returned"
    exit 0
fi

AGG_INT="$(_normalize_score "${AGG_SCORE}")"
AGG_BAR="$(_progress_bar "${AGG_INT}")"

# ── Build display ────────────────────────────────────────────────────
# Header
MSG="━━ Copass Scores ━━"

# Per-term breakdown
TERM_COUNT="$(echo "${SCORE_RESPONSE}" | jq -r '.terms // [] | length' 2>/dev/null || echo 0)"

if [ "${TERM_COUNT}" -gt 0 ]; then
    MSG="${MSG}\n"
    # Iterate terms and build a line for each
    for (( i=0; i<TERM_COUNT; i++ )); do
        TERM_NAME="$(echo "${SCORE_RESPONSE}" | jq -r ".terms[${i}].term // .terms[${i}].name // \"term_${i}\"" 2>/dev/null || true)"
        TERM_SCORE="$(echo "${SCORE_RESPONSE}" | jq -r ".terms[${i}].score // empty" 2>/dev/null || true)"
        if [ -n "${TERM_SCORE}" ]; then
            TERM_INT="$(_normalize_score "${TERM_SCORE}")"
            TERM_BAR="$(_progress_bar "${TERM_INT}" 12)"
            MSG="${MSG}\n  ${TERM_NAME}: ${TERM_BAR} ${TERM_INT}%"
        fi
    done
fi

# Aggregate total
MSG="${MSG}\n\n  Total: ${AGG_BAR} ${AGG_INT}%"

_log "INFO" "PermissionRequest: cosync=${AGG_INT}% (${TERM_COUNT} terms) for ${DESCRIPTION}"

MSG_ESC="$(_json_escape "${MSG}")"
cat <<ENDJSON
{"systemMessage":"${MSG_ESC}"}
ENDJSON
