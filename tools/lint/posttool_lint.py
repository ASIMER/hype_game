"""Claude Code PostToolUse hook: auto-lint the file just edited by Edit/Write.

Reads the hook JSON from stdin, extracts tool_input.file_path, and runs the
matching linter (.gd -> gdlint + gdformat --check, .py -> ruff). On violations
it prints the linter output and exits 2 — a BLOCKING result that feeds the
output back to Claude so the violation is fixed immediately, with no manual
lint runs (and no tokens spent invoking linters by hand). Anything else (other
extensions, missing tools, parse problems of the hook input itself) exits 0
silently — the hook must never break unrelated edits.

gdformat --check became enforceable once the one-time formatting baseline
landed (docs/AUDIT.md phase 3; commit "style: gdformat baseline").
scripts/resource_index.gd is exempt — it is REGENERATED unformatted per build.
"""

import json
import os
import subprocess
import sys

GDLINT = r"C:\Users\illya\miniconda3\Scripts\gdlint.exe"
GDFORMAT = r"C:\Users\illya\miniconda3\Scripts\gdformat.exe"
RUFF = r"C:\Users\illya\.local\bin\ruff.exe"
PROJECT = r"C:\personal\hype game"
FORMAT_EXEMPT = ("resource_index.gd",)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    tool_input = payload.get("tool_input", payload) or {}
    file_path = str(tool_input.get("file_path") or "")
    if not file_path or not os.path.isfile(file_path):
        return 0
    # Only lint files that belong to this project.
    try:
        if os.path.commonpath([os.path.abspath(file_path), PROJECT]) != PROJECT:
            return 0
    except ValueError:
        return 0

    ext = os.path.splitext(file_path)[1].lower()
    if ext == ".gd":
        cmds = [("gdlint", [GDLINT, file_path])]
        if os.path.basename(file_path) not in FORMAT_EXEMPT:
            cmds.append(("gdformat --check (fix: run gdformat on the file)",
                         [GDFORMAT, "--check", file_path]))
    elif ext == ".py":
        cmds = [("ruff", [RUFF, "check", "--no-fix", file_path])]
    else:
        return 0

    for label, cmd in cmds:
        if not os.path.isfile(cmd[0]):
            continue  # linter not installed — never block
        try:
            res = subprocess.run(
                cmd, capture_output=True, text=True, timeout=60, cwd=PROJECT
            )
        except Exception:
            continue
        if res.returncode == 0:
            continue
        # Violations: surface them to Claude as blocking feedback.
        sys.stderr.write(
            "[lint] %s violations in %s:\n%s%s"
            % (label, os.path.basename(file_path), res.stdout or "", res.stderr or "")
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
