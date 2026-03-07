#!/usr/bin/env python3
"""
Client-side encryption for Twin Brain data pipeline.

Provides AES-256-GCM encryption with HKDF-SHA256 key derivation from a master key.
Used by both CLI (Bash hooks) and Python code (MCP tools, index_project.py).

Key derivation is deterministic: same master key always produces the same DEK.
The DEK is sent per-request via X-Encryption-Key header (over TLS).
The backend uses the DEK immediately and never persists it.

Dependencies: cryptography (pip install cryptography)

CLI Usage:
    # Encrypt JSON payload from stdin
    echo '{"text":"hello"}' | python3 olane_crypto.py encrypt --stdin
    # → {"encrypted_text":"b64...","encryption_iv":"b64...","encryption_tag":"b64..."}

    # Encrypt a file
    python3 olane_crypto.py encrypt-file --path /path/to/file
    # → {"encrypted_file_path":"/tmp/olane_enc_xxx","encryption_iv":"b64...","encryption_tag":"b64..."}

    # Get DEK as base64 (for X-Encryption-Key header)
    python3 olane_crypto.py get-dek
    # → base64-encoded DEK

Python API:
    from olane_crypto import OlaneCrypto
    crypto = OlaneCrypto(copass_encryption_key=os.environ["COPASS_ENCRYPTION_KEY"])
    encrypted = crypto.encrypt("plaintext")    # → dict with encrypted_text, encryption_iv, encryption_tag
    plaintext = crypto.decrypt(encrypted)      # → str
    dek_b64 = crypto.dek_b64                   # → base64 string for header
"""

import base64
import json
import os
import sys
import tempfile

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

# Fixed salt for deterministic key derivation
_HKDF_SALT = b"olane-twin-brain-dek-v1"
_HKDF_INFO = b"olane-dek"


def derive_dek(copass_encryption_key: str) -> bytes:
    """
    Derive a 256-bit DEK from a master key using HKDF-SHA256.

    Deterministic: same copass_encryption_key always produces the same DEK.

    Args:
        copass_encryption_key: The master key string (from COPASS_ENCRYPTION_KEY env var)

    Returns:
        32-byte DEK suitable for AES-256-GCM
    """
    hkdf = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=_HKDF_SALT,
        info=_HKDF_INFO,
    )
    return hkdf.derive(copass_encryption_key.encode("utf-8"))


def encrypt(plaintext: str, dek: bytes) -> dict:
    """
    Encrypt plaintext with AES-256-GCM.

    Args:
        plaintext: UTF-8 string to encrypt
        dek: 32-byte DEK from derive_dek()

    Returns:
        Dict with base64-encoded fields:
        {
            "encrypted_text": "<base64 ciphertext>",
            "encryption_iv": "<base64 IV>",
            "encryption_tag": "<base64 auth tag>"
        }
    """
    aesgcm = AESGCM(dek)
    iv = os.urandom(12)  # 96-bit nonce for GCM
    # AESGCM.encrypt() appends the 16-byte tag to ciphertext
    ciphertext_with_tag = aesgcm.encrypt(iv, plaintext.encode("utf-8"), None)
    # Split: last 16 bytes are the authentication tag
    ciphertext = ciphertext_with_tag[:-16]
    tag = ciphertext_with_tag[-16:]

    return {
        "encrypted_text": base64.b64encode(ciphertext).decode("ascii"),
        "encryption_iv": base64.b64encode(iv).decode("ascii"),
        "encryption_tag": base64.b64encode(tag).decode("ascii"),
    }


def decrypt(encrypted_text_b64: str, iv_b64: str, tag_b64: str, dek: bytes) -> str:
    """
    Decrypt AES-256-GCM ciphertext.

    Args:
        encrypted_text_b64: Base64-encoded ciphertext
        iv_b64: Base64-encoded IV (12 bytes)
        tag_b64: Base64-encoded authentication tag (16 bytes)
        dek: 32-byte DEK from derive_dek()

    Returns:
        Decrypted plaintext string

    Raises:
        cryptography.exceptions.InvalidTag: If decryption fails (wrong key or tampered data)
    """
    ciphertext = base64.b64decode(encrypted_text_b64)
    iv = base64.b64decode(iv_b64)
    tag = base64.b64decode(tag_b64)

    aesgcm = AESGCM(dek)
    # AESGCM.decrypt() expects ciphertext + tag concatenated
    plaintext_bytes = aesgcm.decrypt(iv, ciphertext + tag, None)
    return plaintext_bytes.decode("utf-8")


