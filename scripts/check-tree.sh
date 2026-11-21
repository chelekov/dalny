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
if info.get("CFBundleIconFile") != "AppIcon":
    raise SystemExit("CFBundleIconFile must be AppIcon")
png = Path("resources/AppIcon.png").read_bytes()
if png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
    raise SystemExit("resources/AppIcon.png must be a PNG")
w, h = int.from_bytes(png[16:20], "big"), int.from_bytes(png[20:24], "big")
if (w, h) != (1024, 1024):
    raise SystemExit(f"resources/AppIcon.png must be 1024x1024, got {w}x{h}")
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

# Server setup runs as the SSH user. It must never ask for root.
if grep -n -w 'sudo' src/LanguageSetup.m resources/server/*; then
	echo "LanguageSetup.m and the server helpers must not use sudo" >&2
	exit 1
fi
# Server helpers: POSIX sh and Python 3, bundled by build-macos.sh and checked by verify-bundle.sh.
for script in resources/server/setup.sh resources/server/dalny-keyboard; do
	sh -n "$script"
	if command -v dash >/dev/null 2>&1; then dash -n "$script"; fi
done
python3 - <<'PY'
import ast
from pathlib import Path
ast.parse(Path("resources/server/dalny-clipboard").read_text(), "dalny-clipboard")
PY
for text in 'xkbcomp -xkb' 'grp:alt_shift_toggle' '--watch'; do
	if ! grep -q -- "$text" resources/server/dalny-keyboard; then
		echo "dalny-keyboard is missing: $text" >&2
		exit 1
	fi
done
for text in 'use-system-keyboard-layout true' 'DALNY_CLIPBOARD=' 'DALNY_IBUS=' 'autostart'; do
	if ! grep -q -- "$text" resources/server/setup.sh; then
		echo "setup.sh is missing: $text" >&2
		exit 1
	fi
done
if ! grep -q 'resources/server/setup.sh' scripts/build-macos.sh || ! grep -q 'Resources/server' scripts/verify-bundle.sh; then
	echo "server helpers must be bundled and verified" >&2
	exit 1
fi
# Mac -> server pictures: the echo of our own picture must not be fetched back.
if ! grep -q 'sentDibMs' src/session.mm || ! grep -q 'isLinkText' src/SessionWindow.m; then
	echo "picture clipboard echo guard or link filter is missing" >&2
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
