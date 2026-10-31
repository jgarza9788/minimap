#!/usr/bin/env python3
"""herdr pane provider for the jgarza.minimap widget.  # provider: herdr, push

Finds every running herdr client (the TUI attached inside a terminal window)
and reports the pane rectangles of the tab its server is showing.

Push, not poll: each herdr server is subscribed to over its socket and a
snapshot is only taken when it reports a layout, focus or pane change. The
process list is rescanned every few seconds to notice clients attaching and
detaching; that is a read of /proc, no herdr calls.

Usage: herdr.py [--rescan SECONDS]
"""
import argparse
import json
import os
import selectors
import shutil
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402

EVENTS = [
    "layout.updated", "pane.focused", "pane.created", "pane.closed", "pane.moved", "pane.exited",
    "tab.focused", "tab.created", "tab.closed", "tab.moved",
    "workspace.focused", "workspace.created", "workspace.closed",
]
DEBOUNCE = 0.03          # seconds: one snapshot for a burst of events
RETRY = 2.0              # seconds before reconnecting a dropped subscription
MAX_LINE = 4 * 1024 * 1024


def client_sessions(procs):
    """{pid: session name} of the herdr TUI clients among `procs` ({pid: argv})."""
    out = {}
    for pid, argv in procs.items():
        rest = argv[1:]
        session = "default"
        if len(rest) >= 2 and rest[0] == "--session":
            session, rest = rest[1], rest[2:]
        elif len(rest) >= 3 and rest[:2] == ["session", "attach"]:
            session, rest = rest[2], rest[3:]
        # The TUI takes no subcommand; anything else (server, api, pane ...) is not a client.
        if rest and not rest[0].startswith("-"):
            continue
        if "--remote" in rest:
            continue
        out[pid] = session
    return out


def session_sockets(herdr):
    try:
        res = subprocess.run([herdr, "session", "list", "--json"], capture_output=True, timeout=3, text=True)
        return {s["name"]: s["socket_path"] for s in json.loads(res.stdout)["sessions"]
                if s.get("running") and s.get("socket_path")}
    except Exception:
        return {}


def request(path, method, params=None):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(2)
        s.connect(path)
        s.sendall((json.dumps({"id": "minimap", "method": method, "params": params or {}}) + "\n").encode())
        return json.loads(s.makefile("rb").readline(MAX_LINE))["result"]


def rect(r):
    return {k: int(r.get(k, 0)) for k in ("x", "y", "width", "height")}


def pane_label(info):
    """What to call a pane: its herdr name if renamed, else its title, with the agent in front."""
    name = info.get("label") or info.get("terminal_title_stripped") or info.get("title") or ""
    agent = info.get("display_agent") or info.get("agent") or ""
    if agent and agent.lower() not in name.lower():
        name = "%s \u00b7 %s" % (agent, name) if name else agent
    return name


def layout_of(snap):
    """(area, panes, zoomed, hidden) of the tab a herdr snapshot has focused, or None. `hidden`
    is the agent status of every pane in the session's other tabs and workspaces."""
    tab = snap.get("focused_tab_id")
    infos = {p.get("pane_id"): p for p in snap.get("panes") or []}
    for lay in snap.get("layouts") or []:
        if lay.get("tab_id") != tab:
            continue
        focused = lay.get("focused_pane_id")
        panes = []
        for p in lay.get("panes") or []:
            r = rect(p.get("rect") or {})
            info = infos.get(p.get("pane_id")) or {}
            panes.append(C.pane(r["x"], r["y"], r["width"], r["height"], p.get("pane_id") == focused,
                                status=info.get("agent_status"), label=pane_label(info), id=p.get("pane_id")))
        shown = {p.get("pane_id") for p in lay.get("panes") or []}
        hidden = [C.hidden_pane(pid, info.get("agent_status"), pane_label(info))
                  for pid, info in sorted(infos.items(), key=lambda kv: str(kv[0])) if pid not in shown]
        return rect(lay.get("area") or {}), panes, lay.get("zoomed") is True, [h for h in hidden if h]
    return None


def pane_ids(snap):
    return frozenset(p["pane_id"] for p in snap.get("panes") or [] if p.get("pane_id"))


