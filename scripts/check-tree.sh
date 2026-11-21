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

# The clipboard channel must be built into FreeRDP (text and pictures go through cliprdr).
if ! grep -q -- '-DCHANNEL_CLIPRDR=ON' scripts/build-macos.sh; then
	echo "build-macos.sh must build the cliprdr channel" >&2
	exit 1
fi

if ! grep -q 'CF_DIB' src/session.mm || ! grep -q 'rdp_session_send_language_toggle' src/session.mm; then
	echo "session.mm is missing picture clipboard or the language toggle" >&2
	exit 1
fi

# Language setup runs as the SSH user. It must never ask for root.
if grep -n -w 'sudo' src/LanguageSetup.m; then
	echo "LanguageSetup.m must not use sudo" >&2
	exit 1
fi

# Session window sizing: the picture is drawn in its own layer at imageRect (same rect as the
# mouse mapping), unfilled areas are black, and fixed mode limits the window to the remote size.
if grep -q 'self.layer.contents' src/RDPView.m || ! grep -q '_imageLayer.frame = NSRectToCGRect(\[self imageRect\])' src/RDPView.m; then
	echo "RDPView must draw the picture in the image layer placed at imageRect" >&2
	exit 1
fi
if ! grep -q 'window.backgroundColor = NSColor.blackColor' src/SessionWindow.m ||
	! grep -q 'contentMaxSize = full' src/SessionWindow.m ||
	! grep -q '_viewToBottom' src/SessionWindow.m; then
	echo "SessionWindow must use a black background and size fixed mode to the remote desktop" >&2
	exit 1
fi
if ! grep -q -- '-framework QuartzCore' scripts/build-macos.sh; then
	echo "build-macos.sh must link QuartzCore" >&2
	exit 1
fi

# Network loss must never close the session window: only windowWillClose ends it.
if [ "$(grep -c 'DalnySessionFinished' src/SessionWindow.m)" != "1" ] ||
	! awk '/- \(void\)windowWillClose:/,/^}/' src/SessionWindow.m | grep -q 'DalnySessionFinished'; then
	echo "SessionWindow must post DalnySessionFinished only from windowWillClose" >&2
	exit 1
fi
for text in 'Связь потеряна — переподключаюсь… (попытка %d)' 'Переподключиться сейчас' 'Плохое соединение' \
	'Переключиться на экстремальную экономию' 'kReconnectBackoff\[\] = {1, 2, 4, 8, 15, 30}' 'checkAlive'; do
	if ! grep -q -- "$text" src/SessionWindow.m; then
		echo "SessionWindow is missing: $text" >&2
		exit 1
	fi
done
if ! grep -q 'handlers.link' src/session.mm || ! grep -q 'RefreshRect' src/session.mm; then
	echo "session.mm must probe the link" >&2
	exit 1
fi
# An app-requested stop must never count as a fatal error.
if [ "$(grep -c 'if (session->stop)' src/session.mm)" -lt 2 ]; then
	echo "session.mm must clear fatal when the app stopped the session" >&2
	exit 1
fi
if ! grep -q '"extreme"' src/Server.m || ! grep -q 'self.colorDepth = 8' src/Server.m ||
	! grep -q 'Экстремальная экономия' src/ServerEditor.m || ! grep -q 'profile == 3' src/session.mm; then
	echo "extreme economy profile is incomplete" >&2
	exit 1
fi

echo "tree ok"
