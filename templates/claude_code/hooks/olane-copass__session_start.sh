#!/usr/bin/env bash
# olane-copass__session_start.sh
# SessionStart hook: expose the Claude Code session_id via two channels so
# subprocess tools (notably the copass MCP server and `copass discover`) can
# resolve the active transcript without an mtime-guessing race.
#
#   1. hookSpecificOutput.additionalContext -> model sees it in a system reminder
#   2. $CLAUDE_ENV_FILE                     -> exported into tool-call environments
#
# Workaround for anthropics/claude-code#25642 (no $CLAUDE_SESSION_ID env yet).

set -euo pipefail

INPUT="$(cat || true)"
if [ -z "${INPUT}" ]; then
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

SESSION_ID="$(printf '%s' "${INPUT}" | jq -r '.session_id // empty' 2>/dev/null || true)"
if [ -z "${SESSION_ID}" ]; then
    exit 0
fi

jq -n --arg ctx "CLAUDE_CODE_SESSION_ID=${SESSION_ID}" '{
    hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: $ctx
    }
}'

# Append (not overwrite) so we don't clobber env written by other hooks. The
# grep guard prevents duplicate entries when the hook re-fires for the same
# env file (resume/continue/compaction).
if [ -n "${CLAUDE_ENV_FILE:-}" ] && ! grep -q "CLAUDE_CODE_SESSION_ID" "${CLAUDE_ENV_FILE}" 2>/dev/null; then
    printf 'export CLAUDE_CODE_SESSION_ID=%q\n' "${SESSION_ID}" >> "${CLAUDE_ENV_FILE}"
fi
