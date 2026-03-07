#!/usr/bin/env python3
"""
Copass Local Project Indexer

Self-contained script (stdlib only) that walks a project directory locally
and POSTs each file individually to the Copass extract API. The API handles
its own batching internally.

Usage:
    python .olane/scripts/index_project.py --mode full
    python .olane/scripts/index_project.py --mode full --dry-run
    python .olane/scripts/index_project.py --mode full --patterns "**/*.py" --max-files 50
"""

import argparse
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from fnmatch import fnmatch
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

# =========================================================================
# Constants (mirrored from tools.py)
# =========================================================================

MAX_FILE_SIZE_BYTES = 100_000  # 100KB per file
MAX_FILES_DEFAULT = 5000

DEFAULT_EXCLUDED_DIRS = {
    ".git", "__pycache__", "node_modules", ".next", "dist", "build",
    ".venv", "venv", ".tox", ".mypy_cache", ".pytest_cache", "coverage",
    "vendor", "target", ".idea", ".vscode", ".eggs", "egg-info",
    ".terraform", ".serverless", ".aws-sam", ".cache", ".parcel-cache",
}

DEFAULT_EXCLUDED_PATTERNS = {
    "*.lock", "*.min.js", "*.min.css", "*.pyc", "*.pyo", "*.so", "*.dylib",
    "*.dll", "*.exe", "*.o", "*.a", "*.class", "*.jar",
    "*.png", "*.jpg", "*.jpeg", "*.gif", "*.ico", "*.svg", "*.webp",
    "*.pdf", "*.zip", "*.tar", "*.gz", "*.bz2",
    "*.woff", "*.woff2", "*.ttf", "*.eot",
    "*.map", "*.chunk.js", "*.chunk.css",
    "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
    "Cargo.lock", "poetry.lock", "Gemfile.lock", "composer.lock",
}

EXTENSION_TO_LANGUAGE = {
    ".py": "python",
    ".js": "javascript",
    ".jsx": "javascript",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".java": "java",
    ".go": "go",
    ".rs": "rust",
    ".c": "c",
    ".cpp": "cpp",
    ".cc": "cpp",
    ".h": "c",
    ".hpp": "cpp",
    ".rb": "ruby",
    ".php": "php",
    ".swift": "swift",
    ".kt": "kotlin",
    ".kts": "kotlin",
    ".scala": "scala",
    ".sh": "bash",
    ".bash": "bash",
    ".zsh": "zsh",
    ".sql": "sql",
    ".r": "r",
    ".R": "r",
    ".m": "matlab",
    ".cs": "csharp",
    ".lua": "lua",
    ".pl": "perl",
    ".pm": "perl",
    ".dart": "dart",
    ".ex": "elixir",
    ".exs": "elixir",
    ".erl": "erlang",
    ".hs": "haskell",
    ".vue": "vue",
    ".svelte": "svelte",
    ".tf": "terraform",
    ".yaml": "yaml",
    ".yml": "yaml",
    ".toml": "toml",
    ".json": "json",
    ".xml": "xml",
    ".html": "html",
    ".css": "css",
    ".scss": "scss",
    ".sass": "sass",
    ".less": "less",
    ".md": "markdown",
    ".rst": "rst",
    ".proto": "protobuf",
    ".graphql": "graphql",
    ".gql": "graphql",
    ".dockerfile": "dockerfile",
    ".makefile": "makefile",
}

INDEXABLE_EXTENSIONS = set(EXTENSION_TO_LANGUAGE.keys())


# =========================================================================
# Config
# =========================================================================

