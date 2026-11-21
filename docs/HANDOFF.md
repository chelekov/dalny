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
- Graphics profiles: Economy, Balanced, Quality, Extreme economy (640x480, 8 bpp, no RemoteFX/NSCodec), plus fixed resolution, fit-to-window, or fullscreen. Stock xrdp 0.9.24 does not negotiate GFX or H.264. Profiles use RemoteFX, resolution, bits per pixel, and desktop-effect flags. Do not embed OpenH264 or FFmpeg.
- Bits per pixel stay stable per server. xrdp allocates a session per user and color depth. Changing 8/16/32 opens a different desktop. The editor and the extreme-economy switch warn about that.
- Auto-reconnect is app-level: detect a dead link, back off, read the Keychain again, rebuild the SSH tunnel, log in again. FreeRDP’s reconnect cookie is not enough on xrdp 0.9 and is disabled. Do not set `KillDisconnected=true` on the server.
- Clipboard is on by default: text (Unicode) and pictures both ways over `cliprdr`. Files are not supported.
- Keyboard: scancodes, US layout `0x00000409`, language switch on the remote session (XKB `grp:alt_shift_toggle`, layouts `us,ru`). The session window has an **RU/EN** button with the hint «Язык: ⌥ Option + ⇧ Shift» in the title bar (top right). Menu **Подключение → Переключить язык (RU/EN)**, shortcut ⌘⇧Space (⌃Space is the macOS input-source switch). Both send left Alt + left Shift press/release. Physical Option+Shift is forwarded as LMENU+LSHIFT scancodes. Do not use Unicode keyboard mode with xrdp. The Mac input source should stay ABC/US while the session is focused. Command maps to Ctrl by default. ISO Mac keyboards swap grave and section.
- Russian UI.
- Export/import of one server entry without the password or private key. A certificate fingerprint may be included.
- SSH tunnel on by default for new servers. Local forward to `127.0.0.1` only. Key or password auth. Secrets in the Keychain. Restart the tunnel on reconnect.
- Built-in SSH key generation, copy public key, and install-on-server. Host-key confirmation writes every key type into `~/Library/Application Support/Dalny/known_hosts`. Later `ssh` calls pass `-o UserKnownHostsFile="<that path>"` (the path contains a space, so it is quoted) and `-o StrictHostKeyChecking=yes`. A host-key failure is not reported as a rejected password. Certificate trust-on-first-use with a stored fingerprint and a blocking warning when it changes. Never `/cert:ignore`.
- No Terminal on the Mac for normal use. Logs are an in-app view with copy. README install steps use Finder and System Settings. The updater strips quarantine on the copy it installs.
- In-app updates. Tags `v*` publish a GitHub Release of `Dalny-macos.zip` on `chelekov/dalny`. Launch and **Проверить обновления** call the public Releases API with no token, offer **Обновить**, download the asset with `Accept: application/octet-stream`, check the zip, bundle id `app.dalny.client`, and `codesign --verify`, replace the app, and relaunch. A 403 that is a rate limit asks the user to retry later. **Настройки…** can store an optional token for a private fork; it is not required for the public repo and is never written to the log.
- Network loss never closes the session window (see «Added in 1.0.7»). A network change (including a VPN coming up or down) triggers a clean reconnect unless the live session proves it survived. TCP keepalives and SSH `ServerAliveInterval` detect a dead link. Status text says what is happening and why it failed. If a VPN sends all traffic through the same host, that host belongs on the VPN bypass list.
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
src/ClipboardImage.m       NSPasteboard PNG/TIFF <-> CF_DIB (24-bit BI_RGB out, any BMP in)
src/LanguageSetup.m        One-click server language setup over SSH, no root
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

FreeRDP channels are built into `libfreerdp-client3` (static table). A small provider asks that table first and then falls back to `dlopen` of `lib<name>-client.dylib` in `Contents/Frameworks`. Clipboard text and pictures use `cliprdr` (`-DCHANNEL_CLIPRDR=ON` is explicit in the build and `check-tree.sh` checks it; `verify-bundle.sh` checks the channel is linked). Dynamic resize uses `disp` when the server offers it.

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

### Fixed in 1.0.4

