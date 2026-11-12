#!/usr/bin/env python3
"""Guard probe: checks that the guard is LIVE and DISCRIMINATING.

Not "the file is in place", but a live command: the guard is fed a synthetic PreToolUse payload and
its behavior is checked.

* POSITIVE — a destructive act on the working tree must be blocked (exit 2).
* NEGATIVE — an ordinary command must pass (exit 0).

The probe runs on its OWN sandbox in mktemp, not on the owner's repository: the rules are enabled
by its
config, and where the destructive rule is legitimately off, the probe would report a broken guard.

Run from the gate:  python3 "$HOME/retainer/hooks/selfcheck_guard.py"
Exit code: 0 — the guard is fine; 1 — does not block, blocks falsely or is broken.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
GUARD = HERE / "guard_discipline.py"
_PROBE_TIMEOUT = 30  # seconds per probe guard run
_CFG_REL = (".retainer", "config.toml")  # config layout: one literal per file
_SANDBOX_CFG = """unlock_file = ".retainer/unlock"
guard_destructive = true
guard_egress = true
"""
_BLOCK = 2  # call-cancel code, the same contract as the guard
_DESTRUCTIVE = "rm -rf app"
_HARMLESS = "ls -la app"


def _run_guard(command: str, root: Path) -> int:
    """Feed the guard a command and return the exit code."""
    payload = {
        "tool_name": "Bash",
        "tool_input": {"command": command},
        "cwd": str(root),
        "hook_event_name": "PreToolUse",
    }
    probe_env = {
        **os.environ,
        "RETAINER_GUARD_PROBE": "1",
    }  # decision without the guard's side effects
    try:
        proc = subprocess.run(
            [sys.executable, str(GUARD)],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            timeout=_PROBE_TIMEOUT,
            check=False,
            env=probe_env,
        )
    except subprocess.TimeoutExpired:
        print("✗ guard hung (timeout) on the probe", file=sys.stderr)
        return -1
    return proc.returncode


def _probe(root: Path) -> int:
    """Positive (destructive act is blocked) plus negative (an ordinary command passes)."""
    hit = _run_guard(_DESTRUCTIVE, root)
    miss = _run_guard(_HARMLESS, root)
    if hit == _BLOCK and miss == 0:
        print(f"✓ guard is live: blocks «{_DESTRUCTIVE}» (2), passes «{_HARMLESS}» (0)")
        return 0
    if hit != _BLOCK:
        print(
            f"✗ guard does NOT block the destructive act «{_DESTRUCTIVE}»"
            f" (code {hit}, expected {_BLOCK})",
            file=sys.stderr,
        )
    if miss != 0:
        print(f"✗ guard falsely blocks «{_HARMLESS}» (code {miss}, expected 0)", file=sys.stderr)
    return 1


def main() -> int:
    """Run the probe on its own sandbox: 0 — guard is live, 1 — broken."""
    if not GUARD.is_file():
        print(f"✗ guard not found: {GUARD}", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory() as sandbox_dir:
        root = Path(sandbox_dir)
        root.joinpath(_CFG_REL[0]).mkdir()
        root.joinpath(*_CFG_REL).write_text(_SANDBOX_CFG, encoding="utf-8")
        (root / "app").mkdir()
        return _probe(root)


if __name__ == "__main__":
    sys.exit(main())