def load_config(project_path: Path) -> dict:
    """Load config from .olane/config.json with env var overrides."""
    config = {
        "api_url": "https://ai.copass.id",
        "user_id": "",
        "auth_token": "",
    }

    config_file = project_path / ".olane" / "config.json"
    if config_file.is_file():
        try:
            with open(config_file, "r", encoding="utf-8") as f:
                file_config = json.load(f)
            if file_config.get("api_url"):
                config["api_url"] = file_config["api_url"]
            if file_config.get("user_id"):
                config["user_id"] = file_config["user_id"]
            if file_config.get("auth_token"):
                config["auth_token"] = file_config["auth_token"]
        except (json.JSONDecodeError, OSError) as e:
            print(f"  Warning: Could not read {config_file}: {e}", file=sys.stderr)

    # Env vars take precedence
    if os.environ.get("OLANE_API_URL"):
        config["api_url"] = os.environ["OLANE_API_URL"]
    if os.environ.get("OLANE_USER_ID"):
        config["user_id"] = os.environ["OLANE_USER_ID"]
    if os.environ.get("OLANE_AUTH_TOKEN"):
        config["auth_token"] = os.environ["OLANE_AUTH_TOKEN"]

    return config


# =========================================================================
# File discovery helpers
# =========================================================================

def is_binary_file(file_path: Path) -> bool:
    """Read first 8KB and check for null bytes / high non-printable ratio."""
    try:
        with open(file_path, "rb") as f:
            chunk = f.read(8192)
        if not chunk:
            return False
        if b"\x00" in chunk:
            return True
        non_printable = sum(1 for b in chunk if b < 32 and b not in (9, 10, 13))
        return (non_printable / len(chunk)) > 0.3
    except Exception:
        return True


def load_gitignore_matcher(project_path: Path):
    """Parse .gitignore at project root. Returns pathspec.PathSpec or None."""
    gitignore = project_path / ".gitignore"
    if not gitignore.is_file():
        return None
    try:
        import pathspec
        with open(gitignore, "r", encoding="utf-8", errors="replace") as f:
            return pathspec.PathSpec.from_lines("gitwildmatch", f)
    except ImportError:
        print(
            "  Warning: 'pathspec' not installed — .gitignore rules will be skipped. "
            "Install with: pip install pathspec",
            file=sys.stderr,
        )
        return None
    except Exception:
        return None


def discover_files(
    project_path: Path,
    file_patterns: list = None,
    max_files: int = MAX_FILES_DEFAULT,
    verbose: bool = False,
) -> tuple:
    """
    Walk project tree with filters. Returns (included_files, skipped_count).

    Filter order: excluded dirs -> gitignore -> excluded patterns ->
    extension allowlist -> file_patterns -> size limit -> binary detection -> max_files cap.
    """
    gitignore_matcher = load_gitignore_matcher(project_path)
    included: list = []
    skipped = 0

    for dirpath, dirnames, filenames in os.walk(project_path):
        # Prune excluded directories in-place
        dirnames[:] = [d for d in dirnames if d not in DEFAULT_EXCLUDED_DIRS]

        for filename in filenames:
            file_path = Path(dirpath) / filename
            rel_path = file_path.relative_to(project_path)
            rel_str = str(rel_path)

            # gitignore check
            if gitignore_matcher and gitignore_matcher.match_file(rel_str):
                skipped += 1
                if verbose:
                    print(f"  [skip:gitignore] {rel_str}", file=sys.stderr)
                continue

            # excluded patterns check
            if any(fnmatch(filename, pat) for pat in DEFAULT_EXCLUDED_PATTERNS):
                skipped += 1
                continue

            # extension allowlist
            ext = file_path.suffix.lower()
            if ext not in INDEXABLE_EXTENSIONS:
                lower_name = filename.lower()
                if lower_name == "dockerfile":
                    ext = ".dockerfile"
                elif lower_name == "makefile":
                    ext = ".makefile"
                else:
                    skipped += 1
                    continue

            # file_patterns filter
            if file_patterns:
                matched = False
                for pat in file_patterns:
                    if fnmatch(rel_str, pat):
                        matched = True
                        break
                    if pat.startswith("**/") and fnmatch(filename, pat[3:]):
                        matched = True
                        break
                if not matched:
                    skipped += 1
                    continue

            # size limit
            try:
                if file_path.stat().st_size > MAX_FILE_SIZE_BYTES:
                    skipped += 1
                    if verbose:
                        print(f"  [skip:size] {rel_str}", file=sys.stderr)
                    continue
            except OSError:
                skipped += 1
                continue

            # binary detection
            if is_binary_file(file_path):
                skipped += 1
                continue

            included.append(file_path)

            if len(included) >= max_files:
                return included, skipped

    return included, skipped


