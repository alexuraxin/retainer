#!/usr/bin/env python3
"""Local (127.0.0.1) server of the retainer settings pult: serves pages and WRITES config on POST.

No egress — listens on loopback only (nothing goes outward). Lives
while the pult is open; Ctrl-C in the terminal stops it. Prints the port as the first stdout line —
the launcher
(retainer-settings.sh) reads it and opens the browser at http://127.0.0.1:<port>/.

Endpoints:
  GET  /config          → current config.toml (round-trip of page load).
  GET  /projects        → JSON of managed projects (allowlist ~/.config/retainer/managed-repos).
  GET  /rigor?project=  → that project's [rigor] block, "" when it declared none (same allowlist).
  GET  /autonomy-status → {configured, paused} of the autonomy (conveyor).
  POST /save            {"config": …}       → overwrite ~/.config/retainer/config.toml.
  POST /save-rigor      {"project","rigor"} → [rigor] into a project ONLY from the allowlist.
  POST /pause           → toggle kill-switch ~/.retainer/conveyor.off (autonomy pause).
  GET  /key-status      → {"deepseek": "set"|"environment"|"missing"} — never the key itself.
  POST /save-key        {"key": …} → ~/.config/retainer/deepseek_key, mode 600.
  POST /delete-key      → remove that file.

The key routes and the origin check live in the neighbour `settings_key.py`.
"""

from __future__ import annotations

import json
import os
import re
import sys
from collections.abc import Callable, Mapping
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import MappingProxyType
from urllib.parse import unquote

import settings_key

HOST = "127.0.0.1"
UTF8 = "utf-8"
DEFAULT_PORT = 8765  # stable port: the URL does not jump between runs (else the old URL → refused)
EPHEMERAL_PORT = 0  # 0 = the OS hands out a free port (fallback when the stable one is busy)
MAX_PORT = 65535
# [rigor] section: from its header to the next table HEADER `[...]` alone on its line, or EOF.
# The header may carry a trailing `#` comment; with one its name must hold a letter and no comma:
# `[3]  # last` needs the letter, `["abc", "d"]  # last` needs the comma, and both are array
# element lines whose adoption as the block's end orphans the array tail. Line endings are
# normalized by the reader, so the class needs no `\r`.
# The lookahead is a full header, not any `[`: otherwise a multiline TOML array would be orphaned.
# It is also anchored at column ZERO on purpose, and accepting an INDENTED one costs more than it
# buys: an indented `[ ... ]` is the ordinary shape of a multiline array's last element, so the
# block would end inside the array, the read would hide the keys below it, and the write would
# leave the array's tail behind a header -- measured, a file that parses before the write and not
# after. An indented header therefore still over-reaches into the next table; that form belongs
# with the other TOML header notations this reader does not match.
RIGOR_RE = re.compile(
    r"(?ms)^\[rigor\].*?(?=^\[[^\n]*\][ \t]*$|^\[[^\n,]*[A-Za-z][^\n,]*\][ \t]*#|\Z)",
)
# A key line of the [rigor] block: the name, the value without quotes, the trailing comment. The
# pattern consumes the WHOLE line, so substituting group 1 into it yields the bare key — that is
# how the merge asks "is this key mentioned" without a second pattern of its own. A `#` inside a
# quoted value is not of this subject: the block holds booleans and a closed set of segment words.
KEY_RE = re.compile(
    r'(?m)^[ \t]*([A-Za-z_]\w*)[ \t]*=[ \t]*"?([^"#\n\[{]*)"?[ \t]*(#[^\n]*)?$',
)
COMMENT_RE = re.compile(r"^[ \t]*#")
_pages_arg = sys.argv[1] if len(sys.argv) > 1 else "."
PAGES_DIR = Path(_pages_arg)
_config_env = os.environ.get("RETAINER_SETTINGS_CONFIG")
_default_config = Path.home() / ".config" / "retainer" / "config.toml"
CONFIG_PATH = Path(_config_env) if _config_env else _default_config
_repos_env = os.environ.get("RETAINER_MANAGED_REPOS")
_default_repos = Path.home() / ".config" / "retainer" / "managed-repos"
MANAGED_REPOS = Path(_repos_env) if _repos_env else _default_repos
_kill_env = os.environ.get("RETAINER_KILL_SWITCH")
KILL_SWITCH = Path(_kill_env) if _kill_env else Path.home() / ".retainer" / "conveyor.off"
_conf_env = os.environ.get("RETAINER_CONVEYOR_CONF")
CONVEYOR_CONF = (
    Path(_conf_env) if _conf_env else Path.home() / ".config" / "retainer" / "conveyor.conf"
)


