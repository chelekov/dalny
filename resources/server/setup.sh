# Dalny server setup: keyboard (us,ru + Alt+Shift) and picture clipboard, for this user only.
# Runs as the SSH user, never as root. Safe to run again: every step checks first. The app prepends DALNY_KB_B64 and
# DALNY_CB_B64 (the helper scripts, base64) and runs this with sh over SSH.
export LC_ALL=C
uid=$(id -u)
DISP=''; BUS=''; XA=''; best=-1
# Find the user's X display: xrdp sessions use :10 and up. Prefer a process that also knows the
# session D-Bus (xfconf, gsettings and ibus need it).
for p in $(pgrep -u "$uid" 2>/dev/null); do
  [ -r "/proc/$p/environ" ] || continue
  env=$( { tr '\000' '\n' < "/proc/$p/environ"; } 2>/dev/null) || continue
  d=$(printf '%s\n' "$env" | sed -n 's/^DISPLAY=//p' | head -n 1)
  case "$d" in :*) ;; *) continue ;; esac
  n=${d#:}; n=${n%%.*}
  case "$n" in ''|*[!0-9]*) continue ;; esac
  b=$(printf '%s\n' "$env" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -n 1)
  score=$n
  [ -n "$b" ] && score=$((score + 1000))
  [ "$n" -ge 10 ] && score=$((score + 100000))
  if [ "$score" -gt "$best" ]; then
    best=$score; DISP=$d; BUS=$b
    XA=$(printf '%s\n' "$env" | sed -n 's/^XAUTHORITY=//p' | head -n 1)
  fi
done
echo "DALNY_DISPLAY=${DISP:-none}"
XA=${XA:-$HOME/.Xauthority}
run_x() { DISPLAY="$DISP" XAUTHORITY="$XA" DBUS_SESSION_BUS_ADDRESS="${BUS:-$DBUS_SESSION_BUS_ADDRESS}" "$@"; }
# Double fork with all fds closed, so the SSH command returns at once.
start_bg() {
  ( DISPLAY="$DISP" XAUTHORITY="$XA" DBUS_SESSION_BUS_ADDRESS="${BUS:-$DBUS_SESSION_BUS_ADDRESS}" \
    exec setsid nohup "$@" >/dev/null 2>&1 </dev/null & ) >/dev/null 2>&1 </dev/null
}

# 1. Helpers in ~/.local/share/dalny, started at every login from ~/.config/autostart.
dir="$HOME/.local/share/dalny"
auto="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
mkdir -p "$dir" "$auto"
install_helper() { # name base64 -> prints changed|same|fail
  tmp="$dir/.$1.new"
  if ! printf '%s' "$2" | base64 -d > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    rm -f "$tmp"; echo fail; return
  fi
  chmod 755 "$tmp"
  if [ -f "$dir/$1" ] && cmp -s "$tmp" "$dir/$1"; then rm -f "$tmp"; echo same; return; fi
  mv -f "$tmp" "$dir/$1" && echo changed || echo fail
}
autostart() { # name exec comment
  cat > "$auto/$1.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=$1
Comment=$3
Exec="$2" --watch
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
DESKTOP
}
kb=$(install_helper dalny-keyboard "$DALNY_KB_B64")
[ "$kb" != fail ] && autostart dalny-keyboard "$dir/dalny-keyboard" "Dalny: keeps us,ru and Alt+Shift after xrdp reconnects"
# Old autostart entries that call setxkbmap with other layouts fight with us; switch them off.
for f in "$auto"/*.desktop; do
  [ -f "$f" ] || continue
  case "${f##*/}" in dalny-*) continue ;; esac
  if grep -q '^Exec=.*setxkbmap' "$f" && ! grep -q '^Hidden=true' "$f"; then
    cp -p "$f" "$f.dalny-backup"
    sed -i '/^\[Desktop Entry\]/a Hidden=true' "$f"
    echo "DALNY_AUTOSTART_OFF=${f##*/}"
  fi
done

