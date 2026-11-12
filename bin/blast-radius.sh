#!/usr/bin/env bash
# retainer: blast-radius measurement for a retrofit — how many violations the box's STRICT gate yields on
# EXISTING code. Decides per ADR-0002: few → fix at once; a flood → phased ratchet (skill retrofit).
# READ-ONLY (touches no code). Run IN a project: bin/blast-radius.sh [code-dirs...]
#
# Tools (the box's strict set) are looked up: $RETAINER_LINT_VENV/bin → ./.venv/bin → PATH.
# Needed: ruff, flake8 + wemake-python-styleguide, mypy. Missing — install the box's requirements-dev.txt.
set -euo pipefail

# ── find a venv with the strict tools ────────────────────────────────────
BIN=""
for cand in "${RETAINER_LINT_VENV:-}/bin" "./.venv/bin" "$PWD/.venv/bin"; do
  [ -x "$cand/ruff" ] && [ -x "$cand/flake8" ] && [ -x "$cand/mypy" ] && { BIN="$cand"; break; }
done
if [ -z "$BIN" ]; then
  command -v ruff >/dev/null && command -v flake8 >/dev/null && command -v mypy >/dev/null \
    && BIN="$(dirname "$(command -v ruff)")" \
    || { echo "no strict tools (ruff/flake8+WPS/mypy). Install the box's requirements-dev.txt or set RETAINER_LINT_VENV=path" >&2; exit 1; }
fi

# ── sources: arguments, else top-level dirs with .py per git, else '.' ─────
SRC="$*"
if [ -z "$SRC" ]; then
  SRC="$(git ls-files '*.py' 2>/dev/null | grep -v '/migrations/' | sed 's|/[^/]*$||' | sort -u | grep -v '^$' | tr '\n' ' ')"
  [ -z "$SRC" ] && SRC="."
fi
echo "tools: $BIN"
echo "sources:   $SRC"
echo

RUFF_SEL="E,F,W,I,N,UP,B,C4,SIM,D"       # the box's wide select
TMPCFG="$(mktemp)"
printf '[flake8]\nmax-line-length = 99\nextend-select = WPS\nextend-exclude = .venv,.git,__pycache__,migrations\n' > "$TMPCFG"
trap 'rm -f "$TMPCFG"' EXIT

# ── measurements (isolated from project configs — measures the BOX, not the current gate) ──
# --output-format=concise is REQUIRED: ruff ≥0.15 prints diagnostics in the full style by default
# (rustc-like `-->`), where grep 'file:line:col:' matches NO line → a false ruff=0.
ruff=$("$BIN/ruff" check --isolated --select="$RUFF_SEL" --line-length=99 --output-format=concise $SRC 2>/dev/null | grep -cE '^[^ ].*:[0-9]+:[0-9]+:' || true)
fmt=$("$BIN/ruff" format --isolated --check --line-length=99 $SRC 2>/dev/null | grep -c 'Would reformat' || true)
wps=$("$BIN/flake8" --config="$TMPCFG" $SRC 2>/dev/null | grep -cE ':[0-9]+:[0-9]+: ' || true)
myp=$("$BIN/mypy" --strict --ignore-missing-imports --no-error-summary --config-file=/dev/null $SRC 2>/dev/null | grep -c 'error:' || true)
tot=$((ruff + fmt + wps + myp))

echo "── TOTAL ──────────────────────────────"
printf "  ruff (wide select)    : %s\n  format               : %s\n  WPS (wemake)         : %s\n  mypy strict          : %s\n  TOTAL                : %s\n" \
  "$ruff" "$fmt" "$wps" "$myp" "$tot"
echo

# ── WPS by category (first digit of the code) → phase order ──────────────────────
echo "── WPS by category (phased ratchet: practices+complexity → consistency → names/style) ──"
"$BIN/flake8" --config="$TMPCFG" --statistics -q $SRC 2>/dev/null | grep -E '^[0-9]+[[:space:]]+WPS' \
  | awk '{n=$1; c=$2; d=substr(c,4,1); cnt[d]+=n; top[d]=top[d] sprintf("      %-9s %s\n", c, n" · "substr($0, index($0,$3)))}
    END{
      split("1 names;2 complexity;3 consistency;4 practices;5 OOP;6 framework", nm, ";");
      for(i in nm){split(nm[i],p," "); label[p[1]]=p[2]}
      order="4 2 3 1 5 6";  # practices+complexity first, names/style later
      split(order, ord, " ");
      for(j=1;j<=length(ord);j++){d=ord[j]; if(cnt[d]>0){printf "  WPS%sxx %-16s %s\n", d, label[d], cnt[d]}}
    }' || true
echo
echo "  verdict: $([ "$tot" -le 40 ] && echo "few ($tot) → fix at once" || echo "FLOOD ($tot) → phased ratchet (skill retrofit): enable WPS by category, keep the gate green each phase, log deferred items in the RATCHET journal")"
