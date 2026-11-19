#!/usr/bin/env python3
"""Strip shared sections from ~/.claude/CLAUDE.md and @-import the vault fleet-rules note.
Usage: claude-fleet-import.py <vault-path>   (idempotent; writes CLAUDE.md.pre-fleet backup)"""
import os, re, sys, shutil
vault = sys.argv[1]
p = os.path.expanduser("~/.claude/CLAUDE.md")
s = open(p).read()
imp = f"@{vault}/06_Metadata/claude-fleet-rules.md"
if imp in s: print("already imported"); sys.exit()
shutil.copy2(p, p + ".pre-fleet")
for h in ("Git — NO AI attribution", "Autonomy", "Secrets — never through the model"):
    s = re.sub(rf"^## {re.escape(h)}[^\n]*\n.*?(?=^## |\Z)", "", s, flags=re.S | re.M)
s = s.rstrip() + f"\n\n## Fleet rules (shared — edit in the vault, not here)\n\n{imp}\n"
open(p, "w").write(s); print("ok")