# 2. XFCE keyboard settings (xfsettingsd applies them at login).
xf=skip
if command -v xfconf-query >/dev/null 2>&1; then
  xq() { if [ -n "$BUS" ]; then DBUS_SESSION_BUS_ADDRESS="$BUS" xfconf-query "$@"; else xfconf-query "$@"; fi; }
  setp() { xq -c keyboard-layout -p "$1" -n -t "$2" -s "$3" 2>/dev/null || xq -c keyboard-layout -p "$1" -s "$3"; }
  if [ -n "$BUS" ] || pgrep -u "$uid" -x xfconfd >/dev/null 2>&1; then
    if setp /Default/XkbDisable bool false && setp /Default/XkbLayout string us,ru &&
       setp /Default/XkbVariant string , && setp /Default/XkbOptions/Group string grp:alt_shift_toggle; then
      xf=ok
    else
      xf=fail
    fi
  else
    # No running XFCE session: write the channel file, xfconfd reads it at the next login.
    f="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/keyboard-layout.xml"
    mkdir -p "${f%/*}"
    [ -f "$f" ] && cp -p "$f" "$f.dalny-backup"
    cat > "$f" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="keyboard-layout" version="1.0">
  <property name="Default" type="empty">
    <property name="XkbDisable" type="bool" value="false"/>
    <property name="XkbLayout" type="string" value="us,ru"/>
    <property name="XkbVariant" type="string" value=","/>
    <property name="XkbOptions" type="empty">
      <property name="Group" type="string" value="grp:alt_shift_toggle"/>
    </property>
  </property>
</channel>
XML
    xf=file
  fi
fi
echo "DALNY_XFCONF=$xf"

