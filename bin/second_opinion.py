#!/usr/bin/env python3
"""second_opinion — a cross-model "second opinion" (DeepSeek).

SUPPLEMENTS code review, does not replace it.

Calls ANOTHER model (DeepSeek) for an independent view on an important/irreversible step. A Claude
subagent of our own would give correlated errors — the value is in a different model. The opinion
is a hypothesis.

Usage (usually from the `second-opinion` skill):
    python3 "${CLAUDE_PLUGIN_ROOT}/bin/second_opinion.py" "question" <<< "context"
    echo "diff" | python3 "${CLAUDE_PLUGIN_ROOT}/bin/second_opinion.py" "refactor risks?" \
        --model deepseek-chat

Key: env DEEPSEEK_API_KEY or ~/.config/retainer/deepseek_key (chmod 600). NOT printed.
No key / error / timeout / empty → a clear message, never fails silently (an extra check).
The wait threshold depends on the model class: a reasoning model needs minutes, a chat model
seconds.
"""

from __future__ import annotations

import json
import os
import socket
import sys
from pathlib import Path
from typing import Any
from urllib import error, request

# The frame for foreign text lives next to the guard: it is protection, not a CLI utility, and it
# must have exactly one home — otherwise the frame's shape would diverge between callers.
_HOOKS = Path(__file__).resolve().parent.parent / "hooks"
sys.path.insert(0, str(_HOOKS))
from untrusted import untrusted  # noqa: E402 — the hooks/ path is set up on the line above

ENDPOINT = "https://api.deepseek.com/v1/chat/completions"
# The header is OUR text and stays OUTSIDE the frame; the source names whose text is inside.
_HEADER = "=== SECOND OPINION (DeepSeek {model}, a DIFFERENT model) — a hypothesis, verify ==="
_SOURCE = "second model · {model}"
DEFAULT_MODEL = "deepseek-reasoner"
# The wait threshold is per model CLASS, not one for all. A reasoning model spends most of its time
# on
# reasoning tokens BEFORE the first answer character: on a trivial question with 20 KB of context
# that
# is already 19 seconds, on a diff review — minutes. A shared threshold fitted to a chat model
# always
# cut the reasoning one: the tool went silent on exactly the questions it exists for.
_TIMEOUT_CHAT = 60
_TIMEOUT_REASONER = 600
_REASONER_MARK = "reasoner"

_SYSTEM = (
    "You are an independent reviewer from a DIFFERENT model. Give a second opinion on the"
    " question: risks, what is missed, whether the decision/seam is right, how it may"
    " backfire. Brief and to the point, no filler."
    " You are not the final authority — your answer will be verified."
)
# Network/parse errors as one group: keep a tuple so the except does not grow (WPS239).
_NET_ERRORS = (error.URLError, TimeoutError, OSError, json.JSONDecodeError)
# `socket.timeout` became an alias of `TimeoutError` only in 3.10, while the working interpreter
# here
# is 3.9: `urlopen` raises exactly `socket.timeout`, and a check on `TimeoutError` alone misses it.
# The tuple is right on both versions — on 3.10+ it is the same object twice.
_TIMEOUTS = (TimeoutError, socket.timeout)
# Answer temperature, via the environment. Empty — the field is not sent AT ALL and the model's
# spread
# stays as is: the job of a second opinion is an independent view, and flattening it to zero would
# take away what the tool exists for. Zero is asked by whoever needs a reproducible verdict rather
# than an opinion — the publish gate — and it sets it in the environment of ITS OWN call, so a
# foreign
# value from the environment is not inherited. The check cannot be weakened this way: temperature
# does
# not turn a finding into "clean" and does not skip a step, it affects only repeatability.
_TEMPERATURE = os.environ.get("RETAINER_SO_TEMPERATURE", "")


def _key() -> str:
    """Key from env or the key file the settings page writes. An empty string = no key."""
    env = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    if env:
        return env
    path = os.environ.get("RETAINER_DEEPSEEK_KEY_PATH") or str(
        Path.home() / ".config" / "retainer" / "deepseek_key"
    )
    try:
        return Path(path).read_text().strip()
    except OSError:
        return ""


def _soft_msg(msg: str) -> str:
    """Soft message (a second opinion is not a blocker).

    Return as a string, do not print, do not fail.
    """
    return (
        f"⚠ Second opinion: {msg} Skip it — an extra check on top of code review, not a blocker."
    )