def wanted_port() -> int:
    """Port from env RETAINER_SETTINGS_PORT; junk/out of range → DEFAULT_PORT."""
    raw = os.environ.get("RETAINER_SETTINGS_PORT", "")
    # isdecimal, not isdigit: superscripts ²³ pass isdigit, but int() does not parse them → crash
    if not raw.isdecimal():
        return DEFAULT_PORT
    port = int(raw)
    return port if EPHEMERAL_PORT <= port <= MAX_PORT else DEFAULT_PORT


def managed_repos() -> list[Path]:
    """Allowlist projects from the managed-repos registry (# — comment, blanks skipped).

    Absolute paths.
    """
    if not MANAGED_REPOS.is_file():
        return []
    picked: list[Path] = []
    for line in MANAGED_REPOS.read_text(encoding=UTF8).splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            picked.append(Path(stripped).expanduser())
    return picked


def replace_rigor(config_text: str, rigor_block: str) -> str:
    """Merge rigor_block into [rigor]; no such table — append to the end.

    A comment or a whole key line of the old block that rigor_block does not mention survives, so
    a key this writer does not know is not erased by it. Nothing else survives, and that is what
    keeps a second [rigor] out of the file: the old header is neither a comment nor a key line, so
    the same filter drops it. A value whose line does not end on it is dropped for the same reason,
    rather than carried over without its continuation, and a name already carried is not carried
    twice -- a repeated key would cost the whole file, not one table.
    """
    block = rigor_block.strip("\n")
    found = RIGOR_RE.search(config_text)
    if found:
        # Substituting group 1 into the whole line turns the incoming block into its bare list of
        # keys, one per line; a non-key line survives the substitution unchanged and so matches
        # nothing. Membership is by whole line, never by substring: `prose` is not `prose_lang`.
        # The list GROWS as lines are kept, so one name is carried at most once. Without that, a
        # block that over-reaches an indented neighbouring table emits both tables' keys, and a
        # repeated name makes the whole file unloadable for every TOML reader -- worse than
        # losing the table, which is what a plain whole-block write does.
        mentioned = KEY_RE.sub(r"\1", block).splitlines()
        # Keyed by the NAME, so one name is carried at most once: a block that over-reaches an
        # indented neighbouring table would otherwise emit both tables' keys, and a repeated name
        # makes the whole file unloadable for every TOML reader -- worse than losing the table,
        # which is what a plain whole-block write does. A name repeated keeps its last line.
        kept = {
            KEY_RE.sub(r"\1", line, count=1): line
            for line in found.group(0).splitlines()
            if (COMMENT_RE.match(line) or KEY_RE.match(line))
            and KEY_RE.sub(r"\1", line, count=1) not in mentioned
        }
        return RIGOR_RE.sub(
            lambda _match: "\n".join([block, *kept.values(), "", ""]),
            config_text,
            count=1,
        )
    if config_text.endswith("\n\n") or not config_text:
        return f"{config_text}{block}\n"
    return f"{config_text}\n{block}\n"


def rigor_file(project: str) -> Path | None:
    """The project's config path; None when the project is outside the allowlist.

    One call for the read and for the write, so the two cannot drift on the form of a path.
    """
    if project not in {str(repo) for repo in managed_repos()}:
        return None
    return Path(project) / ".retainer" / "config.toml"


def pause_switch(want: bool | None = None) -> dict[str, bool]:
    """Autonomy status + pause (kill-switch). want=None → status; True → pause; False → clear."""
    if want is True:
        KILL_SWITCH.parent.mkdir(parents=True, exist_ok=True)
        KILL_SWITCH.write_text("paused by pult\n", encoding=UTF8)
    elif want is False and KILL_SWITCH.is_file():
        KILL_SWITCH.unlink()
    return {"configured": CONVEYOR_CONF.is_file(), "paused": KILL_SWITCH.is_file()}


KEY_ROUTES = MappingProxyType({"/save-key": settings_key.save, "/delete-key": settings_key.delete})
GET_JSON: Mapping[str, Callable[[], object]] = MappingProxyType(
    {"/autonomy-status": pause_switch, "/key-status": settings_key.status},
)


