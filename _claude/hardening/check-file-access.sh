#!/usr/bin/env bash
# Thin wrapper around check-file-access.py for macOS / Linux.
#
# Locates a Python interpreter on PATH (python3, then python) and execs
# the policy script with stdin/stdout forwarded.
#
# Fail-closed behavior: if no Python is found, emit a PreToolUse deny
# JSON object and exit 0. Returning a deny here is intentional — a
# missing interpreter on a host that wired up this hook means the
# policy cannot be evaluated, so we must not silently allow the call.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
for PY in "${PYTHON:-}" python3 python; do
  [ -n "$PY" ] || continue
  if command -v "$PY" >/dev/null 2>&1; then
    exec "$PY" "$DIR/check-file-access.py" "$@"
  fi
done

# No interpreter available — fail closed.
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"hardening hook denied: no Python interpreter found on PATH (tried python3, python). Install Python 3.9+ or remove the hook from .claude/settings.json."}}'
exit 0