# =========================================================================
# File payload
# =========================================================================

def build_file_payload(file_path: Path, project_path: Path) -> str:
    """Build a language-tagged fenced code block for a single file."""
    rel_path = file_path.relative_to(project_path)
    ext = file_path.suffix.lower()
    if ext not in EXTENSION_TO_LANGUAGE:
        lower_name = file_path.name.lower()
        if lower_name == "dockerfile":
            ext = ".dockerfile"
        elif lower_name == "makefile":
            ext = ".makefile"
    lang = EXTENSION_TO_LANGUAGE.get(ext, "text")
    content = file_path.read_text(encoding="utf-8", errors="replace")
    return f"File: {rel_path}\nLanguage: {lang}\n\n```{lang}\n{content}\n```"


# =========================================================================
# API posting
# =========================================================================

def _get_crypto():
    """Initialize encryption from COPASS_ENCRYPTION_KEY env var or .olane/config.json. Returns (crypto, dek_b64)."""
    copass_encryption_key = os.environ.get("COPASS_ENCRYPTION_KEY")
    if not copass_encryption_key:
        # Fallback: read from .olane/config.json
        config_path = Path(".olane") / "config.json"
        if config_path.is_file():
            try:
                with open(config_path, "r", encoding="utf-8") as f:
                    config_data = json.load(f)
                copass_encryption_key = config_data.get("copass_encryption_key", "")
            except (json.JSONDecodeError, OSError):
                pass
    if not copass_encryption_key:
        print("ERROR: COPASS_ENCRYPTION_KEY not found in environment or .olane/config.json", file=sys.stderr)
        print("  Run: python3 .olane/scripts/olane_crypto.py generate-key", file=sys.stderr)
        sys.exit(1)

    # Import from the same scripts directory
    script_dir = Path(__file__).parent
    sys.path.insert(0, str(script_dir))
    from olane_crypto import OlaneCrypto

    crypto = OlaneCrypto(copass_encryption_key)
    return crypto, crypto.dek_b64


def post_extract(
    api_url: str,
    user_id: str,
    text_payload: str,
    mode: str,
    project_path_str: str,
    file_rel_path: str,
    auth_token: str = "",
    retries: int = 3,
    crypto=None,
    dek_b64: str = "",
    project_id: str = "",
) -> dict:
    """POST a single file to the extract API with retry on 5xx/connection errors."""
    url = f"{api_url.rstrip('/')}/api/v1/extract/code"

    payload_dict = {
        "text": text_payload,
        "source_type": "code",
        "client_type": "claude_code",
        "user_id": user_id,
        "additional_context": {
            "indexing_mode": mode,
            "project_path": project_path_str,
            "file": file_rel_path,
        },
    }
    if project_id:
        payload_dict["project_id"] = project_id

    # Encrypt if crypto is available
    if crypto:
        encrypted = crypto.encrypt(payload_dict["text"])
        payload_dict.pop("text")
        payload_dict.update(encrypted)

    payload = json.dumps(payload_dict).encode("utf-8")

    headers = {"Content-Type": "application/json"}
    if auth_token:
        headers["Authorization"] = f"Bearer {auth_token}"
    if dek_b64:
        headers["X-Encryption-Key"] = dek_b64

    for attempt in range(1, retries + 1):
        try:
            req = Request(
                url,
                data=payload,
                headers=headers,
                method="POST",
            )
            with urlopen(req, timeout=180) as resp:
                body = resp.read().decode("utf-8")
                return json.loads(body)
        except HTTPError as e:
            if e.code >= 500 and attempt < retries:
                wait = 2 ** attempt
                print(f"  Server error {e.code}, retrying in {wait}s...", file=sys.stderr)
                time.sleep(wait)
                continue
            raise
        except (URLError, OSError) as e:
            if attempt < retries:
                wait = 2 ** attempt
                print(f"  Connection error: {e}, retrying in {wait}s...", file=sys.stderr)
                time.sleep(wait)
                continue
            raise

    return {}


