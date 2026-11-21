# Handoff — Дальний (Dalny)

Кратко: клиент удалённого стола для macOS 12 и новее (Intel и Apple Silicon). Протокол — RDP к xrdp, не VNC. Серверная сторона, на которую рассчитаны профили картинки, — Ubuntu с XFCE и штатным xrdp 0.9.24. Сборка — GitHub Actions. Исследование: `docs/rdp-best-practices.md`.

## Goal

A self-contained macOS remote-desktop app. The `.app` embeds FreeRDP and OpenSSL. Nothing else is installed on the Mac.

The app name is **Дальний** (bundle id `app.dalny.client`, executable `Dalny`). In-app updates read GitHub Releases for the public repo `chelekov/dalny` and do not require a token.

## Requirements

### Machine and protocol

- Target: macOS 12 or later, Intel and Apple Silicon. Deployment target **macOS 12.0**. The default CI binary is **x86_64**. A workflow input can also build a universal x86_64+arm64 binary. Every bundled dylib uses the same architectures and the same minimum OS.
- Protocol is RDP to xrdp. Typing must not drop letters in Russian or English.

### Product

- Native AppKit app. FreeRDP and OpenSSL are built from source and bundled. No Homebrew and no XQuartz on the machine that runs the app.
- Server list: name, host, port, username. Add, edit, delete, connect on double-click. First launch is an empty list. No hardcoded servers or credentials.
- The editor opens with name (optional; defaults to the address), address, user, one password, and a graphics profile. SSH user, host, and port default to the same user, the same address, and 22. The desktop port defaults to 3389. SSH uses that password until a key is installed, then switches to the key. A separate SSH password, ports, screen size, and the other checkboxes sit under **Дополнительно**. New servers default the screen to fit-to-window. Saved servers keep stored values.
- Passwords, SSH private keys, and the GitHub token live in the Keychain (`SecItem`). The write tries the data-protection keychain first. If that returns `errSecMissingEntitlement` (-34018) or `errSecParam`, it falls back to the legacy login keychain. Never in the repo, plist, or JSON. The real `OSStatus` is shown in the UI and in the copyable journal. Save commits text fields without requiring Return. Validation names the missing field.
- Graphics profiles: Economy, Balanced, Quality, plus fixed resolution, fit-to-window, or fullscreen. Stock xrdp 0.9.24 does not negotiate GFX or H.264. Profiles use RemoteFX, resolution, bits per pixel, and desktop-effect flags. Do not embed OpenH264 or FFmpeg.
- Bits per pixel stay stable per server. xrdp allocates a session per user and color depth. Changing 16↔32 opens a different desktop. The editor warns about that.
- Auto-reconnect is app-level: detect a dead link, back off, read the Keychain again, rebuild the SSH tunnel, log in again. FreeRDP’s reconnect cookie is not enough on xrdp 0.9 and is disabled. Do not set `KillDisconnected=true` on the server.
- Clipboard text is on by default.
- Keyboard: scancodes, US layout `0x00000409`, language switch on the remote session. Do not use Unicode keyboard mode with xrdp. The Mac input source should stay ABC/US while the session is focused. Command maps to Ctrl by default. ISO Mac keyboards swap grave and section.
- Russian UI.
- Export/import of one server entry without the password or private key. A certificate fingerprint may be included.
- SSH tunnel on by default for new servers. Local forward to `127.0.0.1` only. Key or password auth. Secrets in the Keychain. Restart the tunnel on reconnect.
- Built-in SSH key generation, copy public key, and install-on-server. Host-key confirmation writes every key type into `~/Library/Application Support/Dalny/known_hosts`. Later `ssh` calls pass `-o UserKnownHostsFile="<that path>"` (the path contains a space, so it is quoted) and `-o StrictHostKeyChecking=yes`. A host-key failure is not reported as a rejected password. Certificate trust-on-first-use with a stored fingerprint and a blocking warning when it changes. Never `/cert:ignore`.
- No Terminal on the Mac for normal use. Logs are an in-app view with copy. README install steps use Finder and System Settings. The updater strips quarantine on the copy it installs.
- In-app updates. Tags `v*` publish a GitHub Release of `Dalny-macos.zip` on `chelekov/dalny`. Launch and **Проверить обновления** call the public Releases API with no token, offer **Обновить**, download the asset with `Accept: application/octet-stream`, check the zip, bundle id `app.dalny.client`, and `codesign --verify`, replace the app, and relaunch. A 403 that is a rate limit asks the user to retry later. **Настройки…** can store an optional token for a private fork; it is not required for the public repo and is never written to the log.
- A network change (including a VPN coming up or down) triggers a clean reconnect. TCP keepalives and SSH `ServerAliveInterval` detect a dead link. Status text says what is happening and why it failed. If a VPN sends all traffic through the same host, that host belongs on the VPN bypass list.
- README in Russian: install, usage, keyboard, graphics, network changes, and a short server-hardening section. Do not recommend `crypt_level=none`.

### CI

