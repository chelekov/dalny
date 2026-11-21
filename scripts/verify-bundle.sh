#!/bin/bash
# Checks the bundled app: x86_64, or x86_64+arm64 when DALNY_UNIVERSAL=1, minos 12.0.
set -euo pipefail

APP="${1:-dist/Dalny.app}"
if [[ ! -d "$APP" ]]; then
	echo "missing app: $APP" >&2
	exit 1
fi

fail=0
check_file() {
	local file="$1"
	local info
	info=$(lipo -info "$file")
	if [[ "$info" != *"x86_64"* ]]; then
		echo "missing x86_64: $file ($info)" >&2
		fail=1
	fi
	if [[ "${DALNY_UNIVERSAL:-0}" == "1" && "$info" != *"arm64"* ]]; then
		echo "missing arm64: $file ($info)" >&2
		fail=1
	fi
	local minos
	minos=$(vtool -show-build "$file" | awk '/minos/ { print $2 }')
	if [[ -z "$minos" ]]; then
		echo "no LC_BUILD_VERSION minos: $file" >&2
		fail=1
		return
	fi
	while read -r version; do
		local major="${version%%.*}"
		if [[ "$major" != "12" ]]; then
			echo "minos $version (want 12.x) in $file" >&2
			fail=1
		fi
	done <<<"$minos"
	local deps
	deps=$(otool -L "$file" | awk 'NR>1 { print $1 }')
	while read -r dep; do
		[[ -z "$dep" ]] && continue
		case "$dep" in
		/usr/lib/*|/System/*|@rpath/*|@executable_path/*|@loader_path/*) ;;
		*)
			echo "unbundled dependency $dep in $file" >&2
			fail=1
			;;
		esac
	done <<<"$deps"
}

check_file "$APP/Contents/MacOS/Dalny"
check_file "$APP/Contents/MacOS/DalnyAskpass"
while IFS= read -r dylib; do
	check_file "$dylib"
done < <(find "$APP/Contents/Frameworks" -name '*.dylib' -type f)

if ! find "$APP/Contents/Frameworks" -name 'libfreerdp*.dylib' | grep -q .; then
	echo "FreeRDP dylib was not bundled" >&2
	fail=1
fi
# Clipboard is either a plugin dylib or linked into libfreerdp-client
# (FreeRDP builds channels static when the client library is shared).
clipboard_ok=0
if find "$APP/Contents/Frameworks" -name 'libcliprdr-client*.dylib' | grep -q .; then
	clipboard_ok=1
fi
client_lib="$(find "$APP/Contents/Frameworks" -name 'libfreerdp-client3.dylib' -print -quit)"
# grep -q closes the pipe early. With pipefail, nm's SIGPIPE would look like a miss.
if [[ -n "$client_lib" ]]; then
	set +o pipefail
	if nm "$client_lib" | grep -q cliprdr_VirtualChannelEntryEx; then
		clipboard_ok=1
	fi
	set -o pipefail
fi
if [[ "$clipboard_ok" != "1" ]]; then
	echo "clipboard channel was not bundled and not linked into libfreerdp-client" >&2
	fail=1
fi

for helper in setup.sh dalny-keyboard dalny-clipboard; do
	if [[ ! -s "$APP/Contents/Resources/server/$helper" ]]; then
		echo "server helper $helper was not bundled" >&2
		fail=1
	fi
done
if [[ ! -s "$APP/Contents/Resources/AppIcon.icns" ]]; then
	echo "AppIcon.icns was not bundled" >&2
	fail=1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null)" != "AppIcon" ]]; then
	echo "CFBundleIconFile must be AppIcon" >&2
	fail=1
fi

if [[ "$fail" != "0" ]]; then
	exit 1
fi
if [[ "${DALNY_UNIVERSAL:-0}" == "1" ]]; then
	echo "bundle ok: universal x86_64+arm64, minos 12.0"
else
	echo "bundle ok: x86_64, minos 12.0"
fi