def api_request(url: str, method: str = "GET", payload: dict = None, auth_token: str = "") -> dict:
    """Generic JSON API request (GET, POST, PATCH). Returns parsed JSON or {} on error."""
    headers = {"Content-Type": "application/json"}
    if auth_token:
        headers["Authorization"] = f"Bearer {auth_token}"

    data = json.dumps(payload).encode("utf-8") if payload else None

    try:
        req = Request(url, data=data, headers=headers, method=method)
        with urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8")
            return json.loads(body) if body else {}
    except (HTTPError, URLError, OSError) as e:
        print(f"  Warning: {method} {url} failed: {e}", file=sys.stderr)
        return {}


# =========================================================================
# Main
# =========================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Copass Local Project Indexer — walk project and POST each file to extract API",
    )
    parser.add_argument(
        "--mode", required=True, choices=["full", "incremental"],
        help="Indexing mode: 'full' re-indexes everything, 'incremental' only new/changed",
    )
    parser.add_argument(
        "--max-files", type=int, default=MAX_FILES_DEFAULT,
        help=f"Maximum files to process (default: {MAX_FILES_DEFAULT})",
    )
    parser.add_argument(
        "--patterns", nargs="*",
        help="Glob patterns to include (e.g. '**/*.py' '**/*.ts')",
    )
    parser.add_argument(
        "--project-path", type=str, default=None,
        help="Project root path (default: current working directory)",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Discover files without POSTing to the API",
    )
    parser.add_argument(
        "--verbose", action="store_true",
        help="Print detailed skip reasons during file discovery",
    )
    args = parser.parse_args()

    project_path = Path(args.project_path).resolve() if args.project_path else Path.cwd().resolve()

    if not project_path.is_dir():
        print(f"Error: project path does not exist: {project_path}", file=sys.stderr)
        sys.exit(1)

    print(f"Copass Indexer — {project_path}")
    print(f"  Mode: {args.mode}")

    # Load config
    config = load_config(project_path)
    api_url = config["api_url"]
    user_id = config["user_id"]
    auth_token = config["auth_token"]

    if not args.dry_run and not user_id:
        print(
            "Error: user_id not configured. Set OLANE_USER_ID env var or "
            "add user_id to .olane/config.json",
            file=sys.stderr,
        )
        sys.exit(1)

    # Initialize encryption (required)
    crypto, dek_b64 = _get_crypto()
    if crypto:
        print("  Encryption: enabled")
    else:
        print("  Encryption: disabled (COPASS_ENCRYPTION_KEY not set)")

    print(f"  API: {api_url}")
    if user_id:
        print(f"  User: {user_id[:8]}...")
    if auth_token:
        print(f"  Auth: Bearer {auth_token[:8]}...")

    # Phase 1: Discover
    print("\nDiscovering files...")
    t0 = time.monotonic()
    files, skipped = discover_files(
        project_path,
        file_patterns=args.patterns,
        max_files=args.max_files,
        verbose=args.verbose,
    )
    t_discover = time.monotonic() - t0

    print(f"  Found {len(files)} indexable files ({skipped} skipped) in {t_discover:.1f}s")

    if not files:
        print("No files to index.")
        sys.exit(0)

    if args.dry_run:
        print("\n[DRY RUN] Files to index:")
        for i, f in enumerate(files, 1):
            rel = f.relative_to(project_path)
            try:
                payload = build_file_payload(f, project_path)
                chars = len(payload)
            except Exception:
                chars = 0
            print(f"  {i}/{len(files)}: {rel} ({chars} chars)")
        print(f"\nTotal: {len(files)} files")
        sys.exit(0)

    # Register project with the API
    project_id = None
    register_resp = api_request(
        f"{api_url.rstrip('/')}/api/v1/projects/register",
        method="POST",
        payload={
            "project_path": str(project_path),
            "project_name": project_path.name,
            "indexing_mode": args.mode,
        },
        auth_token=auth_token,
    )
    project_id = register_resp.get("project_id")
    if project_id:
        print(f"  Registered project: {project_id[:8]}...")
        # Persist project_id to config so hooks can use it
        config_file = project_path / ".olane" / "config.json"
        if config_file.is_file():
            try:
                with open(config_file, "r", encoding="utf-8") as f:
                    file_config = json.load(f)
                file_config["project_id"] = project_id
                with open(config_file, "w", encoding="utf-8") as f:
                    json.dump(file_config, f, indent=2)
            except (json.JSONDecodeError, OSError) as e:
                print(f"  Warning: Could not save project_id to config: {e}", file=sys.stderr)

    # Phase 2: Extract (batched 10 at a time)
    BATCH_SIZE = 10
    print(f"\nPosting {len(files)} files to {api_url} (batch size: {BATCH_SIZE})...")
    files_processed = 0
    errors = []
    t_start = time.monotonic()

    def upload_file(file_idx_and_path):
        file_idx, fp = file_idx_and_path
        rel_path = fp.relative_to(project_path)
        text_payload = build_file_payload(fp, project_path)
        post_extract(
            api_url=api_url,
            user_id=user_id,
            text_payload=text_payload,
            mode=args.mode,
            project_path_str=str(project_path),
            file_rel_path=str(rel_path),
            auth_token=auth_token,
            crypto=crypto,
            dek_b64=dek_b64,
            project_id=project_id or "",
        )
        return file_idx, rel_path, len(text_payload)

    for batch_start in range(0, len(files), BATCH_SIZE):
        batch = list(enumerate(files[batch_start:batch_start + BATCH_SIZE], start=batch_start + 1))
        batch_end = min(batch_start + BATCH_SIZE, len(files))
        print(f"  Batch [{batch_start + 1}-{batch_end}/{len(files)}]...")

        with ThreadPoolExecutor(max_workers=BATCH_SIZE) as executor:
            futures = {executor.submit(upload_file, (idx, fp)): (idx, fp) for idx, fp in batch}
            for future in as_completed(futures):
                idx, fp = futures[future]
                rel_path = fp.relative_to(project_path)
                try:
                    _, _, chars = future.result()
                    files_processed += 1
                    print(f"    [{idx}/{len(files)}] {rel_path} ({chars} chars) OK")
                except Exception as e:
                    error_msg = f"{rel_path} failed: {e}"
                    errors.append(error_msg)
                    print(f"    [{idx}/{len(files)}] {rel_path} FAILED: {e}")

    # Phase 3: Summary
    duration = time.monotonic() - t_start
    print(f"\n{'='*50}")
    print(f"Indexing complete in {duration:.1f}s")
    print(f"  Files processed: {files_processed}/{len(files)}")

    # Update project status
    if project_id:
        api_request(
            f"{api_url.rstrip('/')}/api/v1/projects/{project_id}/complete",
            method="PATCH",
            payload={
                "file_count": files_processed,
                "error_count": len(errors),
                "duration_ms": int(duration * 1000),
            },
            auth_token=auth_token,
        )

    if errors:
        print(f"  Errors:          {len(errors)}")
        for err in errors:
            print(f"    - {err}")
        sys.exit(1)

    print("  Errors:          0")


if __name__ == "__main__":
    main()