def encrypt_file(path: str, dek: bytes) -> dict:
    """
    Encrypt a file to a temporary path.

    Args:
        path: Path to the file to encrypt
        dek: 32-byte DEK from derive_dek()

    Returns:
        Dict with:
        {
            "encrypted_file_path": "/tmp/olane_enc_xxx",
            "encryption_iv": "<base64 IV>",
            "encryption_tag": "<base64 auth tag>"
        }
    """
    with open(path, "r", encoding="utf-8") as f:
        plaintext = f.read()

    result = encrypt(plaintext, dek)

    # Write encrypted content to temp file
    fd, tmp_path = tempfile.mkstemp(prefix="olane_enc_", suffix=".bin")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(base64.b64decode(result["encrypted_text"]))
    except Exception:
        os.unlink(tmp_path)
        raise

    return {
        "encrypted_file_path": tmp_path,
        "encryption_iv": result["encryption_iv"],
        "encryption_tag": result["encryption_tag"],
    }


class OlaneCrypto:
    """
    High-level encryption interface for Python code.

    Usage:
        crypto = OlaneCrypto(copass_encryption_key=os.environ["COPASS_ENCRYPTION_KEY"])
        encrypted = crypto.encrypt("plaintext")
        plaintext = crypto.decrypt(encrypted)
        dek_b64 = crypto.dek_b64  # for X-Encryption-Key header
    """

    def __init__(self, copass_encryption_key: str):
        """
        Initialize with master key. Derives DEK immediately.

        Args:
            copass_encryption_key: The master key string (from COPASS_ENCRYPTION_KEY env var)

        Raises:
            ValueError: If copass_encryption_key is empty
        """
        if not copass_encryption_key:
            raise ValueError("COPASS_ENCRYPTION_KEY must not be empty")
        self._dek = derive_dek(copass_encryption_key)

    @property
    def dek_b64(self) -> str:
        """Get DEK as base64 string (for X-Encryption-Key header)."""
        return base64.b64encode(self._dek).decode("ascii")

    def encrypt(self, plaintext: str) -> dict:
        """
        Encrypt plaintext string.

        Returns:
            Dict with encrypted_text, encryption_iv, encryption_tag (all base64)
        """
        return encrypt(plaintext, self._dek)

    def decrypt(self, encrypted: dict) -> str:
        """
        Decrypt from a dict with encrypted_text, encryption_iv, encryption_tag.

        Args:
            encrypted: Dict with base64-encoded encrypted_text, encryption_iv, encryption_tag

        Returns:
            Decrypted plaintext string
        """
        return decrypt(
            encrypted["encrypted_text"],
            encrypted["encryption_iv"],
            encrypted["encryption_tag"],
            self._dek,
        )

    def encrypt_file(self, path: str) -> dict:
        """Encrypt a file to a temporary path."""
        return encrypt_file(path, self._dek)

    def create_session_token(self, access_token: str) -> str:
        """
        Create an opaque session token by wrapping the DEK with the access token.

        The backend API unwraps this token using the same access token from the
        Authorization header to recover the DEK.

        Args:
            access_token: Raw Supabase JWT access token string.

        Returns:
            Base64-encoded session token string.
        """
        wrap_key = _derive_wrap_key(access_token)
        aesgcm = AESGCM(wrap_key)
        iv = os.urandom(12)
        ciphertext_with_tag = aesgcm.encrypt(iv, self._dek, None)
        encrypted_dek = ciphertext_with_tag[:32]
        tag = ciphertext_with_tag[32:]
        token_bytes = iv + encrypted_dek + tag
        return base64.b64encode(token_bytes).decode("ascii")


# Session token wrap key derivation constants (shared with backend)
_WRAP_HKDF_SALT = b"olane-session-wrap-v1"
_WRAP_HKDF_INFO = b"olane-wrap"


def _derive_wrap_key(access_token: str) -> bytes:
    """Derive a 256-bit wrap key from a Supabase access token using HKDF-SHA256."""
    hkdf = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=_WRAP_HKDF_SALT,
        info=_WRAP_HKDF_INFO,
    )
    return hkdf.derive(access_token.encode("utf-8"))


# =========================================================================
# CLI Interface
# =========================================================================

