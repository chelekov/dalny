# Best practices for a macOS RDP client (FreeRDP + xrdp 0.9.24)

Research date: 21 November 2026.  
Scope: native app embedding FreeRDP, built in GitHub Actions. Target: macOS 12 or later, Intel and Apple Silicon, talking to Ubuntu 24.04 + XFCE + stock xrdp 0.9.24 / xorgxrdp.  
Priorities: stable connection and auto-reconnect, low-bandwidth graphics, reliable Russian/English typing, clipboard, security.

Each recommendation has a one-line rationale and a source URL that was opened during this research. Recommendations are ordered by impact within each section.

---

## Conflicts with the current plan

These items should be applied so the implementation does not take the wrong graphics, keyboard, or CI path.

1. **Do not design graphics profiles around GFX / H.264 / AVC420 / AVC444 / GFX-progressive.** Ubuntu 24.04’s packaged xrdp is 0.9.24. GFX landed in xrdp / xorgxrdp 0.10 and is the feature that “achieves more frame rates and less bandwidth compared to v0.9.” Against 0.9.24 those client flags will not negotiate; RemoteFX (`/rfx`) is the codec that actually works. Skip embedding OpenH264/FFmpeg unless you later upgrade the server to 0.10. Source: https://github.com/neutrinolabs/xrdp/discussions/3070

2. **Do not enable FreeRDP `/kbd:unicode` against xrdp.** FreeRDP itself warns that Unicode input “Does not work with every RDP server.” xrdp maintainers state that the server does not support `TS_UNICODE_KEYBOARD_EVENT` / `TS_FP_UNICODE_KEYBOARD_EVENT`. Unicode input drops letters; scancodes plus a server-side layout are the correct fix. Sources: https://raw.githubusercontent.com/FreeRDP/FreeRDP/master/client/common/cmdline.h and https://github.com/neutrinolabs/xrdp/issues/2337

3. **Do not rely on FreeRDP’s AutoReconnect cookie alone.** FreeRDP exposes `/auto-reconnect` and `/auto-reconnect-max-retries`, but xrdp 0.9.x reconnects by starting a new RDP login and attaching to an existing session after credentials are supplied again. Cookie-style silent reconnect is not a 0.9 feature. The app must detect a dead link, back off, re-authenticate from Keychain, and rejoin the session. Also, sesman’s default policy allocates a session per `<User,BitPerPixel>`, so changing color depth between “economy” and “quality” can create a *new* desktop instead of reconnecting. Sources: https://raw.githubusercontent.com/FreeRDP/FreeRDP/master/client/common/cmdline.h , https://github.com/neutrinolabs/xrdp/discussions/2717 , https://manpages.ubuntu.com/manpages/noble/man5/sesman.ini.5.html

4. **GitHub Actions: do not use `macos-13` for the Intel build.** The `macos-13` image was retired on 4 December 2025. As of late 2026 the Intel label to use is `macos-15-intel`, with `MACOSX_DEPLOYMENT_TARGET=12.0` and `-arch x86_64` so the binary still runs on macOS 12. GitHub will drop macOS x86_64 runners when the macOS 15 image retires in Fall 2027 — an Apple Silicon or universal build can be produced separately, but the default build does not require it. Source: https://github.blog/changelog/2025-09-19-github-actions-macos-13-runner-image-is-closing-down/

5. **Do not copy “speed” tips that weaken security or break reconnect.** Some popular xrdp tuning posts set `crypt_level=none` and `KillDisconnected=true`. The first downgrades RDP security; the second destroys the XFCE session on a drop, which fights auto-reconnect. Prefer TLS + leaving disconnected sessions alive. Sources: https://askubuntu.com/questions/1323601/xrdp-is-quite-slow (community tip to avoid) and https://manpages.ubuntu.com/manpages/noble/man5/xrdp.ini.5.html

6. **Ad-hoc signing will not pass Gatekeeper on a downloaded `.app`.** An ad-hoc or unsigned GitHub Actions artifact gets the `com.apple.quarantine` attribute. macOS 12 and later expects Developer ID + notarization for internet-downloaded apps. For an unsigned build this is acceptable if the README says to Control-click or use System Settings → Privacy & Security → Open Anyway. Do not claim the app will “just launch.” Source: https://support.apple.com/en-us/102445

