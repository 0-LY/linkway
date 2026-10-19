#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
export IDENTITY_RELEASE=1
source "$root/scripts/identity.sh"
check=0
[[ "${1:-}" == --check ]] && check=1
python3 -I - "$root" "$check" <<'PY'
import os, sys, tempfile
root, check = sys.argv[1], sys.argv[2] == "1"
keys = ["APP_NAME", "PUBLISHER", "GITHUB_REPO", "CONFIG_DIR_NAME", "REPO_URL", "SITE_URL", "FEED_URL", "DOWNLOAD_URL"]
values = {k: os.environ[k] for k in keys}
values["ZIP_NAME"] = os.environ["ZIP_BASE"] + ".zip"
targets = {"README.md.in": "README.md", "LICENSE.in": "LICENSE", "SECURITY.md.in": "SECURITY.md"}
stale = []
for src, dst in targets.items():
    text = open(os.path.join(root, "templates", src), encoding="utf-8").read()
    for k, v in values.items():
        text = text.replace("{{" + k + "}}", v)
    if "{{" in text:
        sys.exit(f"{src}: unknown placeholder left: " + text[text.index("{{"):text.index("{{") + 40])
    path = os.path.join(root, dst)
    current = open(path, encoding="utf-8").read() if os.path.exists(path) else None
    if current == text:
        continue
    if check:
        stale.append(dst)
        continue
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)
    print("updated", dst)
if stale:
    print("out of date:", ", ".join(stale))
    sys.exit(1)
PY
