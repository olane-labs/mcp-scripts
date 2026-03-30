#!/usr/bin/env bash
# olane-copass__common.sh — Shared foundation for Copass Claude Code hooks.
# Sourced by each hook script. Provides config loading, logging,
# olane CLI wrappers, and local fallback.
#
# IMPORTANT: Hooks must NEVER write arbitrary text to stdout.
# stdout is reserved for the JSON response to Claude Code.
# All logging goes to stderr + log file.
#
# All networking and crypto is delegated to the `olane` CLI.

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────
OLANE_DIR="${OLANE_DIR:-.olane}"
OLANE_LOG_DIR="${OLANE_DIR}/logs"
OLANE_LOG_FILE="${OLANE_LOG_DIR}/hooks.log"
OLANE_FALLBACK_FILE="${OLANE_DIR}/observations.jsonl"
OLANE_CONFIG_FILE="${OLANE_DIR}/config.json"

# Ensure log directory exists
mkdir -p "${OLANE_LOG_DIR}" 2>/dev/null || true

# ── Logging ────────────────────────────────────────────────────────────
_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    local line="[${ts}] [${level}] ${msg}"
    echo "${line}" >&2
    echo "${line}" >> "${OLANE_LOG_FILE}" 2>/dev/null || true
}

# ── Config Loading ─────────────────────────────────────────────────────
# Layered precedence: env vars > .olane/config.json > defaults

OLANE_HOOKS_ENABLED="${OLANE_HOOKS_ENABLED:-}"
OLANE_PROJECT_ID="${OLANE_PROJECT_ID:-}"

_load_config() {
    if [ -f "${OLANE_CONFIG_FILE}" ] && command -v jq >/dev/null 2>&1; then
        if [ -z "${OLANE_HOOKS_ENABLED}" ]; then
            OLANE_HOOKS_ENABLED="$(jq -r '.hooks.enabled // empty' "${OLANE_CONFIG_FILE}" 2>/dev/null || true)"
        fi
        if [ -z "${OLANE_PROJECT_ID}" ]; then
            OLANE_PROJECT_ID="$(jq -r '.project_id // empty' "${OLANE_CONFIG_FILE}" 2>/dev/null || true)"
        fi
    fi

    # Apply defaults
    OLANE_HOOKS_ENABLED="${OLANE_HOOKS_ENABLED:-true}"
}

_load_config

# ── Verify olane CLI ──────────────────────────────────────────────────
if ! command -v olane >/dev/null 2>&1; then
    _log "ERROR" "olane CLI not found in PATH — hooks require it"
    echo '{"continue": true}' # respond so Claude Code doesn't hang
    exit 0
fi

# ── Check Enabled ──────────────────────────────────────────────────────
_check_enabled() {
    if [ "${OLANE_HOOKS_ENABLED}" != "true" ]; then
        _log "DEBUG" "Hooks disabled — exiting"
        _respond '{"continue": true}'
        exit 0
    fi
}

# ── Read Event from stdin ──────────────────────────────────────────────
HOOK_EVENT=""

_read_event() {
    HOOK_EVENT="$(cat)"
    if [ -z "${HOOK_EVENT}" ]; then
        _log "WARN" "Empty event on stdin"
        _respond '{"continue": true}'
        exit 0
    fi
}

# ── JSON field extraction ──────────────────────────────────────────────
_jq() {
    # Extract a field from HOOK_EVENT using jq.
    # Returns empty string if jq missing or field absent.
    if command -v jq >/dev/null 2>&1; then
        echo "${HOOK_EVENT}" | jq -r "$1 // empty" 2>/dev/null || true
    fi
}

# ── Respond ────────────────────────────────────────────────────────────
_respond() {
    # Write JSON response to stdout (the ONLY thing that goes to stdout).
    echo "$1"
}

# ── olane CLI wrappers ────────────────────────────────────────────────
# All networking and encryption is handled by the olane CLI.

_olane_ingest_text() {
    # Ingest text via olane CLI (piped through stdin).
    local text="$1"
    local source_type="$2"
    shift 2
    local extra_args=("$@")

    local project_args=()
    if [ -n "${OLANE_PROJECT_ID}" ]; then
        project_args=(--project-id "${OLANE_PROJECT_ID}")
    fi

    echo "${text}" | olane ingest text \
        --source-type "${source_type}" \
        "${project_args[@]}" \
        "${extra_args[@]}" \
        --json 2>/dev/null
}