---

## (A) Client app implementation

**A1. Send physical scancodes, announce a stable US layout (0x00000409), and switch Russian/English on the Ubuntu session — never on the Mac input source during typing.**  
Why: RDP scancode input identifies each key by physical position, and the remote layout produces the character. xrdp applies the client-advertised layout only at session create/reconnect, assumes a single layout per connection, and ignores mid-session client layout changes. Keep the Mac input source on US/ABC while the session is focused so scancodes stay consistent. Provide a documented server-side toggle (for example Ctrl+Alt or a Super+Space mapping via `setxkbmap`).  
Source: https://github.com/neutrinolabs/xrdp/issues/2337

**A2. Always request RemoteFX; treat “LAN” as a codec hint, not a bandwidth claim; cut traffic with resolution, bpp, and desktop effects — not by disabling RFX.**  
Why: An xrdp maintainer’s guidance is that the best improvement on recent 0.9.x is to enable the RFX codec, which is what a LAN connection type asks for. FreeRDP equivalents are `/rfx`, `/network:lan`, `+compression`, and turning off wallpaper, themes, aero, window-drag, and menu animations. Economy profile: modest geometry (for example 1280×800 or 1600×900), `/bpp:16`, visuals off. Balanced/quality: keep RFX, raise geometry and `/bpp:32`. Do not default to `/network:modem` if that causes the client to drop RFX and fall back to raw bitmaps.  
Sources: https://github.com/neutrinolabs/xrdp/discussions/2136 and https://raw.githubusercontent.com/FreeRDP/FreeRDP/master/client/common/cmdline.h

**A3. Implement application-level auto-reconnect with heartbeat, exponential backoff, and Keychain re-authentication, and keep bpp/geometry policy-safe.**  
Why: Enable FreeRDP `heartbeat` and `/auto-reconnect` as helpers, but the app must watch for a dropped TCP/TLS session (including when the SSH tunnel dies), retry with jittered backoff, log in again, and attach to the existing XFCE session. Warn or persist bpp per server so a profile change does not allocate a second desktop under sesman’s `<User,BitPerPixel>` policy. After reconnect, re-open clipboard (and audio if added later): xrdp 0.9 has a known failure where a second client cannot attach to `chansrv` while the first is still half-connected.  
Sources: https://raw.githubusercontent.com/FreeRDP/FreeRDP/master/client/common/cmdline.h , https://manpages.ubuntu.com/manpages/noble/man5/sesman.ini.5.html , https://github.com/neutrinolabs/xrdp/discussions/2717

**A4. Turn clipboard on by default (text first), and treat file/image paste as optional.**  
Why: FreeRDP supports `+clipboard` with direction controls. xrdp requires `[Channels] cliprdr=true` and, for file copy, FUSE (`EnableFuseMount` in sesman). Text is the requirement; file and image paths have had more regressions. After a flaky reconnect, offer a “reconnect channels” or full reconnect action rather than silently failing paste.  
Sources: https://raw.githubusercontent.com/FreeRDP/FreeRDP/master/client/common/cmdline.h and https://manpages.ubuntu.com/manpages/noble/man5/sesman.ini.5.html

**A5. Embed FreeRDP and its dylibs inside the `.app`, rewrite them to `@rpath`, and sign from the inside out; build on `macos-15-intel` for macOS 12 x86_64.**  
Why: Put libraries in `Contents/Frameworks` (helpers in `Contents/MacOS`), use `@rpath` / `@executable_path/../Frameworks`, and run `install_name_tool` *before* signing — `install_name_tool` breaks signatures. Sign each nested dylib, then the app last. Apple’s TN2206 also warns that Gatekeeper verifies libraries loaded from outside the bundle. Set `MACOSX_DEPLOYMENT_TARGET=12.0` and `-arch x86_64` on `macos-15-intel` (see conflict 4). For an unsigned distribution, ad-hoc `codesign --sign -` is enough if the Open Anyway steps are documented.  
Sources: https://developer.apple.com/documentation/xcode/embedding-nonstandard-code-structures-in-a-bundle , https://developer.apple.com/library/archive/technotes/tn2206/_index.html , https://github.blog/changelog/2025-09-19-github-actions-macos-13-runner-image-is-closing-down/

