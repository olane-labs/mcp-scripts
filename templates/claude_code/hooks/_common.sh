#!/usr/bin/env bash
# _common.sh — Shared foundation for Copass Claude Code hooks.
# Sourced by each hook script. Provides config loading, logging,
# async API calls, encryption, and local fallback.
#
# IMPORTANT: Hooks must NEVER write arbitrary text to stdout.
# stdout is reserved for the JSON response to Claude Code.
# All logging goes to stderr + log file.

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────
OLANE_DIR="${OLANE_DIR:-.olane}"
OLANE_LOG_DIR="${OLANE_DIR}/logs"
OLANE_LOG_FILE="${OLANE_LOG_DIR}/hooks.log"
OLANE_FALLBACK_FILE="${OLANE_DIR}/observations.jsonl"
OLANE_CONFIG_FILE="${OLANE_DIR}/config.json"
OLANE_CRYPTO_SCRIPT="${OLANE_DIR}/scripts/olane_crypto.py"

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

OLANE_API_URL="${OLANE_API_URL:-}"
OLANE_USER_ID="${OLANE_USER_ID:-}"
OLANE_AUTH_TOKEN="${OLANE_AUTH_TOKEN:-}"
COPASS_ENCRYPTION_KEY="${COPASS_ENCRYPTION_KEY:-}"
OLANE_HOOKS_ENABLED="${OLANE_HOOKS_ENABLED:-}"
OLANE_PROJECT_ID="${OLANE_PROJECT_ID:-}"

_load_config() {
    # Try to read from config.json if jq is available
    if [ -f "${OLANE_CONFIG_FILE}" ] && command -v jq >/dev/null 2>&1; then
        if [ -z "${OLANE_API_URL}" ]; then
            OLANE_API_URL="$(jq -r '.api_url // empty' "${OLANE_CONFIG_FILE}" 2>/dev/null || true)"
        fi
        if [ -z "${OLANE_USER_ID}" ]; then
            OLANE_USER_ID="$(jq -r '.user_id // empty' "${OLANE_CONFIG_FILE}" 2>/dev/null || true)"
        fi
        if [ -z "${OLANE_AUTH_TOKEN}" ]; then
            OLANE_AUTH_TOKEN="$(jq -r '.auth_token // empty' "${OLANE_CONFIG_FILE}" 2>/dev/null || true)"
        fi
        if [ -z "${COPASS_ENCRYPTION_KEY}" ]; then
            COPASS_ENCRYPTION_KEY="$(jq -r '.copass_encryption_key // empty' "${OLANE_CONFIG_FILE}" 2>/dev/null || true)"
        fi
        if [ -z "${OLANE_HOOKS_ENABLED}" ]; then
            OLANE_HOOKS_ENABLED="$(jq -r '.hooks.enabled // empty' "${OLANE_CONFIG_FILE}" 2>/dev/null || true)"
        fi
        if [ -z "${OLANE_PROJECT_ID}" ]; then
            OLANE_PROJECT_ID="$(jq -r '.project_id // empty' "${OLANE_CONFIG_FILE}" 2>/dev/null || true)"
        fi
    fi

    # Apply defaults
    OLANE_API_URL="${OLANE_API_URL:-https://ai.copass.id}"
    OLANE_HOOKS_ENABLED="${OLANE_HOOKS_ENABLED:-true}"
}

_load_config

# ── Encryption ────────────────────────────────────────────────────────
# Requires COPASS_ENCRYPTION_KEY env var. Derives DEK once at load time.
OLANE_DEK_B64=""

_init_encryption() {
    if [ -z "${COPASS_ENCRYPTION_KEY:-}" ]; then
        _log "ERROR" "COPASS_ENCRYPTION_KEY is required for encryption"
        return 1
    fi

    if [ -f "${OLANE_CRYPTO_SCRIPT}" ]; then
        OLANE_DEK_B64="$(python3 "${OLANE_CRYPTO_SCRIPT}" get-dek 2>/dev/null)" || {
            _log "ERROR" "Failed to derive DEK from COPASS_ENCRYPTION_KEY"
            return 1
        }
    else
        _log "ERROR" "Crypto script not found: ${OLANE_CRYPTO_SCRIPT}"
        return 1
    fi
}

_encrypt_payload() {
    # Encrypt a JSON payload's "text" field. Returns JSON with encrypted fields.
    local payload="$1"
    echo "${payload}" | python3 "${OLANE_CRYPTO_SCRIPT}" encrypt --stdin 2>/dev/null
}

_encrypt_file() {
    # Encrypt a file. Returns JSON with encrypted_file_path, iv, tag.
    local file_path="$1"
    python3 "${OLANE_CRYPTO_SCRIPT}" encrypt-file --path "${file_path}" 2>/dev/null
}

# Initialize encryption (REQUIRED — hooks must not send unencrypted data)
if [ -z "${COPASS_ENCRYPTION_KEY:-}" ]; then
    _log "ERROR" "COPASS_ENCRYPTION_KEY is required. Set the env var or add 'copass_encryption_key' to .olane/config.json."
    _respond '{"continue": true}'
    exit 0
