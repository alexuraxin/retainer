"""The settings server's DeepSeek key and its origin check.

The key goes in through the settings page and is stored in one file with mode 600; nothing here
returns its value. A POST is accepted from no Origin (a local client) or from the server's own
loopback origin, compared by scheme, host and port: a prefix match let
`http://localhost.evil.com` write.
"""

# complexity: keep, step 2 — the settings server is at its size limits; the key lives beside it

from __future__ import annotations

import json
import os
import re
import tempfile
from http import HTTPStatus
from pathlib import Path
from urllib.parse import urlsplit

_UTF8 = "utf-8"
LOOPBACK_HOSTS = frozenset(("127.0.0.1", "localhost"))
_KEY_ENV = "RETAINER_DEEPSEEK_KEY_PATH"
_KEY_DEFAULT = Path.home() / ".config" / "retainer" / "deepseek_key"
KEY_PATH = Path(os.environ.get(_KEY_ENV) or _KEY_DEFAULT)
# A key is one run of visible ASCII: no spaces, no line breaks, at most 512 characters.
_KEY_FORM = re.compile(r"\A[\x21-\x7e]{1,512}\Z")
_REFUSED = "the key is empty, too long or holds spaces"
_UNWRITABLE = "the key file could not be written"
_ROOT_PATHS = frozenset(("", "/"))
# The answer in the order the server replies with it: the JSON body, then the status.
Answer = tuple[dict[str, object], HTTPStatus]


def origin_allowed(origin: str, port: int) -> bool:
    """No Origin, or exactly http://<loopback host>:<this server's port>."""
    if not origin:
        return True
    parts = urlsplit(origin)
    try:
        origin_port = parts.port
    except ValueError:
        return False
    same_host = parts.scheme == "http" and parts.hostname in LOOPBACK_HOSTS
    return same_host and origin_port == port and not parts.username and parts.path in _ROOT_PATHS


def key_status() -> str:
    """Where the key comes from; the environment wins, as in the second-opinion reader."""
    if os.environ.get("DEEPSEEK_API_KEY", "").strip():
        return "environment"
    try:
        stored = KEY_PATH.read_text(encoding=_UTF8).strip()
    except OSError:
        return "missing"
    return "set" if stored else "missing"


def status() -> dict[str, object]:
    """GET /key-status: where the key comes from, never the key."""
    return {"deepseek": key_status()}


def save(body: bytes) -> Answer:
    """POST /save-key: write the key through a temp file and a rename, so it ends at mode 600."""
    try:
        key = json.loads(body or b"{}")["key"]
    except (ValueError, KeyError, TypeError):
        return {"error": 'expected {"key": ...}'}, HTTPStatus.BAD_REQUEST
    key = key.strip() if isinstance(key, str) else ""
    if not _KEY_FORM.match(key):
        return {"error": _REFUSED}, HTTPStatus.BAD_REQUEST
    try:
        _store(key)
    except OSError:
        return {"error": _UNWRITABLE}, HTTPStatus.INTERNAL_SERVER_ERROR
    return {"ok": True, "deepseek": key_status()}, HTTPStatus.OK


def _store(key: str) -> None:
    """Write through a temp file and a rename; a failed write leaves no copy of the key behind."""
    KEY_PATH.parent.mkdir(parents=True, exist_ok=True)
    descriptor, staged = tempfile.mkstemp(dir=KEY_PATH.parent, prefix=".deepseek_key.")
    try:
        os.replace(_filled(descriptor, staged, key), KEY_PATH)
    except OSError:
        # The temp file holds the key: a failed write or rename must not leave that copy behind.
        Path(staged).unlink(missing_ok=True)
        raise


def _filled(descriptor: int, staged: str, key: str) -> str:
    """Write the key into the open temp file and return its path."""
    with os.fdopen(descriptor, "w", encoding=_UTF8) as stream:
        stream.write(f"{key}\n")
    return staged


def delete(_body: bytes) -> Answer:
    """POST /delete-key: remove the key file."""
    KEY_PATH.unlink(missing_ok=True)
    return {"ok": True, "deepseek": key_status()}, HTTPStatus.OK
