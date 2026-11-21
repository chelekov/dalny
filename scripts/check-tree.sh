#!/bin/bash
# Cheap checks that run without a Mac. They do not compile the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash -n scripts/build-macos.sh
bash -n scripts/verify-bundle.sh
bash -n scripts/check-tree.sh

python3 - <<'PY'
import plistlib
from pathlib import Path
info = plistlib.loads(Path("src/Info.plist").read_bytes())
bundle = info.get("CFBundleIdentifier")
if bundle != "app.dalny.client":
    raise SystemExit(f"unexpected bundle id: {bundle}")
if info.get("LSMinimumSystemVersion") != "12.0":
    raise SystemExit("LSMinimumSystemVersion must be 12.0")
PY

if grep -R -n --exclude-dir=.git --exclude=check-tree.sh -e 'chelekov' . | grep -v 'chelekov/dalny'; then
	echo "unexpected owner reference outside the updater repository slug" >&2
	exit 1
fi

if ! grep -q 'chelekov/dalny' src/Updater.m; then
	echo "updater is missing the release repository" >&2
	exit 1
fi

if ! grep -q 'app.dalny.client' src/Updater.m; then
	echo "updater is missing the bundle id check" >&2
	exit 1
fi

echo "tree ok"