- Every connect failed with «A configuration error prevented a connection to be established» (`FREERDP_ERROR_PRE_CONNECT_FAILED`). Heartbeat PDU and multitransport are on by default in FreeRDP 3. They make `freerdp_client_load_addins` force rdpdr and add a static `rdpsnd sys:fake` channel. rdpsnd is not built (`CHANNEL_RDPSND=OFF`), so channel loading failed before any TCP connect. `apply_graphics` now turns off `SupportHeartbeatPdu`, `SupportMultitransport`, `DeviceRedirection`, and `AudioPlayback`. If sound or rdpdr are ever enabled, build `CHANNEL_RDPSND` too.
- FreeRDP WLog warnings and errors go to the in-app log (root callback appender). Every failed connect logs the last error name, code, and text.
- `PRE_CONNECT_FAILED` and `POST_CONNECT_FAILED` stop auto-reconnect.
- A wrong login or password (RDP `AUTHENTICATION_FAILED`, `LOGON_FAILURE`, `WRONG_PASSWORD`, `NO_OR_MISSING_CREDENTIALS`, a failed logon info from the server, or SSH `Permission denied`, error code 4) stops the loop and opens a dialog to re-enter the user name and password. The dialog saves them to the Keychain and reconnects. A rejected SSH key only shows a notice. xrdp 0.9 without NLA may show its own login screen instead of returning an error; that case shows up inside the session.

### Added in 1.0.5

- Language switch button and menu item (see Requirements → Keyboard). `RDPView` lets ⌘⇧Space go to the menu. `sendLanguageToggle` first releases every key the server still holds, so the server sees exactly Alt+Shift.
- `windowDidResignKey` releases all keys on the server. Before, ⌘Tab left Ctrl (from Command) held on the server, and the next Option+Shift arrived as Ctrl+Alt+Shift and did not switch.
- **Подключение → Настроить переключение языка на сервере…** (session window or the selected server in the list). Runs a POSIX `sh` script over SSH as the SSH user (`SSHClient runScript:`, base64 on the command line, same `known_hosts` rules, key or password from the Keychain). No sudo. The script:
  - finds the user's X display from `/proc/<pid>/environ` of the user's own processes (prefers `:10` and up and a process with `DBUS_SESSION_BUS_ADDRESS`);
  - XFCE: `xfconf-query -c keyboard-layout` sets `/Default/XkbDisable false`, `/Default/XkbLayout us,ru`, `/Default/XkbVariant ,`, `/Default/XkbOptions/Group grp:alt_shift_toggle` (`-n -t`, then without them if the property exists). With no session bus and no `xfconfd`, it writes `keyboard-layout.xml` instead (old file kept as `.dalny-backup`);
  - `setxkbmap -layout us,ru -variant , -option grp:alt_shift_toggle` on that display;
  - prints `DALNY_DISPLAY=`, `DALNY_XFCONF=ok|file|skip|fail`, `DALNY_SETXKBMAP=ok|nodisplay|missing|fail`. The app logs every line and shows an alert.
- After the first frame of a session, if SSH is on and the server field `languageSetup` is empty, a sheet asks once. The answer (`done` / `declined`) is saved in `servers.json`; it is not exported.
- Manual commands for XFCE and for other desktops are in the README («Переключение языка на сервере»).
- Picture clipboard:
  - Mac → server: the 0.5 s pasteboard poll reads PNG or TIFF (not when a file URL is present: Finder also puts the file icon there), draws it on white, and writes a 24-bit bottom-up `BITMAPINFOHEADER` DIB. The format list offers WinPR's text formats plus `CF_DIB`. A `CF_DIB` request is answered from that buffer. xrdp 0.9.24 shows it to X as `image/bmp`. Limit 20 megapixels / 64 MB.
  - Server → Mac: when the server list has no text format, the client asks for `CF_DIB` (or `CF_DIBV5`), adds a 14-byte BMP file header (offset from header size, masks and palette), decodes it with `NSBitmapImageRep` and puts PNG and TIFF on the pasteboard. Text still wins when both are offered.
  - A new session offers the current Mac clipboard right away. The pasteboard timer keeps running across reconnects (before, it stopped after the first reconnect).
  - The session window clears `RDPView.session` synchronously on the main thread before freeing the session.
- Files: not supported. It needs `FileGroupDescriptorW` plus `FileContents` streaming and, on xrdp 0.9, FUSE in chansrv. Use SFTP over the same SSH.

### Fixed in 1.0.6

- Fixed mode (for example 1280x800) left a white strip at the bottom of the session window. The hidden log still held its 160 pt because `_view.bottom` was tied to `_logScroll.top`. Now `_view` goes to the window bottom while the log is hidden (`_viewToBottom` / `_viewToLog`).
- The session window background is black (dark appearance), so any area the picture does not cover is black.
- `RDPView` draws the frame in its own `CALayer` placed at `imageRect`. Before, `layer.contents` stretched the frame over the whole view while the mouse used a centered, aspect-kept rectangle, so clicks were off. Drawing and mouse mapping now use the same rectangle; points outside it are ignored, coordinates are clamped to the remote size. Remote size is only touched on the main thread.
- Fixed mode: before the first frame and whenever the remote size changes, the window content is set to remote size (1 pixel = 1 point; on Retina this is sharp at 2x) plus the controls above the picture. `contentMaxSize` is that size, so the window cannot grow past the desktop. A smaller window scales the picture down with the aspect kept. When the remote desktop is larger than the screen's `visibleFrame`, the window is made to fit and the picture is scaled down (logged once). Showing or hiding the log, moving to another screen, and leaving full screen refit the window; full screen lifts the size limit.
- Fit and full-screen modes already resize the remote desktop through the Display Control channel (`rdp_session_request_resize` → `DISPLAY_CONTROL_MONITOR_LAYOUT`) at the end of a live resize. Zoom, tiling and screen changes now also ask, debounced by 0.5 s. When the server has no Display Control (xrdp 0.9.x may not offer it), the picture is just scaled in the window.
- QuartzCore is linked explicitly.