- Ubuntu job on every push: `bash -n` and a few static checks. It does not compile the app.
- macOS job only for tags `v*` and `workflow_dispatch`, on `macos-15-intel`, timeout 120 minutes. Default architecture is x86_64. `workflow_dispatch` has an input to also build arm64 and lipo a universal app.
- Concurrency group per ref, cancel in progress.
- A tag `v*` uploads artifact `Dalny-macos` and publishes a GitHub Release with `CFBundleShortVersionString` from the tag and `CFBundleVersion` from the Actions run number. A manual run uploads the artifact and does not replace the latest release.
- `scripts/verify-bundle.sh` checks the architectures that were requested, minos 12.x, no absolute non-system deps, and the clipboard channel.
- This file must stay free of personal details. `docs/rdp-best-practices.md` is the research note. Do not re-introduce GFX, Unicode keyboard mode, cookie-only reconnect, `macos-13`, or `/cert:ignore`.

## Architecture

```
src/main.m                 NSApplicationMain-style bootstrap
src/AppDelegate.m          Russian menus, server table, import/export, settings
src/Server.m               Server model. No secrets in the dictionary.
src/ServerStore.m          ~/Library/Application Support/Dalny/servers.json
src/Keychain.m             SecItem generic passwords, legacy fallback on -34018
src/DalnyLog.m             Copyable journal
src/Updater.m              GitHub Release check, verify, replace, relaunch
src/ServerEditor.m         Short form plus Дополнительно; SSH key create/copy/install
src/SSHClient.m            ssh-keygen, ssh-keyscan, known_hosts, local forward, askpass
src/askpass.c              SSH_ASKPASS helper inside Contents/MacOS
src/SessionWindow.m        Status, log, reconnect loop, path monitor, cert dialog
src/RDPView.m              Bitmap, mouse, scancodes, Command→Ctrl
src/AppleKeyboard.c        IOKit ISO-vs-ANSI detection only (no WinPR in this file)
src/Scancode.c             Mac virtual key → RDP scancode (WinPR only, no CoreFoundation)
src/session.mm             One FreeRDP connection: RFX, US layout, cliprdr, disp, certificate check
scripts/build-macos.sh     OpenSSL + FreeRDP + clang + bundle + codesign + verify
scripts/verify-bundle.sh   lipo + vtool minos + otool dependency check
scripts/check-tree.sh      Cheap checks for the Ubuntu job
.github/workflows/build.yml
```

Connection path when SSH is on (the default):

1. Confirm or prompt for the SSH host key and store it in the app `known_hosts` file.
2. `ssh -N -L 127.0.0.1:<local>:127.0.0.1:<rdpPort>` with `ConnectTimeout=12`, `ServerAliveInterval=5`, `ServerAliveCountMax=2`, `TCPKeepAlive=yes`, `-F /dev/null`.
3. FreeRDP connects to `127.0.0.1:<local>`.
4. On drop, path change, or tunnel death: kill SSH, abort FreeRDP, back off, read the Keychain again, repeat.
5. Authentication failure, a rejected host key, or a rejected certificate stops the loop.

FreeRDP channels are shared libraries copied into `Contents/Frameworks` and loaded with a small `dlopen` provider. Clipboard text uses `cliprdr`. Dynamic resize uses `disp` when the server offers it.

## How the CI build works

`scripts/build-macos.sh`:

1. Download OpenSSL 3.4.1 and FreeRDP 3.33.1.
2. Build OpenSSL shared for the requested architectures with `-mmacosx-version-min=12.0`. A universal build lipos x86_64 and arm64.
3. Configure FreeRDP with Ninja, `CMAKE_OSX_ARCHITECTURES` set to the same list, `CMAKE_OSX_DEPLOYMENT_TARGET=12.0`, shared libs, client only, no SDL, no Mac client sample, no FFmpeg, no H.264, no server. `WITH_JSON_DISABLED=ON` and `CMAKE_IGNORE_PREFIX_PATH=/usr/local;/opt/homebrew`. Pass `-DUSE_VERSION_FROM_GIT_TAG=OFF` so a tag on this repository is not read as the FreeRDP version (that installs headers under `freerdp1` instead of `freerdp3`).
4. Compile the app with `clang`/`clang++` and `-mmacosx-version-min=12.0`. C and Objective-C files pass `-Dnullptr=NULL` because FreeRDP headers use `nullptr`.
5. Copy dylibs into `Contents/Frameworks`, rewrite ids and deps to `@rpath`, sign inside-out with `codesign --sign -`.
6. `scripts/verify-bundle.sh` checks architectures, minos 12.x, dependencies, and clipboard.
7. `ditto` writes `dist/Dalny-macos.zip`.

Each macOS run rebuilds OpenSSL and FreeRDP from scratch. There is no cache.

## Current status

The tree is the public-ready snapshot: short server card, Keychain fallback, quoted `known_hosts` path, and release-based updates. Default CI builds x86_64. Universal is opt-in. Releases that the updater installs are tag `v*` builds.

An already installed copy from before the bundle id was `app.dalny.client` will not accept an update, and its Keychain items are under a different service name. That copy is a different app.

## Known limits

- No sound, drive, or printer redirection.
- Changing 16-bit vs 32-bit color starts a different xrdp session.
- Unicode keyboard mode is intentionally absent.
- The build is ad-hoc signed and not notarized.
- GFX and H.264 stay off until the server is xrdp 0.10 or newer.
