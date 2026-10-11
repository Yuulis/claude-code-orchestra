#!/usr/bin/env python3
"""Report and enforce the orchestra role of the current process.

A Codex reached through ``codex_consult.py`` is a delegated *executor*; the
wrapper marks it with ``ORCHESTRA_ROLE=executor``, which every process the
executor starts inherits. The cross-CLI wrappers call ``role_refusal`` before
doing anything, so an executor cannot delegate again through them. Any other
launch from Claude Code is recognisable by ``CLAUDECODE=1``; with neither
signal, the process belongs to a session the user started (the main agent).

Usage:
    python3 orchestra_role.py      # prints {"role": ..., "signal": ...}

Exit codes:
    0  role reported
    1  bad arguments, or ORCHESTRA_ROLE holds an unknown value
"""

import argparse
import json
import os
import sys
from typing import NoReturn

ROLE_ENV = "ORCHESTRA_ROLE"
ROLE_EXECUTOR = "executor"
ROLE_MAIN = "main"
KNOWN_ROLES = ("", ROLE_MAIN, ROLE_EXECUTOR)
CLAUDE_CODE_ENV = "CLAUDECODE"


def role_refusal(environ: dict[str, str]) -> str | None:
    """Return why a delegating wrapper must not run in *environ*, or None.

    An executor that delegated again would turn a leaf into a second
    orchestrator. An unrecognised value is refused too: guessing a role is how
    a typo would silently disable the guard.
    """
    role = environ.get(ROLE_ENV, "")
    if role not in KNOWN_ROLES:
        return (
            f"{ROLE_ENV}={role!r} is not a known role "
            f"(expected {ROLE_MAIN!r} or {ROLE_EXECUTOR!r}, or unset)"
        )
    if role == ROLE_EXECUTOR:
        return (
            f"refusing nested delegation: {ROLE_ENV}={ROLE_EXECUTOR} means this "
            "process is already a delegated executor; do the task yourself and "
            "report back to your caller"
        )
    return None


def detect_role(environ: dict[str, str]) -> tuple[str, str]:
    """Return ``(role, signal)`` for *environ*; role is executor or main."""
    role = environ.get(ROLE_ENV, "")
    if role == ROLE_EXECUTOR:
        return ROLE_EXECUTOR, f"{ROLE_ENV}={ROLE_EXECUTOR}"
    if role == ROLE_MAIN:
        return ROLE_MAIN, f"{ROLE_ENV}={ROLE_MAIN}"
    if environ.get(CLAUDE_CODE_ENV) == "1":
        return ROLE_EXECUTOR, f"{CLAUDE_CODE_ENV}=1"
    return ROLE_MAIN, "no role signal"


class JsonArgumentParser(argparse.ArgumentParser):
    """Report usage errors as one JSON object and exit 1 (shared contract)."""

    def error(self, message: str) -> NoReturn:
        print(json.dumps({"ok": False, "error": message}))
        sys.exit(1)


def main() -> int:
    parser = JsonArgumentParser(
        description="Report the orchestra role of this process (main or executor)."
    )
    parser.add_argument(
        "--project-root",
        default=None,
        help=(
            "Accepted for the shared-script interface; the role depends only on "
            "the environment, never on repository files"
        ),
    )
    parser.parse_args()
    environ = dict(os.environ)
    role_value = environ.get(ROLE_ENV, "")
    if role_value not in KNOWN_ROLES:
        print(json.dumps({"ok": False, "error": role_refusal(environ)}))
        return 1
    role, signal = detect_role(environ)
    print(json.dumps({"ok": True, "role": role, "signal": signal}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