fi
_init_encryption || {
    _log "ERROR" "Encryption initialization failed — aborting hook"
    _respond '{"continue": true}'
    exit 0
}

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

# ── Async API Post ─────────────────────────────────────────────────────
_api_post_async() {
    local endpoint="$1"
    local payload="$2"
    local max_time="${3:-5}"

    # Encrypt payload (required — OLANE_DEK_B64 is always set by _init_encryption)
    local send_payload="${payload}"
    local encrypted
    encrypted="$(_encrypt_payload "${payload}" 2>/dev/null)" && send_payload="${encrypted}"

    local url="${OLANE_API_URL}${endpoint}"

    # Build auth header if token available
    local auth_args=()
    if [ -n "${OLANE_AUTH_TOKEN}" ]; then
        auth_args=(-H "Authorization: Bearer ${OLANE_AUTH_TOKEN}")
    fi

    # Encryption header (required)
    local enc_args=(-H "X-Encryption-Key: ${OLANE_DEK_B64}")

    # Fire-and-forget background curl
    (
        curl -s -X POST \
            -H "Content-Type: application/json" \
            "${auth_args[@]}" \
            "${enc_args[@]}" \
            -m "${max_time}" \
            -d "${send_payload}" \
            "${url}" >/dev/null 2>&1 || _local_fallback "${endpoint}" "${send_payload}"
    ) &
    disown 2>/dev/null || true
}

# ── Async File Upload ─────────────────────────────────────────────────
_api_upload_file_async() {
    local endpoint="$1"
    local file_path="$2"
    shift 2
    # Remaining args are extra -F fields, e.g. "source_type=agent_transcript"
    local extra_fields=("$@")

    local url="${OLANE_API_URL}${endpoint}"

    # Build auth header if token available
    local auth_args=()
    if [ -n "${OLANE_AUTH_TOKEN}" ]; then
        auth_args=(-H "Authorization: Bearer ${OLANE_AUTH_TOKEN}")
    fi

    # Encryption header (required)
    local enc_args=(-H "X-Encryption-Key: ${OLANE_DEK_B64}")

    # Encrypt file (required — OLANE_DEK_B64 is always set by _init_encryption)
    local upload_file="${file_path}"
    local enc_form_args=()
    local enc_result
    enc_result="$(_encrypt_file "${file_path}" 2>/dev/null)" && {
        local enc_file_path enc_iv enc_tag
        enc_file_path="$(echo "${enc_result}" | jq -r '.encrypted_file_path' 2>/dev/null)"
        enc_iv="$(echo "${enc_result}" | jq -r '.encryption_iv' 2>/dev/null)"
        enc_tag="$(echo "${enc_result}" | jq -r '.encryption_tag' 2>/dev/null)"
        if [ -n "${enc_file_path}" ] && [ -f "${enc_file_path}" ]; then
            upload_file="${enc_file_path}"
            enc_form_args=(-F "encryption_iv=${enc_iv}" -F "encryption_tag=${enc_tag}")
        fi
    }

    # Build -F flags for extra form fields
    local form_args=(-F "file=@${upload_file}")
    for field in "${extra_fields[@]}"; do
        form_args+=(-F "${field}")
    done

    # Fire-and-forget background curl (no Content-Type — curl sets multipart automatically)
    (
        curl -s -X POST \
            "${auth_args[@]}" \
            "${enc_args[@]}" \
            -m 30 \
            "${form_args[@]}" \
            "${enc_form_args[@]}" \
            "${url}" >/dev/null 2>&1 || _local_fallback "${endpoint}" "{\"file\":\"${file_path}\"}"
        # Clean up encrypted temp file
        if [ "${upload_file}" != "${file_path}" ] && [ -f "${upload_file}" ]; then
            rm -f "${upload_file}" 2>/dev/null || true
        fi
    ) &
    disown 2>/dev/null || true
}

# ── Local Fallback ─────────────────────────────────────────────────────
_local_fallback() {
    local endpoint="$1"
    local payload="$2"
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    if command -v jq >/dev/null 2>&1; then
        local record
        record="$(jq -nc \
            --arg ts "${ts}" \
            --arg ep "${endpoint}" \
            --argjson pl "${payload}" \
            '{timestamp: $ts, endpoint: $ep, payload: $pl}' 2>/dev/null)" \
        || record="$(jq -nc \
            --arg ts "${ts}" \
            --arg ep "${endpoint}" \
            --arg pl "${payload}" \
            '{timestamp: $ts, endpoint: $ep, payload_raw: $pl}')"
        echo "${record}" >> "${OLANE_FALLBACK_FILE}" 2>/dev/null || true
    else
        echo "{\"timestamp\":\"${ts}\",\"endpoint\":\"${endpoint}\",\"payload\":${payload}}" \
            >> "${OLANE_FALLBACK_FILE}" 2>/dev/null || true
    fi
    _log "WARN" "API unreachable — saved to local fallback: ${endpoint}"
}

# ── Truncate helper ────────────────────────────────────────────────────
_truncate() {
    # Truncate a string to max length, appending "..." if truncated.
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