class Session:
    """One herdr server: an event subscription plus its latest layout.

    Agent status changes are only sent per pane, so the subscription names every pane the
    last snapshot had, and is renewed when that set changes."""

    def __init__(self, path):
        self.path = path
        self.panes = frozenset()
        self.sock = None
        self.buf = b""
        self.layout = None
        self.dirty = True
        self.retry_at = 0.0

    def connect(self, sel):
        try:
            s = socket.socket(socket.AF_UNIX)
            s.settimeout(2)
            s.connect(self.path)
            subs = [{"type": t} for t in EVENTS]
            subs += [{"type": "pane.agent_status_changed", "pane_id": p} for p in sorted(self.panes)]
            s.sendall((json.dumps({"id": "minimap-events", "method": "events.subscribe",
                                   "params": {"subscriptions": subs}}) + "\n").encode())
            s.setblocking(False)
        except OSError:
            self.retry_at = time.monotonic() + RETRY
            return
        self.sock = s
        self.buf = b""
        self.dirty = True
        sel.register(s, selectors.EVENT_READ, self)

    def close(self, sel):
        if self.sock:
            try:
                sel.unregister(self.sock)
            except Exception:
                pass
            self.sock.close()
        self.sock = None
        self.layout = None
        self.retry_at = time.monotonic() + RETRY

    def readable(self, sel):
        try:
            data = self.sock.recv(65536)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if not data:
            self.close(sel)
            return
        # Any event line means something may have moved; the content itself isn't needed.
        self.buf = (self.buf + data)[-MAX_LINE:]
        if b"\n" in self.buf:
            self.buf = self.buf[self.buf.rindex(b"\n") + 1:]
            self.dirty = True

    def refresh(self, sel):
        self.dirty = False
        try:
            snap = request(self.path, "session.snapshot")["snapshot"]
        except Exception:
            self.layout = None
            return
        self.layout = layout_of(snap)
        ids = pane_ids(snap)
        if ids != self.panes:
            self.panes = ids
            self.resubscribe(sel)

    def resubscribe(self, sel):
        """Swap the subscription for one covering the current panes, keeping the layout."""
        layout = self.layout
        self.close(sel)
        self.retry_at = 0.0
        self.connect(sel)
        self.layout = layout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rescan", type=float, default=3.0)
    args = ap.parse_args()
    C.die_with_parent()
    out = C.Emitter()
    herdr = shutil.which("herdr")
    if not herdr:
        out.emit([])
        while True:                          # not installed: stay quiet instead of being restarted
            time.sleep(3600)

    sel = selectors.DefaultSelector()
    commands = C.Commands(sel)
    sessions = {}          # socket path -> Session
    sockets = {}           # session name -> socket path
    clients = {}           # pid -> session name
    rescan_at = 0.0
    dirty_since = None

    while True:
        now = time.monotonic()
        if now >= rescan_at:
            rescan_at = now + max(0.5, args.rescan)
            clients = client_sessions(C.processes({"herdr"}))
            if any(name not in sockets for name in clients.values()):
                sockets = session_sockets(herdr)
            wanted = {sockets[n] for n in clients.values() if n in sockets}
            for path in list(sessions):
                if path not in wanted:
                    sessions.pop(path).close(sel)
            for path in wanted:
                sessions.setdefault(path, Session(path))

        for sess in sessions.values():
            if sess.sock is None and now >= sess.retry_at:
                sess.connect(sel)
        if any(s.dirty for s in sessions.values()):
            if dirty_since is None:
                dirty_since = now
            if now - dirty_since >= DEBOUNCE:
                dirty_since = None
                for sess in sessions.values():
                    if sess.dirty and sess.sock is not None:
                        sess.refresh(sel)

        # Hold output while a snapshot is due, so startup never flashes an empty list.
        if not any(s.dirty and s.sock is not None for s in sessions.values()):
            layouts = []
            for pid, name in clients.items():
                sess = sessions.get(sockets.get(name))
                if sess and sess.layout and sess.layout[1]:
                    area, panes, zoomed, hidden = sess.layout
                    layouts.append(C.layout("herdr", {"pids": C.ancestors(pid)}, area, panes, zoomed, hidden))
            if not out.emit(layouts):
                return

        timeout = rescan_at - time.monotonic()
        if dirty_since is not None:
            timeout = min(timeout, DEBOUNCE)
        for sess in sessions.values():
            if sess.sock is None:
                timeout = min(timeout, sess.retry_at - time.monotonic())
        for key, _ in sel.select(max(0.0, timeout)):
            if key.data is commands:
                if "refresh" in commands.readable():
                    for sess in sessions.values():
                        sess.dirty = True
            else:
                key.data.readable(sel)


if __name__ == "__main__":
    main()
