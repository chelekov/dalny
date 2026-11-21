#!/bin/bash
# Builds a self-contained Dalny.app for macOS 12.0.
# Default architecture is x86_64. DALNY_UNIVERSAL=1 also builds arm64 and lipos.
set -euo pipefail
set -o errtrace

# On GitHub Actions, report where the script stopped as an annotation. Annotations can be read
# without a token, job logs cannot.
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
	trap 'echo "::error file=scripts/build-macos.sh,line=$LINENO::failed: $BASH_COMMAND"' ERR
fi

# Runs a compiler command. Errors become GitHub annotations with file and line.
compile() {
	local log
	log="$(mktemp)"
	if "$@" 2>"$log"; then
		cat "$log" >&2
		rm -f "$log"
		return 0
	fi
	cat "$log" >&2
	if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
		grep -E '^[^ :]+:[0-9]+:[0-9]+: (fatal )?error: ' "$log" | head -n 20 |
			while IFS= read -r line; do
				local file="${line%%:*}"
				local rest="${line#*:}"
				local lineno="${rest%%:*}"
				local message="${line#*error: }"
				file="${file#"$ROOT"/}"
				echo "::error file=$file,line=$lineno::$message"
			done || true
		if ! grep -q -E ': (fatal )?error: ' "$log"; then
			# Linker and other errors: the last lines, joined into one annotation.
			echo "::error::$(tail -n 8 "$log" | tr '\n' ' ' | cut -c1-900)"
		fi
	fi
	rm -f "$log"
	return 1
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export MACOSX_DEPLOYMENT_TARGET=12.0
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

select_xcode() {
	local candidate
	for candidate in \
		/Applications/Xcode_16.4.app \
		/Applications/Xcode_16.3.app \
		/Applications/Xcode_16.2.app \
		/Applications/Xcode_16.1.app \
		/Applications/Xcode_16.app \
		/Applications/Xcode.app
	do
		if [[ -d "$candidate" ]]; then
			sudo xcode-select -s "$candidate"
			echo "Using $candidate"
			return
		fi
	done
	echo "No Xcode found" >&2
	exit 1
}
select_xcode
xcodebuild -version

JOBS="$(sysctl -n hw.ncpu)"
need=()
command -v cmake >/dev/null || need+=(cmake)
command -v ninja >/dev/null || need+=(ninja)
command -v nasm >/dev/null || need+=(nasm)
if [[ ${#need[@]} -gt 0 ]]; then
	brew install "${need[@]}"
fi

WORK="$ROOT/build"
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

echo "Downloading OpenSSL and FreeRDP"
curl -fL --retry 3 -o openssl.tar.gz \
	https://github.com/openssl/openssl/releases/download/openssl-3.4.1/openssl-3.4.1.tar.gz
curl -fL --retry 3 -o freerdp.tar.gz \
	https://github.com/FreeRDP/FreeRDP/archive/refs/tags/3.33.1.tar.gz

build_openssl() {
	local arch="$1"
	local target="$2"
	local prefix="$3"
	rm -rf "openssl-$arch"
	mkdir "openssl-$arch"
	tar -C "openssl-$arch" --strip-components=1 -xzf openssl.tar.gz
	pushd "openssl-$arch" >/dev/null
	./Configure "$target" shared no-tests no-apps no-docs \
		--prefix="$prefix" --libdir=lib \
		-mmacosx-version-min=12.0
	make -j"$JOBS"
	make install_sw
	popd >/dev/null
	local lib
	for lib in "$prefix"/lib/libcrypto.3.dylib "$prefix"/lib/libssl.3.dylib; do
		if ! lipo -info "$lib" | grep -q "$arch"; then
			echo "OpenSSL $lib is not $arch" >&2
			lipo -info "$lib" >&2
			exit 1
		fi
	done
}

UNIVERSAL="${DALNY_UNIVERSAL:-0}"
OPENSSL_X86="$WORK/openssl-x86-inst"
OPENSSL_ARM="$WORK/openssl-arm-inst"
OPENSSL="$WORK/openssl-uni"
build_openssl x86_64 darwin64-x86_64-cc "$OPENSSL_X86"
if [[ "$UNIVERSAL" == "1" ]]; then
	build_openssl arm64 darwin64-arm64-cc "$OPENSSL_ARM"
fi

mkdir -p "$OPENSSL/lib" "$OPENSSL/include"
cp -R "$OPENSSL_X86/include/." "$OPENSSL/include/"
for lib in libcrypto.3.dylib libssl.3.dylib; do
	if [[ "$UNIVERSAL" == "1" ]]; then
		lipo -create "$OPENSSL_X86/lib/$lib" "$OPENSSL_ARM/lib/$lib" -output "$OPENSSL/lib/$lib"
	else
		cp "$OPENSSL_X86/lib/$lib" "$OPENSSL/lib/$lib"
	fi
	install_name_tool -id "$OPENSSL/lib/$lib" "$OPENSSL/lib/$lib"
done
# Point libssl at the libcrypto just installed.
crypto_dep="$(otool -L "$OPENSSL/lib/libssl.3.dylib" | awk 'NR>1 { print $1 }' | grep libcrypto || true)"
if [[ -n "$crypto_dep" ]]; then
	install_name_tool -change "$crypto_dep" "$OPENSSL/lib/libcrypto.3.dylib" "$OPENSSL/lib/libssl.3.dylib"
fi
ln -sfn libcrypto.3.dylib "$OPENSSL/lib/libcrypto.dylib"
ln -sfn libssl.3.dylib "$OPENSSL/lib/libssl.dylib"
lipo -info "$OPENSSL/lib/libcrypto.3.dylib"
lipo -info "$OPENSSL/lib/libssl.3.dylib"

echo "Building FreeRDP"
mkdir freerdp-src
tar -C freerdp-src --strip-components=1 -xzf freerdp.tar.gz
FREERDP="$WORK/freerdp-inst"
CMAKE_ARCHS="x86_64"
CLANG_ARCHS=(-arch x86_64)
if [[ "$UNIVERSAL" == "1" ]]; then
	CMAKE_ARCHS="x86_64;arm64"
	CLANG_ARCHS=(-arch x86_64 -arch arm64)
fi
cmake -G Ninja -S freerdp-src -B freerdp-build \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$FREERDP" \
	-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
	-DCMAKE_OSX_ARCHITECTURES="$CMAKE_ARCHS" \
	-DUSE_VERSION_FROM_GIT_TAG=OFF \
	-DCMAKE_PREFIX_PATH="$OPENSSL" \
	-DCMAKE_IGNORE_PREFIX_PATH="/usr/local;/opt/homebrew" \
	-DWITH_JSON_DISABLED=ON \
	-DOPENSSL_ROOT_DIR="$OPENSSL" \
	-DOPENSSL_INCLUDE_DIR="$OPENSSL/include" \
	-DOPENSSL_CRYPTO_LIBRARY="$OPENSSL/lib/libcrypto.dylib" \
	-DOPENSSL_SSL_LIBRARY="$OPENSSL/lib/libssl.dylib" \
	-DBUILD_SHARED_LIBS=ON \
	-DBUILD_TESTING=OFF \
	-DWITH_SERVER=OFF \
	-DWITH_PROXY=OFF \
	-DWITH_SHADOW=OFF \
	-DWITH_SAMPLE=OFF \
	-DWITH_CLIENT=ON \
	-DWITH_CLIENT_COMMON=ON \
	-DWITH_CLIENT_CHANNELS=ON \
	-DWITH_CLIENT_SDL=OFF \
	-DWITH_CLIENT_MAC=OFF \
	-DWITH_X11=OFF \
	-DWITH_WAYLAND=OFF \
	-DWITH_MANPAGES=OFF \
	-DWITH_FFMPEG=OFF \
	-DWITH_SWSCALE=OFF \
	-DWITH_CAIRO=OFF \
	-DWITH_JPEG=OFF \
	-DWITH_OPENH264=OFF \
	-DWITH_GFX_H264=OFF \
	-DWITH_PCSC=OFF \
	-DWITH_KRB5=OFF \
	-DWITH_FUSE=OFF \
	-DWITH_INTERNAL_RC4=ON \
	-DWITH_INTERNAL_MD4=ON \
	-DWITH_VERBOSE_WINPR_ASSERT=OFF \
	-DWITH_CCACHE=OFF \
	-DCHANNEL_CLIPRDR=ON \
	-DCHANNEL_DISP=ON \
	-DCHANNEL_URBDRC=OFF \
	-DCHANNEL_TSMF=OFF \
	-DCHANNEL_RDPECAM=OFF \
	-DCHANNEL_RDPEAR=OFF \
	-DCHANNEL_AUDIN=OFF \
	-DCHANNEL_RDPSND=OFF \
	-DCHANNEL_PRINTER=OFF \
	-DCHANNEL_DRIVE=OFF \
	-DCHANNEL_SMARTCARD=OFF \
	-DCHANNEL_SERIAL=OFF \
	-DCHANNEL_PARALLEL=OFF \
	-DCHANNEL_SSHAGENT=OFF \
	-DCHANNEL_LOCATION=OFF \
	-DCHANNEL_VIDEO=OFF \
	-DWITH_CLIENT_INTERFACE=OFF
cmake --build freerdp-build --target install -j"$JOBS"

if [[ -d "$FREERDP/include/freerdp3" ]]; then
	INC=(-I"$FREERDP/include/freerdp3" -I"$FREERDP/include/winpr3")
else
	INC=(-I"$FREERDP/include")
fi

echo "Compiling Dalny"
cd "$ROOT"
OBJDIR="$WORK/obj"
mkdir -p "$OBJDIR"
SDK="$SDKROOT"
COMMON=(-mmacosx-version-min=12.0 "${CLANG_ARCHS[@]}" -isysroot "$SDK")
# FreeRDP headers use nullptr. Objective-C and C files are not C++, so map it.
for src in src/*.m; do
	compile clang -fobjc-arc -Dnullptr=NULL "${COMMON[@]}" "${INC[@]}" -c "$src" -o "$OBJDIR/$(basename "${src%.m}").o"
done
compile clang -std=c11 -Dnullptr=NULL "${COMMON[@]}" "${INC[@]}" -c src/AppleKeyboard.c -o "$OBJDIR/AppleKeyboard.o"
compile clang -std=c11 -Dnullptr=NULL "${COMMON[@]}" "${INC[@]}" -c src/Scancode.c -o "$OBJDIR/Scancode.o"
compile clang++ -std=c++17 -fno-objc-arc "${COMMON[@]}" "${INC[@]}" -c src/session.mm -o "$OBJDIR/session.o"
clang "${COMMON[@]}" -o "$WORK/DalnyAskpass" src/askpass.c

LIB_FLAGS=(-lfreerdp-client -lfreerdp -lwinpr)
if [[ ! -f "$FREERDP/lib/libfreerdp.dylib" ]]; then
	LIB_FLAGS=(-lfreerdp-client3 -lfreerdp3 -lwinpr3)
fi
compile clang "${COMMON[@]}" "$OBJDIR"/*.o \
	-L"$FREERDP/lib" -L"$OPENSSL/lib" \
	"${LIB_FLAGS[@]}" -lssl -lcrypto -lz -lc++ \
	-framework Cocoa -framework Security -framework IOKit -framework Network \
	-framework CoreGraphics -framework CoreFoundation -framework Carbon -framework QuartzCore \
	-Wl,-rpath,@executable_path/../Frameworks \
	-o "$WORK/Dalny"

echo "Bundling"
APP="$ROOT/dist/Dalny.app"
rm -rf "$ROOT/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$WORK/Dalny" "$APP/Contents/MacOS/Dalny"
cp "$WORK/DalnyAskpass" "$APP/Contents/MacOS/DalnyAskpass"
cp src/Info.plist "$APP/Contents/Info.plist"
VERSION="1.0.0"
BUILD="1"
if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
	BUILD="$GITHUB_RUN_NUMBER"
	VERSION="1.0.${GITHUB_RUN_NUMBER}"
fi
if [[ "${GITHUB_REF:-}" == refs/tags/v* ]]; then
	VERSION="${GITHUB_REF_NAME#v}"
fi
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]]; then
	echo "Refusing version: $VERSION" >&2
	exit 1
fi
if [[ ! "$BUILD" =~ ^[0-9]+$ ]]; then
	echo "Refusing build: $BUILD" >&2
	exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
printf '%s\n' "$VERSION" > "$ROOT/dist/version-short.txt"
printf '%s\n' "$BUILD" > "$ROOT/dist/version-build.txt"
echo "Version $VERSION ($BUILD)"
chmod +x "$APP/Contents/MacOS/Dalny" "$APP/Contents/MacOS/DalnyAskpass"

FRAME="$APP/Contents/Frameworks"
copy_real() {
	local src="$1"
	local name
	name="$(basename "$src")"
	[[ -e "$FRAME/$name" ]] && return
	cp -L "$src" "$FRAME/$name"
	chmod u+w "$FRAME/$name"
}

while IFS= read -r lib; do
	copy_real "$lib"
done < <(find "$FREERDP/lib" "$OPENSSL/lib" -name '*.dylib' \( -type f -o -type l \))

# Pull in anything the executable or bundled libraries still reference by absolute path.
changed=1
while [[ "$changed" == "1" ]]; do
	changed=0
	while IFS= read -r file; do
		while read -r dep; do
			[[ -z "$dep" ]] && continue
			case "$dep" in
			/usr/lib/*|/System/*|@rpath/*|@executable_path/*|@loader_path/*) continue ;;
			esac
			if [[ -e "$dep" ]]; then
				name="$(basename "$dep")"
				if [[ ! -e "$FRAME/$name" ]]; then
					copy_real "$dep"
					changed=1
				fi
			fi
		done < <(otool -L "$file" | awk 'NR>1 { print $1 }')
	done < <(find "$APP/Contents/MacOS" "$FRAME" -type f)
done

rewrite() {
	local file="$1"
	local base
	base="$(basename "$file")"
	case "$file" in
	*.dylib) install_name_tool -id "@rpath/$base" "$file" 2>/dev/null || true ;;
	esac
	while read -r dep; do
		[[ -z "$dep" ]] && continue
		case "$dep" in
		/usr/lib/*|/System/*) continue ;;
		esac
		local depbase
		depbase="$(basename "$dep")"
		if [[ -e "$FRAME/$depbase" ]]; then
			install_name_tool -change "$dep" "@rpath/$depbase" "$file"
		fi
	done < <(otool -L "$file" | awk 'NR>1 { print $1 }')
}

while IFS= read -r file; do
	rewrite "$file"
	if [[ "$file" == "$APP/Contents/MacOS/"* ]]; then
		install_name_tool -add_rpath "@executable_path/../Frameworks" "$file" 2>/dev/null || true
	else
		install_name_tool -add_rpath "@loader_path" "$file" 2>/dev/null || true
	fi
done < <(find "$APP/Contents/MacOS" "$FRAME" -type f)

echo "Signing"
# Sign libraries, then the helper, then the bundle. Signing the main
# executable on its own and leaving DalnyAskpass out of that seal makes
# `codesign --verify` report the helper as unsigned.
while IFS= read -r file; do
	codesign --force --sign - "$file"
done < <(find "$FRAME" -type f \( -name '*.dylib' -o -name '*.so' \))
codesign --force --sign - "$APP/Contents/MacOS/DalnyAskpass"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP"

bash "$ROOT/scripts/verify-bundle.sh" "$APP"
(
	cd "$ROOT/dist"
	ditto -c -k --keepParent Dalny.app Dalny-macos.zip
)
echo "Built $ROOT/dist/Dalny-macos.zip"