_olane_ingest_text_async() {
    # Fire-and-forget text ingestion.
    local text="$1"
    local source_type="$2"
    shift 2
    local extra_args=("$@")

    (
        _olane_ingest_text "${text}" "${source_type}" "${extra_args[@]}" \
            || _local_fallback "ingest/text" "{\"source_type\":\"${source_type}\"}"
    ) &
    disown 2>/dev/null || true
}

_olane_ingest_file() {
    # Ingest a file via olane CLI (passed as positional arg).
    local file_path="$1"
    local source_type="$2"
    shift 2
    local extra_args=("$@")

    local project_args=()
    if [ -n "${OLANE_PROJECT_ID}" ]; then
        project_args=(--project-id "${OLANE_PROJECT_ID}")
    fi

    olane ingest text "${file_path}" \
        --source-type "${source_type}" \
        "${project_args[@]}" \
        "${extra_args[@]}" \
        --json 2>/dev/null
}

_olane_ingest_file_async() {
    # Fire-and-forget file ingestion.
    local file_path="$1"
    local source_type="$2"
    shift 2
    local extra_args=("$@")

    (
        _olane_ingest_file "${file_path}" "${source_type}" "${extra_args[@]}" \
            || _local_fallback "ingest/file" "{\"file\":\"${file_path}\"}"
    ) &
    disown 2>/dev/null || true
}

_olane_context_query() {
    # Query knowledge graph via olane CLI. Returns JSON response on stdout.
    local query="$1"
    shift
    local extra_args=("$@")

    local project_args=()
    if [ -n "${OLANE_PROJECT_ID}" ]; then
        project_args=(--project-id "${OLANE_PROJECT_ID}")
    fi

    olane copass question "${query}" \
        "${project_args[@]}" \
        "${extra_args[@]}" \
        --json 2>/dev/null
}

_olane_cosync_score() {
    # Get cosync score for a query. Returns JSON with score and details.
    local query="$1"
    shift
    local extra_args=("$@")

    local project_args=()
    if [ -n "${OLANE_PROJECT_ID}" ]; then
        project_args=(--project-id "${OLANE_PROJECT_ID}")
    fi

    olane copass score "${query}" \
        "${project_args[@]}" \
        "${extra_args[@]}" \
        --json 2>/dev/null
}

_olane_learning_requests() {
    # Get context summary for given terms via copass context.
    local query="$1"
    shift
    local extra_args=("$@")

    local project_args=()
    if [ -n "${OLANE_PROJECT_ID}" ]; then
        project_args=(--project-id "${OLANE_PROJECT_ID}")
    fi

    olane copass context \
        --text-input "${query}" \
        "${project_args[@]}" \
        "${extra_args[@]}" \
        --json 2>/dev/null
}

# ── Local Fallback ─────────────────────────────────────────────────────
_local_fallback() {
    local source="$1"
    local payload="$2"
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    if command -v jq >/dev/null 2>&1; then
        local record
        record="$(jq -nc \
            --arg ts "${ts}" \
            --arg src "${source}" \
            --arg pl "${payload}" \
            '{timestamp: $ts, source: $src, payload_raw: $pl}')"
        echo "${record}" >> "${OLANE_FALLBACK_FILE}" 2>/dev/null || true
    else
        echo "{\"timestamp\":\"${ts}\",\"source\":\"${source}\",\"payload\":${payload}}" \
            >> "${OLANE_FALLBACK_FILE}" 2>/dev/null || true
    fi
    _log "WARN" "olane CLI failed — saved to local fallback: ${source}"
}

# ── Truncate helper ────────────────────────────────────────────────────
_truncate() {
    local str="$1"
    local max="${2:-500}"
    if [ "${#str}" -gt "${max}" ]; then
        echo "${str:0:${max}}..."
    else
        echo "${str}"
    fi
}

# ── JSON escape helper ────────────────────────────────────────────────
_json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo "${str}"
}

# ── Normalize score helper ────────────────────────────────────────────
_normalize_score() {
    # Convert a score (0.0-1.0 float or 0-100 integer) to 0-100 integer.
    local score="$1"
    echo "${score}" | awk '{
        if ($1 <= 1.0 && $1 >= 0.0) printf "%d", $1 * 100;
        else printf "%d", $1;
    }'
}

# ── Progress bar helper ──────────────────────────────────────────────
_progress_bar() {
    # Render a text progress bar. Args: score (0-100) [width]
    local score="$1"
    local width="${2:-20}"
    local filled=$(( score * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty; i++ )); do bar+="░"; done
    echo "${bar}"
}