# 3. ibus: with keyboard engines (xkb:us, xkb:ru) it runs setxkbmap with its own layout on every
# engine change and grabs Alt+Shift_L. Keep ibus for other input methods, but let XKB own the
# layouts: system layout on, one keyboard engine, no Alt+Shift hotkey.
ib=absent
if command -v gsettings >/dev/null 2>&1 && gsettings list-schemas 2>/dev/null | grep -qx org.freedesktop.ibus.general; then
  gs() { run_x gsettings "$@"; }
  save="$HOME/.config/dalny/ibus-before.txt"
  if [ ! -f "$save" ]; then
    mkdir -p "${save%/*}"
    { gs list-recursively org.freedesktop.ibus.general; gs list-recursively org.freedesktop.ibus.general.hotkey
      gs list-recursively org.freedesktop.ibus.panel; } > "$save" 2>/dev/null
  fi
  engines=$(gs get org.freedesktop.ibus.general preload-engines 2>/dev/null | sed 's/^@as //; s/[][]//g' | tr ',' '\n' |
            sed "s/^ *//; s/ *$//" | grep -v "^'xkb:" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
  list="'xkb:us::eng'"
  [ -n "$engines" ] && list="$list, $engines"
  if gs set org.freedesktop.ibus.general use-system-keyboard-layout true &&
     gs set org.freedesktop.ibus.general preload-engines "[$list]" &&
     gs set org.freedesktop.ibus.general engines-order "[$list]" &&
     gs set org.freedesktop.ibus.general.hotkey next-engine "@as []" &&
     gs set org.freedesktop.ibus.general.hotkey next-engine-in-menu "@as []" &&
     gs set org.freedesktop.ibus.general.hotkey prev-engine "@as []" &&
     gs set org.freedesktop.ibus.general.hotkey previous-engine "@as []"; then
    ib=ok
  else
    ib=fail
  fi
  if [ -n "$DISP" ] && command -v ibus >/dev/null 2>&1 && pgrep -u "$uid" -x ibus-daemon >/dev/null 2>&1; then
    run_x ibus engine xkb:us::eng >/dev/null 2>&1
  fi
fi
echo "DALNY_IBUS=$ib"

# 4. Layout indicator: the ibus tray icon shows the ibus engine, not the real layout, so put the
# XFCE keyboard-layout plugin next to the tray and hide the ibus icon.
pn=skip
xkbso=''
for f in /usr/lib/*/xfce4/panel/plugins/libxkb.so /usr/lib/xfce4/panel/plugins/libxkb.so; do [ -f "$f" ] && xkbso=$f; done
if [ -n "$xkbso" ] && command -v xfconf-query >/dev/null 2>&1 && [ -n "$BUS" ] && pgrep -u "$uid" -x xfce4-panel >/dev/null 2>&1; then
  pq() { DBUS_SESSION_BUS_ADDRESS="$BUS" xfconf-query -c xfce4-panel "$@"; }
  have=''
  for p in $(pq -l 2>/dev/null | grep -E '^/plugins/plugin-[0-9]+$'); do
    [ "$(pq -p "$p" 2>/dev/null)" = xkb ] && have=${p##*-}
  done
  if [ -n "$have" ]; then
    pn=present
  else
    target=''; ids=''
    for panel in $(pq -l 2>/dev/null | sed -n 's|^/panels/\(panel-[0-9]*\)/plugin-ids$|\1|p'); do
      list=$(pq -p "/panels/$panel/plugin-ids" 2>/dev/null | grep -E '^[0-9]+$')
      for id in $list; do
        [ "$(pq -p "/plugins/plugin-$id" 2>/dev/null)" = systray ] && { target=$panel; ids=$list; }
      done
    done
    if [ -n "$target" ]; then
      new=1
      for p in $(pq -l 2>/dev/null | sed -n 's|^/plugins/plugin-\([0-9]*\)$|\1|p'); do
        [ "$p" -ge "$new" ] && new=$((p + 1))
      done
      args=''
      for id in $ids; do
        if [ "$(pq -p "/plugins/plugin-$id" 2>/dev/null)" = systray ]; then args="$args -t int -s $new"; fi
        args="$args -t int -s $id"
      done
      if pq -p "/plugins/plugin-$new" -n -t string -s xkb &&
         pq -p "/plugins/plugin-$new/display-type" -n -t uint -s 1 &&
         pq -p "/plugins/plugin-$new/group-policy" -n -t uint -s 0 &&
         pq -p "/panels/$target/plugin-ids" --force-array $args; then
        # The panel reads its plugin list only at start. `xfce4-panel -r` can race with itself and
        # leave no panel, so quit, wait, and start it again (once more if it did not come up).
        run_x xfce4-panel --quit >/dev/null 2>&1
        i=0
        while pgrep -u "$uid" -x xfce4-panel >/dev/null 2>&1 && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
        sleep 1
        for try in 1 2; do
          pgrep -u "$uid" -x xfce4-panel >/dev/null 2>&1 && break
          start_bg xfce4-panel
          sleep 2
        done
        pgrep -u "$uid" -x xfce4-panel >/dev/null 2>&1 || pn=nopanel
        [ "$pn" = nopanel ] || pn=added
        have=$new
      else
        pn=fail
      fi
    fi
  fi
  if [ -n "$have" ] && [ "$ib" = ok ]; then
    run_x gsettings set org.freedesktop.ibus.panel show-icon-on-systray false >/dev/null 2>&1
  fi
fi
echo "DALNY_PANEL=$pn"

# 5. Apply the layouts now and keep them: xorgxrdp loads plain "us" on every reconnect.
sx=missing
if command -v setxkbmap >/dev/null 2>&1; then
  if [ -z "$DISP" ]; then
    sx=nodisplay
  elif [ "$kb" = fail ]; then
    run_x setxkbmap -layout us,ru -variant , -option '' -option grp:alt_shift_toggle && sx=ok || sx=fail
  else
    r=$(run_x "$dir/dalny-keyboard" --once)
    case "$r" in ok|applied) sx=ok ;; *) sx=fail ;; esac
    if [ "$kb" = changed ]; then
      pkill -u "$uid" -f "$dir/dalny-keyboard --watch" 2>/dev/null
      sleep 0.3
    fi
    pgrep -u "$uid" -f "$dir/dalny-keyboard --watch" >/dev/null 2>&1 || start_bg "$dir/dalny-keyboard" --watch
  fi
fi
echo "DALNY_SETXKBMAP=$sx"
if [ -n "$DISP" ] && command -v xkbcomp >/dev/null 2>&1; then
  echo "DALNY_KEYMAP=$(run_x xkbcomp -xkb "$DISP" - 2>/dev/null | sed -n 's/^ *xkb_symbols *"\([^"]*\)".*/\1/p' | head -n 1)"
fi

# 6. Picture clipboard: xrdp 0.9 offers pictures only as image/bmp, Chromium/Electron apps paste
# only image/png. The helper adds the missing format (both directions).
cb=nogtk
if command -v python3 >/dev/null 2>&1 &&
   python3 -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk, GdkPixbuf' >/dev/null 2>&1; then
  c=$(install_helper dalny-clipboard "$DALNY_CB_B64")
  if [ "$c" = fail ]; then
    cb=fail
  else
    autostart dalny-clipboard "$dir/dalny-clipboard" "Dalny: image/png and image/bmp for pictures in the xrdp clipboard"
    cb=ok
    if [ -z "$DISP" ]; then
      cb=nodisplay
    else
      if [ "$c" = changed ]; then
        pkill -u "$uid" -f "$dir/dalny-clipboard --watch" 2>/dev/null
        sleep 0.3
      fi
      pgrep -u "$uid" -f "$dir/dalny-clipboard --watch" >/dev/null 2>&1 || start_bg "$dir/dalny-clipboard" --watch
    fi
  fi
fi
echo "DALNY_CLIPBOARD=$cb"