def _post(payload: bytes, key: str, waited: int) -> dict[str, Any]:
    """POST payload to the DeepSeek endpoint, return the parsed JSON response."""
    # The endpoint is trusted and hardcoded as HTTPS — an arbitrary scheme never arrives here.
    http_req = request.Request(
        ENDPOINT,
        data=payload,
        method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"},
    )
    with request.urlopen(http_req, timeout=waited) as resp:
        answer: dict[str, Any] = json.load(resp)
    return answer


def _failure_text(err: Exception, model: str, waited: int) -> str:
    """Failure text: a timeout and an unreachable channel are different causes.

    "Did not wait long enough" and "could not reach" call for different actions.

    Printing "DeepSeek unavailable" for both sent the investigation to check a network and key that
    were fine: it was the wait threshold that fell silent, not the channel. A timeout wrapped in a
    URLError is still a timeout — otherwise the distinction would work only some of the time.
    """
    reason = getattr(err, "reason", None)
    if isinstance(err, _TIMEOUTS) or isinstance(reason, _TIMEOUTS):
        return (
            f"{model} did not answer within {waited} s"
            " — the question is harder than the wait threshold."
        )
    return f"DeepSeek unavailable ({type(err).__name__})."


def _delivered(answer: dict[str, Any], model: str) -> str:
    """A foreign model's answer, ready to hand to the agent.

    Empty — nothing to say, the caller decides.

    Extraction and formatting live together: there is no seam between them, but they share a
    property —
    everything produced here is FOREIGN. The header stays outside the frame because it is ours;
    soft
    failure messages are ours too and are not wrapped — a frame around our own text would devalue
    it,
    since it means "this is not our text".
    """
    try:
        said = answer["choices"][0]["message"]
    except (KeyError, IndexError, TypeError):
        return ""
    text = str(said.get("content") or "").strip()
    if not text:
        return ""
    framed = untrusted(text, _SOURCE.format(model=model))
    return f"{_HEADER.format(model=model)}\n\n{framed}"


def second_opinion(
    question: str,
    context: str,
    model: str = DEFAULT_MODEL,
    temperature: str = "",
) -> str:
    """Core: the DeepSeek second-opinion text OR a soft message. Does not print, does not fail.

    Reused by the CLI (main) and the MCP server (bin/second_opinion_mcp.py).

    An empty `temperature` — the field is not sent AT ALL, so the model default stays. This
    matters:
    the job of a second opinion is an independent view, and flattening its spread to zero would
    take
    away what the tool exists for. Zero is asked by whoever needs a reproducible verdict rather
    than
    an opinion — the publish gate.
    """
    key = _key()
    if not key:
        return _soft_msg(
            "no DeepSeek key (env DEEPSEEK_API_KEY or ~/.config/retainer/deepseek_key).",
        )
    waited = _TIMEOUT_REASONER if _REASONER_MARK in model.lower() else _TIMEOUT_CHAT
    body: dict[str, Any] = {
        "model": model,
        "messages": [
            {"role": "system", "content": _SYSTEM},
            {"role": "user", "content": f"QUESTION: {question}\n\nCONTEXT:\n{context}"},
        ],
        "stream": False,
    }
    if temperature:
        body["temperature"] = float(temperature)
    try:
        answer = _post(json.dumps(body).encode("utf-8"), key, waited)
    except error.HTTPError as err:
        return _soft_msg(f"DeepSeek returned HTTP {err.code}.")
    except _NET_ERRORS as err:
        return _soft_msg(_failure_text(err, model, waited))
    said = _delivered(answer, model)
    if not said:
        return _soft_msg("DeepSeek returned nothing.")
    return said


def main() -> None:
    """CLI: question from argv, context from stdin, the second opinion on stdout."""
    args = list(sys.argv[1:])
    model = DEFAULT_MODEL
    if "--model" in args:
        idx = args.index("--model")
        if idx + 1 < len(args):
            model = args[idx + 1]
            args = args[:idx] + args[idx + 2 :]
    question = args[0] if args else ""
    if not question:
        print("second_opinion: a question is required as the first argument.", file=sys.stderr)
        sys.exit(2)
    context = "" if sys.stdin.isatty() else sys.stdin.read()
    print(second_opinion(question, context, model, _TEMPERATURE))


if __name__ == "__main__":
    main()