def _get_copass_encryption_key() -> str:
    """Get COPASS_ENCRYPTION_KEY from environment or .olane/config.json, exit if not found."""
    key = os.environ.get("COPASS_ENCRYPTION_KEY", "")
    if not key:
        config_path = os.path.join(".olane", "config.json")
        if os.path.isfile(config_path):
            try:
                with open(config_path, "r", encoding="utf-8") as f:
                    config = json.load(f)
                key = config.get("copass_encryption_key", "")
            except (json.JSONDecodeError, OSError):
                pass
    if not key:
        print("ERROR: COPASS_ENCRYPTION_KEY not found in environment or .olane/config.json", file=sys.stderr)
        print("  Run: python3 .olane/scripts/olane_crypto.py generate-key", file=sys.stderr)
        sys.exit(1)
    return key


def _cli_encrypt_stdin():
    """Encrypt a JSON payload from stdin, extracting the 'text' field."""
    copass_encryption_key = _get_copass_encryption_key()
    dek = derive_dek(copass_encryption_key)

    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        print("ERROR: stdin must be valid JSON", file=sys.stderr)
        sys.exit(1)

    text = payload.get("text", "")
    if not text:
        print("ERROR: JSON payload must contain a 'text' field", file=sys.stderr)
        sys.exit(1)

    result = encrypt(text, dek)

    # Build output: original payload with text replaced by encrypted fields
    output = {k: v for k, v in payload.items() if k != "text"}
    output.update(result)
    print(json.dumps(output))


def _cli_encrypt_file(path: str):
    """Encrypt a file and output metadata as JSON."""
    copass_encryption_key = _get_copass_encryption_key()
    dek = derive_dek(copass_encryption_key)
    result = encrypt_file(path, dek)
    print(json.dumps(result))


def _cli_get_dek():
    """Output DEK as base64 string."""
    copass_encryption_key = _get_copass_encryption_key()
    dek = derive_dek(copass_encryption_key)
    print(base64.b64encode(dek).decode("ascii"))


def _cli_generate_key():
    """Generate a UUID4 master key and write it to .olane/config.json. Refuses to overwrite an existing key."""
    import uuid

    config_path = os.path.join(".olane", "config.json")
    config = {}
    if os.path.isfile(config_path):
        try:
            with open(config_path, "r", encoding="utf-8") as f:
                config = json.load(f)
        except (json.JSONDecodeError, OSError) as e:
            print(f"Warning: Could not read {config_path}: {e}", file=sys.stderr)

    if config.get("copass_encryption_key"):
        
        print("Master key already exists in .olane/config.json — skipping generation.", file=sys.stderr)
        print(config["copass_encryption_key"])
        return

    copass_encryption_key = str(uuid.uuid4())
    config["copass_encryption_key"] = copass_encryption_key

    os.makedirs(os.path.dirname(config_path), exist_ok=True)
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)

    print(copass_encryption_key)


def _cli_generate_session_token():
    """Generate a session token by wrapping the DEK with the auth token."""
    copass_encryption_key = _get_copass_encryption_key()

    # Read auth_token from .olane/config.json
    config_path = os.path.join(".olane", "config.json")
    auth_token = None
    if os.path.isfile(config_path):
        try:
            with open(config_path, "r", encoding="utf-8") as f:
                cfg = json.load(f)
            auth_token = cfg.get("auth_token", "")
        except (json.JSONDecodeError, OSError):
            pass

    if not auth_token:
        print("ERROR: auth_token not found in .olane/config.json", file=sys.stderr)
        sys.exit(1)

    crypto = OlaneCrypto(copass_encryption_key)
    token = crypto.create_session_token(auth_token)
    print(token)


def main():
    if len(sys.argv) < 2:
        print("Usage: olane_crypto.py <command> [options]", file=sys.stderr)
        print("Commands: encrypt --stdin, encrypt-file --path <path>, get-dek, generate-key, generate-session-token", file=sys.stderr)
        sys.exit(1)

    command = sys.argv[1]

    if command == "encrypt":
        if "--stdin" not in sys.argv:
            print("Usage: olane_crypto.py encrypt --stdin", file=sys.stderr)
            sys.exit(1)
        _cli_encrypt_stdin()

    elif command == "encrypt-file":
        try:
            path_idx = sys.argv.index("--path") + 1
            path = sys.argv[path_idx]
        except (ValueError, IndexError):
            print("Usage: olane_crypto.py encrypt-file --path <file_path>", file=sys.stderr)
            sys.exit(1)
        _cli_encrypt_file(path)

    elif command == "get-dek":
        _cli_get_dek()

    elif command == "generate-key":
        _cli_generate_key()

    elif command == "generate-session-token":
        _cli_generate_session_token()

    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        print("Commands: encrypt --stdin, encrypt-file --path <path>, get-dek, generate-key, generate-session-token", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
