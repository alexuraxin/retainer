#!/usr/bin/env python3
"""MCP stdio server around second_opinion: a native "second opinion" tool for an MCP client.

Claude/any MCP client calls the opinion as a tool, without constructing a Bash command. The logic
is the same
`second_opinion()` from bin/second_opinion.py (one implementation, not a duplicate). Transport:
JSON-RPC 2.0,
newline-delimited messages, stdlib-only.

Registration — `.mcp.json` at the project root (or in the plugin manifest). The DeepSeek key is as
for the CLI
(env DEEPSEEK_API_KEY or ~/.config/retainer/deepseek_key). No key/error → a soft text.
"""

from __future__ import annotations

import json
import os
import sys
from collections.abc import Callable
from typing import Any

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
from second_opinion import DEFAULT_MODEL, second_opinion  # noqa: E402 — path is set up above

# MethodFn alias: the method-handler type (keeps the METHODS annotation under the WPS nesting
# threshold).
MethodFn = Callable[[object, dict[str, Any]], None]

PROTOCOL = "2024-11-05"
SERVER = {
    "name": "second-opinion",
    "version": "1.0.0",
}  # protocol descriptor (WPS407 — per-file-ignore)
ERR_INVALID_PARAMS = -32602  # JSON-RPC: invalid params
ERR_METHOD_NOT_FOUND = -32601  # JSON-RPC: method not found
NOTIFY_METHODS = frozenset(("notifications/initialized", "initialized", "notifications/cancelled"))
TOOL = {
    "name": "second_opinion",
    "description": (
        "Cross-model second opinion (DeepSeek — a DIFFERENT model) at an important step: risks, "
        "what was missed, what will backfire. Complements code-reviewer, does NOT replace it."
        " The answer is a hypothesis."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "question": {"type": "string", "description": "Question for the second opinion"},
            "context": {"type": "string", "description": "Context: diff, plan, decision, seam"},
            "model": {
                "type": "string",
                "description": f"DeepSeek model (default {DEFAULT_MODEL})",
            },
        },
        "required": ["question"],
    },
}


def _send(msg: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(msg, ensure_ascii=False))
    sys.stdout.write("\n")
    sys.stdout.flush()


def _reply(mid: object, body: dict[str, Any]) -> None:
    _send({"jsonrpc": "2.0", "id": mid, "result": body})


def _error(mid: object, code: int, message: str) -> None:
    _send({"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}})


def _opinion_content(question: str, context: str, model: str) -> dict[str, Any]:
    """Body of a tools/call response.

    The second-opinion text OR a soft error (the session is not dropped).
    """
    try:
        text = second_opinion(question, context, model)
    # Broad except is deliberate: a second opinion must not bring down the client session.
    except Exception as err:
        name = type(err).__name__
        return {
            "content": [{"type": "text", "text": f"⚠ Second opinion unavailable ({name})."}],
            "isError": True,
        }
    return {"content": [{"type": "text", "text": text}]}


def _m_initialize(mid: object, req: dict[str, Any]) -> None:
    req_params = req.get("params", {})
    _reply(
        mid,
        {
            "protocolVersion": req_params.get("protocolVersion", PROTOCOL),
            "capabilities": {"tools": {}},
            "serverInfo": SERVER,
        },
    )


def _m_ping(mid: object, req: dict[str, Any]) -> None:
    _reply(mid, {})


def _m_tools_list(mid: object, req: dict[str, Any]) -> None:
    _reply(mid, {"tools": [TOOL]})


def _m_tools_call(mid: object, req: dict[str, Any]) -> None:
    req_params = req.get("params", {})
    if req_params.get("name") != TOOL["name"]:
        _error(mid, ERR_INVALID_PARAMS, f"unknown tool: {req_params.get('name')!r}")
        return
    args = req_params.get("arguments", {}) or {}
    question = str(args.get("question", "")).strip()
    if not question:
        _error(mid, ERR_INVALID_PARAMS, "argument question is required")
        return
    context = str(args.get("context", ""))
    model = str(args.get("model") or DEFAULT_MODEL)
    _reply(mid, _opinion_content(question, context, model))


# Dispatch via a map, not an elif chain (complexity sits on method_fn, not on _dispatch).
METHODS: dict[str, MethodFn] = {
    "initialize": _m_initialize,
    "ping": _m_ping,
    "tools/list": _m_tools_list,
    "tools/call": _m_tools_call,
}


def _dispatch(req: dict[str, Any]) -> None:
    method = req.get("method", "")
    mid = req.get("id")
    method_fn = METHODS.get(method)
    if method_fn is not None:
        method_fn(mid, req)
    elif method in NOTIFY_METHODS:
        return  # notifications get no reply
    elif "id" in req:  # a request (not a notification) with an unknown method
        _error(mid, ERR_METHOD_NOT_FOUND, f"unknown method: {method}")


def main() -> None:
    """Read JSON-RPC requests from stdin line by line, reply on stdout."""
    for line in sys.stdin:
        stripped = line.strip()
        if not stripped:
            continue
        try:
            req = json.loads(stripped)
        except json.JSONDecodeError:
            continue  # nothing to reply with without an id — skip the broken line
        if isinstance(req, dict):
            _dispatch(req)


if __name__ == "__main__":
    main()