class SettingsHandler(SimpleHTTPRequestHandler):
    """Serves pages (GET), the project list (GET /projects) and writes config/[rigor] (POST)."""

    # The names do_GET/do_POST/log_message are set by BaseHTTPRequestHandler — cannot be renamed.
    def do_GET(self) -> None:
        """GET /config · /projects · /rigor?project= (a project's block) · otherwise page files."""
        if self.path.startswith("/rigor?"):
            # One parameter by contract, so the route is read without a full query parser. The page
            # sends encodeURIComponent, which writes a space as %20 — unquote, never unquote_plus.
            config = rigor_file(unquote(self.path.partition("project=")[2]))
            if config is None:
                self.send_error(HTTPStatus.FORBIDDEN, "project not in managed-repos allowlist")
                return
            raw = config.read_text(encoding=UTF8, errors="replace") if config.is_file() else ""
            found = RIGOR_RE.search(raw)
            self._send_json({"rigor": found.group(0) if found else ""})
            return
        if self.path == "/config":
            text = CONFIG_PATH.read_text(encoding=UTF8) if CONFIG_PATH.is_file() else ""
            self._send_json({"config": text})
            return
        reply = GET_JSON.get(self.path)
        if reply:
            self._send_json(reply())
            return
        if self.path != "/projects":
            super().do_GET()
            return
        self._send_json(
            [
                {"path": str(repo), "name": repo.name}
                for repo in filter(Path.is_dir, managed_repos())
            ],
        )

    def do_POST(self) -> None:
        """POST /save (global config) or /save-rigor.

        /save-rigor writes [rigor] into a project from the allowlist.
        """
        port = getattr(self.server, "server_port", 0)
        if not settings_key.origin_allowed(self.headers.get("Origin", ""), port):
            self.send_error(HTTPStatus.FORBIDDEN, "cross-origin POST rejected")
            return
        key_route = KEY_ROUTES.get(self.path)
        if key_route:
            length = int(self.headers.get("Content-Length", "0"))
            self._send_json(*key_route(self.rfile.read(length)))
            return
        if self.path == "/save":
            self._save_config()
        elif self.path == "/save-rigor":
            self._save_rigor()
        elif self.path == "/pause":
            self._send_json(pause_switch(not KILL_SWITCH.is_file()))  # toggle: pause ↔ running
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def log_message(self, fmt: str, *args: object) -> None:
        """Quiet log: do not clutter the terminal with every request."""

    def guess_type(self, path: str | os.PathLike[str]) -> str:
        """Serve text with charset=utf-8 — otherwise the browser garbles non-ASCII text."""
        ctype = super().guess_type(path)
        if ctype.startswith("text/") and "charset" not in ctype:
            return f"{ctype}; charset={UTF8}"
        return ctype

    def _save_config(self) -> None:
        """Write the received text to CONFIG_PATH (global config)."""
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) or b"{}"
        try:
            text = str(json.loads(raw)["config"])
        except (
            ValueError,
            KeyError,
            TypeError,
        ) as err:  # TypeError: body is not an object (list/number)
            self.send_error(HTTPStatus.BAD_REQUEST, str(err))
            return
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        CONFIG_PATH.write_text(text, encoding=UTF8)
        self._send_json({"ok": True})

    def _save_rigor(self) -> None:
        """POST /save-rigor: [rigor] into a project from the allowlist (else 403)."""
        length = int(self.headers.get("Content-Length", "0"))
        try:
            parsed = json.loads(self.rfile.read(length) or b"{}")
        except ValueError as err:
            self.send_error(HTTPStatus.BAD_REQUEST, str(err))
            return
        if not isinstance(parsed, dict):
            self.send_error(
                HTTPStatus.BAD_REQUEST, "expected JSON object"
            )  # reason-phrase: ASCII only (latin-1)
            return
        config = rigor_file(str(parsed.get("project", "")))
        if config is None:
            self.send_error(HTTPStatus.FORBIDDEN, "project not in managed-repos allowlist")
            return
        if not str(parsed.get("rigor", "")).lstrip().startswith("[rigor]"):
            # Without its own header the block merges as top-level keys: the table is gone, every
            # regulator then reads as the runner default, and a key already present outside can be
            # duplicated into a file no TOML reader can load. Refusing is the cheaper error.
            self.send_error(HTTPStatus.BAD_REQUEST, "rigor must begin with the [rigor] header")
            return
        existing = config.read_text(encoding=UTF8) if config.is_file() else ""
        config.parent.mkdir(parents=True, exist_ok=True)
        merged = replace_rigor(existing, str(parsed.get("rigor", "")))
        config.write_text(merged, encoding=UTF8)
        self._send_json({"ok": True})

    def _send_json(self, payload: object, status: HTTPStatus = HTTPStatus.OK) -> None:
        """Reply with a JSON body, 200 unless told otherwise."""
        body = json.dumps(payload).encode(UTF8)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    """Start the server (stable port, busy → ephemeral), print the port, run until Ctrl-C."""
    os.chdir(PAGES_DIR)  # SimpleHTTPRequestHandler serves from cwd
    # stable port; busy → the OS hands out an ephemeral one (the server comes up anyway)
    try:
        server = ThreadingHTTPServer((HOST, wanted_port()), SettingsHandler)
    except OSError:
        server = ThreadingHTTPServer((HOST, EPHEMERAL_PORT), SettingsHandler)
    with server:
        print(server.server_address[1], flush=True)  # noqa: WPS421 — the port for the launcher, this is the interface
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            server.shutdown()


if __name__ == "__main__":
    main()
