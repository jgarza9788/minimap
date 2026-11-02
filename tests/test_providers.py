#!/usr/bin/env python3
"""Pane provider tests. Run: python3 -I tests/test_providers.py"""
import importlib.util
import io
import json
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "providers")
FIX = os.path.join(ROOT, "fixtures")
sys.path.insert(0, ROOT)
import _common as C  # noqa: E402

failed = 0


def ok(name, cond):
    global failed
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        failed += 1


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def valid(entry):
    """Does one output entry follow providers/README.md?"""
    m = entry.get("match") or {}
    if not (isinstance(m.get("pids"), list) or isinstance(m.get("pid"), int) or isinstance(m.get("address"), str)):
        return False
    a = entry.get("area") or {}
    if not all(isinstance(a.get(k), int) for k in ("x", "y", "width", "height")):
        return False
    for p in entry.get("panes") or []:
        if not all(isinstance(p.get(k), int) for k in ("x", "y", "width", "height")):
            return False
        if not isinstance(p.get("focused"), bool) or p.get("status", "idle") not in C.STATUSES:
            return False
    for h in entry.get("hidden") or []:
        if not isinstance(h.get("id"), str) or h.get("status") not in C.STATUSES:
            return False
    return isinstance(entry.get("zoomed"), bool) and isinstance(entry.get("provider"), str)


# _common
buf = io.StringIO()
em = C.Emitter(buf)
em.emit([C.layout("x", {"pid": 5}, {"x": 0, "y": 0, "width": 2, "height": 1}, [C.pane(0, 0, 2, 1, True)])])
em.emit([C.layout("x", {"pid": 5}, {"x": 0, "y": 0, "width": 2, "height": 1}, [C.pane(0, 0, 2, 1, True)])])
ok("emitter prints only on change", buf.getvalue().count("\n") == 1)
ok("pane drops unknown status", "status" not in C.pane(0, 0, 1, 1, False, status="weird")
   and C.pane(0, 0, 1, 1, False, status="blocked")["status"] == "blocked")
ok("ancestors start at pid", C.ancestors(os.getpid())[0] == os.getpid())

# herdr
H = load("herdr")
procs = {1: ["herdr"], 2: ["herdr", "server"], 3: ["herdr", "--session", "work"], 4: ["herdr", "api", "snapshot"],
         5: ["herdr", "session", "attach", "x"], 6: ["herdr", "--remote", "box"]}
ok("herdr clients and sessions", H.client_sessions(procs) == {1: "default", 3: "work", 5: "x"})
snap = json.load(open(os.path.join(FIX, "herdr", "snapshot.json")))
area, panes, zoomed, hidden = H.layout_of(snap)
ok("herdr layout of focused tab", area["width"] > 0 and len(panes) == len(snap["layouts"][0]["panes"]))
ok("herdr one focused pane", sum(p["focused"] for p in panes) == 1)
ok("herdr entry valid", valid(C.layout("herdr", {"pids": [1, 2]}, area, panes, zoomed)))
labels = {p["label"] for p in panes}
ok("herdr labels: name, agent + title, agent alone", {"server", "claude \u00b7 Fix the parser", "pi - project", "codex",
   "vim notes.md"} <= labels)
ok("herdr status carried, unknown dropped", sorted(p.get("status", "-") for p in panes)
   == ["-", "-", "blocked", "done", "idle", "working"])
ok("herdr pane ids for status subscriptions", H.pane_ids(snap) == frozenset(p["pane_id"] for p in snap["panes"]))
ok("herdr pane ids", all(p.get("id") for p in panes))
area, panes, zoomed, hidden = H.layout_of(dict(snap, panes=snap["panes"] + [
    {"pane_id": "w9:p1", "agent_status": "blocked", "agent": "claude", "terminal_title_stripped": "Other tab"},
    {"pane_id": "w9:p2", "agent_status": "unknown"}]))
ok("herdr hidden tabs report agent status only", hidden == [{"id": "w9:p1", "status": "blocked", "label": "claude \u00b7 Other tab"}])
ok("herdr entry with hidden valid", valid(C.layout("herdr", {"pids": [1]}, area, panes, zoomed, hidden)))
ok("herdr other tab ignored", H.layout_of(dict(snap, focused_tab_id="nope")) is None)

# tmux
T = load("tmux")
sd = T.socket_dir()
ok("tmux default socket", T.server_socket(["tmux", "attach"]) == os.path.join(sd, "default"))
ok("tmux -L socket", T.server_socket(["tmux", "-L", "work", "attach", "-t", "x"]) == os.path.join(sd, "work"))
ok("tmux -S socket", T.server_socket(["tmux", "-S/run/s.sock", "new"]) == "/run/s.sock"
   and T.server_socket(["tmux", "-2", "-S", "/x/y", "a"]) == "/x/y")
ok("tmux socket stops at command", T.server_socket(["tmux", "new", "-L", "nope"]) == os.path.join(sd, "default"))
rows = T.parse_query(open(os.path.join(FIX, "tmux", "query.txt")).read().splitlines())
ok("tmux control clients skipped", [r[0] for r in rows] == [2205892])
pid, session, area, panes, zoomed = rows[0]
ok("tmux panes of the client's window", area == {"x": 0, "y": 0, "width": 80, "height": 23} and len(panes) == 2
   and [p["focused"] for p in panes] == [False, True])
ok("tmux entry valid", valid(C.layout("tmux", {"pids": [pid]}, area, panes, zoomed)))
ok("tmux pane ids", [p["id"] for p in panes] == ["%0", "%1"])
ok("tmux labels: title, else command", [p["label"] for p in panes] == ["bash", "build | watch"])
ok("tmux label ignores host.domain title", T.pane_label("vim", "box", "box.lan") == "vim")
ok("tmux garbage ignored", T.parse_query(["C|x|0", "P|@0|a|b|c|d|1|%0|sh|h|t", "junk"]) == [])

sys.exit(1 if failed else 0)