**A6. Store passwords only in the macOS Keychain via the SecItem API, targeting the data-protection keychain.**  
Why: Apple’s current guidance is: use SecItem (not the old SecKeychain APIs), prefer the data-protection keychain with `kSecUseDataProtectionKeychain`, add after a successful login, update when the password changes, delete on “forget.” Use `kSecClassGenericPassword` (or Internet password) keyed by service + account, and `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so secrets stay on that Mac and are available only while unlocked. An ad-hoc signature without a keychain entitlement gets `errSecMissingEntitlement` (-34018); fall back to the legacy login keychain in that case. Never write passwords into the GitHub repo, plist, or logs.  
Sources: https://developer.apple.com/documentation/security/using-the-keychain-to-manage-user-secrets , https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains , https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility

---

## (B) Server-side xrdp / XFCE tuning

**B1. Permanently disable the XFCE compositor in the xrdp session.**  
Why: xfwm compositing forces extra full-screen redraws that xrdp must encode. The widely confirmed fix is `xfconf-query --channel=xfwm4 --property=/general/use_compositing --type=bool --set=false --create` (also available in Window Manager Tweaks). Put it in the user’s autostart or `/etc/xrdp/startwm.sh` so it survives new sessions. Use a solid-color wallpaper and turn off XFCE window effects.  
Source: https://askubuntu.com/questions/1323601/xrdp-is-quite-slow

**B2. Tune `/etc/xrdp/xrdp.ini` for RFX-era 0.9 performance without weakening TLS.**  
Why: Keep `bitmap_cache`, `bitmap_compression`, and `bulk_compression` enabled; set `use_fastpath=both` if it is not already (the man page default is `none` when the key is absent); leave `tcp_nodelay=true` and `tcp_keepalive=true`; enable `cliprdr` (and `drdynvc` if you later move to 0.10 GFX). On wide-area links, raising `tcp_send_buffer_bytes=4194304` and `net.core.wmem_max=8388608` is the fix documented by xrdp for a too-small 32 KiB send buffer. Do not set `crypt_level=none`. Leave `max_bpp` at 32 on the server and let the *client* request 16 or 32 so graphics profiles stay client-side. Confirm `security_layer=negotiate` or `tls` and `ssl_protocols` includes only TLSv1.2 / TLSv1.3.  
Sources: https://manpages.ubuntu.com/manpages/noble/man5/xrdp.ini.5.html and https://github.com/neutrinolabs/xrdp/issues/1483

**B3. Configure a bilingual `us,ru` layout in the session, and treat `km-*.ini` as the login-screen path, not the main xorgxrdp path.**  
Why: xrdp maps the client layout ID through `/etc/xrdp/xrdp_keyboard.ini` (`rdp_layout_ru=0x00000419` → XKB `ru`). The RDP protocol still assumes one layout for scancodes. Start the session with something like `setxkbmap -layout 'us,ru' -option grp:alt_shift_toggle` (or another explicit toggle) in autostart/`reconnectwm.sh`. If the client announces US, the physical keys stay stable and the language is switched inside Ubuntu. After reconnect, re-apply the layout in `reconnectwm.sh` because a reattached session can fall back to a single layout.  
Sources: https://github.com/neutrinolabs/xrdp/issues/2337 and https://manpages.ubuntu.com/manpages/noble/man5/sesman.ini.5.html (`ReconnectScript`)

**B4. Keep disconnected sessions alive, and do not restart the xrdp service casually.**  
Why: For auto-reconnect, set `KillDisconnected=false` (default) so a brief drop does not destroy XFCE. Note that `systemctl restart xrdp` in 0.9.x *loses* the ability to attach to existing sessions — that is expected, not a client bug. `AllowRootLogin=false` and a finite `MaxLoginRetry` belong in sesman security settings.  
Sources: https://manpages.ubuntu.com/manpages/noble/man5/sesman.ini.5.html and https://github.com/neutrinolabs/xrdp/discussions/2717

---

## (C) Security

**C1. Do not expose TCP 3389 to the public internet. Bind xrdp to localhost and reach it through an SSH tunnel (or a VPN).**  
Why: CISA lists open RDP as a high-risk, routinely exploited ransomware vector and says systems with an open RDP port should sit behind a firewall. Opening 3389 to the internet is a poor default; an SSH tunnel or a VPN is safer. In `/etc/xrdp/xrdp.ini` set `address=127.0.0.1` and `port=3389` (do not rely on the easy-to-get-wrong `port=tcp://.:3389` form). The Mac app should start `ssh -N -L 127.0.0.1:<local>:127.0.0.1:3389 user@host` and then point FreeRDP at `127.0.0.1:<local>`. Firewall the host so only SSH is public.  
Sources: https://www.cisa.gov/news-events/cybersecurity-advisories/aa22-137a , https://github.com/neutrinolabs/xrdp/discussions/1958 , https://manpages.ubuntu.com/manpages/noble/man5/xrdp.ini.5.html

