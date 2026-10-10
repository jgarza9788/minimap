#!/usr/bin/env bash
# Live notification test against the RUNNING bar (needs hyprctl, notify-send, omarchy-shell, python3).
# Alerts an UNFOCUSED window (a focused one is correctly never alerted), reads the widget's own
# state through `omarchy-shell minimap alerts`, then restores the workspace you started on.
set -u
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
state() { omarchy-shell minimap alerts; }
jq_() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"; }
settle() { sleep 1.5; }

# the shell reloads the widget when plugin files change; wait until its IPC target is back
for _ in $(seq 1 20); do omarchy-shell minimap alerts >/dev/null 2>&1 && break; sleep 0.5; done
omarchy-shell minimap alerts >/dev/null 2>&1 || { echo "FAIL minimap IPC target not available"; exit 1; }

start_ws=$(hyprctl activeworkspace -j | jq_ "d['id']")
active=$(hyprctl activewindow -j | jq_ "d['address']")
trap 'hyprctl dispatch workspace "$start_ws" >/dev/null; omarchy-shell minimap clear' EXIT

# classes of windows that are not the focused one (nor a tab of its group: those are never alerted),
# split by workspace
mapfile -t here  < <(hyprctl clients -j | jq_ "'\n'.join(sorted({c['class'] for c in d if c['workspace']['id']==$start_ws and c['address']!='$active' and '$active' not in c['grouped'] and c['class']}))")
mapfile -t there < <(hyprctl clients -j | jq_ "'\n'.join(sorted({c['class'] for c in d if c['workspace']['id']!=$start_ws and c['workspace']['id']>0 and c['class']}))")

omarchy-shell minimap clear; settle
[ "$(state | jq_ "len(d['alerts'])")" = 0 ] && ok "clear empties alerts" || bad "clear empties alerts"

# 1. unfocused window on this workspace: normal then critical (critical must win)
if [ -n "${here[0]:-}" ]; then
  notify-send -a "${here[0]}" -u normal "live test" "normal"; settle
  [ "$(state | jq_ "max(d['alerts'].values() or [0])")" = 1 ] && ok "normal -> level 1 (${here[0]})" || { bad "normal -> level 1 (${here[0]})"; state; hyprctl activewindow -j | jq_ "d['address']"; }
  [ "$(state | jq_ "len(d['attention'])")" -ge 1 ] && ok "box cue set" || bad "box cue set"
  notify-send -a "${here[0]}" -u critical "live test" "critical"; settle
  [ "$(state | jq_ "max(d['alerts'].values() or [0])")" = 2 ] && ok "critical -> level 2" || bad "critical -> level 2"
else
  echo "SKIP no unfocused window on workspace $start_ws"
fi
omarchy-shell minimap clear; settle

# 2. window on another workspace: the number lights, jump goes there, focusing clears it
if [ -n "${there[0]:-}" ]; then
  notify-send -a "${there[0]}" -u critical "live test" "other workspace"; settle
  [ "$(state | jq_ "d['otherLevel']")" = 2 ] && ok "number lit for other-workspace alert (${there[0]})" || bad "number lit for other-workspace alert (${there[0]})"
  target=$(state | jq_ "d['target']")
  omarchy-shell minimap jump; settle
  now=$(hyprctl activewindow -j | jq_ "d['address']")
  [ -n "$target" ] && [ "$now" = "$target" ] && ok "jump focused the alert target" || bad "jump focused the alert target ($now != $target)"
  [ "$(state | jq_ "len(d['alerts'])")" = 0 ] && ok "focusing the window cleared the alert" || bad "focusing the window cleared the alert"
else
  echo "SKIP no windows on other workspaces"
fi

echo; [ "$fail" = 0 ] && echo "all passed" || echo "FAILED"
exit "$fail"
