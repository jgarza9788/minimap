# Pane providers

A provider tells the minimap how an app splits its window into panes, so the window's box can be
drawn split the same way. One provider per app, one file each: `providers/<id>.py`.

| Provider | Updates | Matches by |
|---|---|---|
| `herdr.py` | push: herdr socket `events.subscribe`, snapshot on change | `pids` of the herdr client |
| `tmux.py` | push: a read-only control-mode client per viewed session | `pids` of the tmux client |

## Output

The widget runs `python3 -I providers/<id>.py` and reads stdout. Every line is a JSON array with
one entry per window the app is showing panes in:

```json
[{
  "provider": "tmux",
  "match":  { "pids": [3774, 3753, 1436] },
  "area":   { "x": 0, "y": 0, "width": 561, "height": 98 },
  "panes":  [{ "x": 0, "y": 0, "width": 191, "height": 49, "focused": true,
               "id": "w3:p2", "status": "working", "label": "claude" }],
  "zoomed": false,
  "hidden": [{ "id": "w3:p7", "status": "blocked", "label": "codex" }]
}]
```

- `match`, one of:
  - `{"pids": [...]}`: a process running inside the window and its parent chain, nearest first
    (`_common.ancestors(pid)`). Use for anything that runs inside a terminal: multiplexers, editors.
  - `{"pid": n}`: the window's own pid. Use when the app is the window (terminal splits).
  - `{"address": "0x..."}`: a Hyprland window address, if the app knows it.
- `area`: the space the panes tile, `panes`: rectangles inside it. Any unit (cells, pixels):
  only proportions are used. `x`/`y` are relative to the same origin as `area`.
- `focused`: the pane the app has focused. Exactly one, normally.
- `id` (optional): the app's own id for the pane, stable while it lives. Needed for agent alerts:
  the widget alerts when a pane *becomes* blocked, and tells panes apart by id.
- `zoomed`: the focused pane is filling the area; the others are hidden.
- `status` (optional): `idle | working | blocked | done`, for panes running an agent. Leave it out
  rather than guess, and only send it if the provider is told when it changes. `blocked` (the
  agent is waiting for the user) colours the pane amber and raises an alert on the window.
- `label` (optional): what the hover label calls the pane (the pane's name or title, with the
  program or agent in it if that helps). Without one, hovering the pane names the window.
- `hidden` (optional): `[{"id", "status", "label"}]` for agent panes the app has but isn't showing
  in this window (other tabs or workspaces), so a waiting agent there still raises an alert.
  Only panes with a `status`.
- `provider`: the provider id; the widget fills it in if missing.

An empty array means "nothing to show". When several layouts match one window, the one whose
match is nearest the window wins (`pids` index; `pid`/`address` count as 0), so an app running
inside another app's pane doesn't take over the box.

## Input

The widget may write lines to the provider's stdin. Read them with `_common.Commands`:

- `refresh`: the user just hovered a box with panes. Re-read the layout now, even without an
  event, so labels the app sends no event for (terminal titles) are current. Print as usual:
  only if something changed.

Ignore lines you don't know. If stdin closes, keep running.

## Rules

1. **Push if the app can.** Subscribe to the app's events and re-read the layout when one
   arrives; poll only when there is no other way, and say which in the header line
   (`# provider: <id>, push|poll`).
2. **Print only on change**, and never print an empty list just because the first read hasn't
   finished yet. `_common.Emitter` does the first part.
3. **Die with the bar**: call `_common.die_with_parent()` first thing. Write only to stdout.
4. **Read only.** Never change the app's state: no focusing, resizing, zooming, config edits or
   hooks. If watching needs a client or connection (tmux control mode), make it one that cannot
   affect what the user sees.
5. **No polling for labels**: refresh them on `refresh`, not on a timer.
6. **No process per update** when a socket or long-lived pipe can answer instead. Finding the
   app (reading `/proc` every few seconds) is fine; starting the app's CLI on every event is not.
7. **App missing or not running**: print `[]` and wait. Don't exit: the widget restarts exited
   providers with a backoff and logs a warning each time.
8. **Test it**: put a recorded reply from the app in `fixtures/<id>/` and cover the parsing in
   `tests/test_providers.py`. Keep the parsing in plain functions so it can be tested without the app.

## Adding a provider

1. Copy the shape of `tmux.py` (pipe-based) or `herdr.py` (socket-based): imports `_common`,
   one `main()` loop with a selector, a slow `/proc` rescan to notice the app starting and stopping.
2. Add it to `PANE_PROVIDERS` in `Model.js` (`id`, setting `key`, `label`, `description`). The
   settings popup lists it from there.
3. Add the same setting key to `manifest.json` (`defaults` and `schema`).
4. Add fixtures and tests; run `python3 -I tests/test_providers.py` and `node tests/model.test.js`.