**C2. Verify the xrdp TLS certificate with TOFU or an explicit fingerprint — never `/cert:ignore`.**  
Why: Stock xrdp uses a self-signed `/etc/xrdp/cert.pem`, so a public CA check will fail, but ignoring certificates disables MITM detection. FreeRDP’s `/cert:tofu` accepts the first certificate and *denies* later changes; `/cert:fingerprint:<algo>:<hash>` pins a known hash. Persist accepted fingerprints in the app (or use FreeRDP’s `known_hosts2` store) and show a blocking UI if the cert rotates. Prefer generating a stable cert for the host and pinning it.  
Sources: https://github.com/FreeRDP/FreeRDP/wiki/CommandLineInterface-(possibly-not-up-to-date,-check-application-help-text-for-most-up-to-date-version) and https://github.com/FreeRDP/FreeRDP/discussions/7016

**C3. Harden the SSH front door, since that becomes the only public path.**  
Why: Once 3389 is loopback-only, attackers hit SSH instead. Use key-only authentication, disable password SSH, keep `fail2ban`’s `sshd` jail on, and restrict `ufw`/`nftables` to SSH from known networks if possible. CISA specifically calls out MFA for remote access and strong passwords as mitigations around RDP-related intrusions; a passphrase-protected SSH key (stored in the Keychain) is the practical control. Do not put SSH private keys or RDP passwords in the GitHub repo.  
Source: https://www.cisa.gov/news-events/cybersecurity-advisories/aa22-137a

---

## Optional later work (not required for v1)

- Upgrading the server to xrdp / xorgxrdp 0.10 gives GFX (better frame rate and bandwidth). That is a server change, not a client-only switch, and GFX generally wants `max_bpp=32`. H.264/AVC444 was still not in 0.10.0. Source: https://github.com/neutrinolabs/xrdp/discussions/3070
- A Developer ID certificate plus notarization would remove the Gatekeeper dance for downloaded builds. Source: https://support.apple.com/en-us/102445
- A later universal or Apple Silicon build, before GitHub retires Intel macOS runners in Fall 2027. Source: https://github.blog/changelog/2025-09-19-github-actions-macos-13-runner-image-is-closing-down/

---

## Краткое резюме (Russian summary)

Клиент собран вокруг FreeRDP. Для Ubuntu 24.04 и штатного xrdp 0.9.24 нельзя закладывать GFX/H.264 — они появляются только в xrdp 0.10. Для слабого канала нужно включать RemoteFX, уменьшать разрешение и лишние эффекты рабочего стола, а на сервере выключить композитинг XFCE. Чтобы русский и английский печатались без пропадающих букв, клиент шлёт сканкоды клавиш, а раскладка переключается в Ubuntu; режим Unicode в xrdp не поддерживается. Автопереподключение нельзя оставить только на встроенной опции FreeRDP: xrdp 0.9 после обрыва просит войти снова, поэтому программа сама переподключается с паролем из Связки ключей и не убивает сессию на сервере. Порт 3389 лучше не выставлять в интернет: слушать только localhost и ходить через SSH-туннель, проверять сертификат сервера при первом подключении (TOFU), без «игнорировать сертификат». Сборку в GitHub Actions нужно делать на Intel-раннере `macos-15-intel` с целью macOS 12; скачанный файл Gatekeeper сначала может не открыть — это нормально для подписи без платного сертификата Apple, его можно разрешить вручную в настройках безопасности.
