#!/usr/bin/env python3
# Rewrites a zeronsh/zeron checkout into Naive in place: contents and paths.
# Run at a repo root: python3 scripts/naive-rename.py
import os
import re
import subprocess
import sys

KEEP = re.compile(
    r"zeronsh(?:/[\w.-]+)?"
    r"|zeron-sh\b(?:/[\w.-]+)?"
    r"|github\.com/apps/zeron(?:-test)?\b"
    r"|GITHUB_APP_SLUG: \"zeron-test\""
    r"|e\.g\. zeron, for the install link"
    r"|zeron-edge-staging\.sylasincorporated"
    r"|zeroning|Zeroning|ZERONING"
)
SWAP = re.compile(r"zeron|Zeron|ZERON")
TO = {"zeron": "naive", "Zeron": "Naive", "ZERON": "NAIVE"}
SKIP = {"scripts/naive-rename.py", "scripts/naive-sync.sh"}


def rename_text(text):
    out, last = [], 0
    for m in KEEP.finditer(text):
        out.append(SWAP.sub(lambda s: TO[s.group()], text[last:m.start()]))
        out.append(m.group())
        last = m.end()
    out.append(SWAP.sub(lambda s: TO[s.group()], text[last:]))
    return "".join(out)


def main():
    root = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
    os.chdir(root)
    files = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
    changed = moved = 0
    for path in filter(None, files):
        if path in SKIP or os.path.islink(path) or not os.path.isfile(path):
            continue
        with open(path, "rb") as f:
            raw = f.read()
        if b"\0" not in raw:
            try:
                text = raw.decode("utf-8")
            except UnicodeDecodeError:
                text = None
            if text is not None:
                new = rename_text(text)
                if new != text:
                    with open(path, "wb") as f:
                        f.write(new.encode("utf-8"))
                    changed += 1
        target = rename_text(path)
        if target != path:
            os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
            subprocess.check_call(["git", "mv", "-f", path, target])
            moved += 1
    subprocess.check_call(["git", "add", "-u"])
    print(f"naive-rename: {changed} files rewritten, {moved} moved", file=sys.stderr)


if __name__ == "__main__":
    main()