### Added in 1.0.7

- Owner report: turning a VPN on or off closed the session window. Cause: when `runLoop` ended (for example a failure classified as fatal while the link was being torn down), it posted `DalnySessionFinished`; `AppDelegate` dropped the last strong reference to the `SessionWindow`, so the window vanished (and FreeRDP callbacks still held a raw pointer to it). Now `DalnySessionFinished` is posted only from `windowWillClose:` (asynchronously). The run loop ending only shows an overlay.
- Drop detection: FreeRDP disconnect; SSH tunnel process exit (`SSHClient checkAlive`, polled twice a second; tunnel stderr now stays open and is logged, so ssh never writes into a closed pipe); `NWPathMonitor` path/interface change; TCP keepalive (10 s + 3×5 s) and SSH `ServerAliveInterval=5`/`CountMax=2`; app-level link probe stall of 20 s.
- Link probe (`session.mm probe_link`): when no update arrived for 2 s, the session thread sends a Refresh Rect PDU for a 16x16 area and times the next update (any update counts). `RDPHandlers.link(rttMs, stalledMs, proven)` reports it. Stall reports only count once the server has answered a probe in this session (`proven`), so a server that ignores Refresh Rect never shows false warnings.
- Lost-link overlay over the picture: «Связь потеряна — переподключаюсь… (попытка N)», buttons «Переподключиться сейчас» (wakes the backoff sleep) and «Отключиться». Backoff 1, 2, 4, 8, 15, 30 s, then 30 s, give up after about 300 s of trying with the network up (time without any network does not count). After giving up the window stays with a large «Переподключиться» button that restarts the loop (`startLoop`). Menu **Подключение → Переподключиться** does the same.
- Each attempt restarts the SSH tunnel on a newly reserved local port. Path down → abort and wait for a satisfied path (the old `sleepSeconds` returned at once while offline and spun the loop; fixed). Path change while the session is proven alive → 6 s check: if a probe is answered, keep the session; otherwise reconnect at once. Without proven probes → immediate clean reconnect as before.
- Same xrdp session on reconnect: same user, same bpp, and in fit/full-screen modes the last remote size (`_lastRemoteWidth/Height`) instead of the current view size; after the first frame the window size is requested again through Display Control.
- A stop requested by the app (`session->stop`, generation change, dead tunnel, stall) is never fatal. Auth errors (credentials dialog), certificate rejection, `PRE/POST_CONNECT_FAILED`, SSH host key and rejected key still stop auto-reconnect (1.0.4 behavior); the window stays with the overlay and the manual button.
- Poor connection: smoothed probe RTT > 800 ms or no answer for 3 s (proven) shows a yellow non-blocking bar at the top of the picture: «Плохое соединение: …», button «Переключиться на экстремальную экономию», «Скрыть». It hides after 10 s of RTT < 500 ms.
- Extreme economy profile `graphics = "extreme"` (`profileIndex` 3): 640x480 fixed, 8 bpp (256 colors; there is no 1-bit/black-and-white mode in RDP to xrdp), RemoteFX and NSCodec off, wallpaper/themes/menu animations/full-window drag/font smoothing/desktop composition off, cursor shadow and blinking off, bitmap cache and RDP 6.1 compression on, connection type modem. No frame-rate setting exists outside GFX. Switching from the session window (bar button or menu **Подключение → Экстремальная экономия**) asks first, saves the previous profile in `profileBeforeExtreme` (servers.json, not exported), and reconnects; choosing the menu item again restores it. The editor shows a hint per profile, including the separate-session note.

## Known limits

- No sound, drive, or printer redirection.
- No file copy through the clipboard. Pictures only through `image/bmp` on the X side.
- Changing 8/16/32-bit color starts a different xrdp session.
- 8 bpp needs xrdp to accept 8-bit clients (stock xrdp 0.9 does). Not tested live yet.
- Unicode keyboard mode is intentionally absent.
- The build is ad-hoc signed and not notarized.
- GFX and H.264 stay off until the server is xrdp 0.10 or newer.
