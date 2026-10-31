"""Shared helpers for minimap pane providers. See README.md for the output format."""
import ctypes
import json
import os
import selectors
import signal
import sys

STATUSES = ("idle", "working", "blocked", "done")


def die_with_parent():
    """Exit when the bar that started us goes away."""
    try:
        ctypes.CDLL("libc.so.6").prctl(1, signal.SIGTERM)   # PR_SET_PDEATHSIG
    except Exception:
        pass


def ppid_of(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            data = f.read()
        return int(data[data.rindex(")") + 2:].split()[1])
    except Exception:
        return 0


def ancestors(pid):
    """pid and its parent chain, nearest first: the window's pid is somewhere in here."""
    out = []
    seen = set()
    while pid > 1 and pid not in seen and len(out) < 32:
        seen.add(pid)
        out.append(pid)
        pid = ppid_of(pid)
    return out


def processes(comms):
    """{pid: argv} of this user's processes whose comm is one of `comms`."""
    uid = os.getuid()
    out = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        pid = int(name)
        try:
            if os.stat("/proc/%d" % pid).st_uid != uid:
                continue
            with open("/proc/%d/comm" % pid) as f:
                if f.read().strip() not in comms:
                    continue
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                out[pid] = [a.decode(errors="replace") for a in f.read().split(b"\0") if a]
        except OSError:
            continue
    return out


def pane(x, y, width, height, focused, status=None, label=None, id=None):
    p = {"x": int(x), "y": int(y), "width": int(width), "height": int(height), "focused": bool(focused)}
    if id:
        p["id"] = str(id)
    if status in STATUSES:
        p["status"] = status
    if label:
        p["label"] = str(label)[:128]
    return p


def hidden_pane(id, status, label=None):
    """A pane the app has but isn't showing (another tab), reported only for its agent status."""
    if status not in STATUSES:
        return None
    p = {"id": str(id), "status": status}
    if label:
        p["label"] = str(label)[:128]
    return p


def layout(provider, match, area, panes, zoomed=False, hidden=None):
    """One entry of the output array. `match` is {"pids": [...]}, {"pid": n} or {"address": "0x..."}."""
    out = {"provider": provider, "match": match, "area": area, "panes": panes, "zoomed": bool(zoomed)}
    hidden = [h for h in hidden or [] if h]
    if hidden:
        out["hidden"] = hidden
    return out


class Commands:
    """Lines the widget writes to our stdin. So far only "refresh": re-read now, the user is
    looking (hovering a box), so labels the app sends no event for are current."""

    def __init__(self, sel):
        self.sel = sel
        self.buf = b""
        os.set_blocking(sys.stdin.fileno(), False)
        sel.register(sys.stdin, selectors.EVENT_READ, self)

    def readable(self):
        try:
            data = os.read(sys.stdin.fileno(), 4096)
        except BlockingIOError:
            return []
        except OSError:
            data = b""
        if not data:                         # widget closed our stdin: keep running without it
            self.sel.unregister(sys.stdin)
            return []
        self.buf = (self.buf + data)[-4096:]
        *lines, self.buf = self.buf.split(b"\n")
        return [line.strip().decode(errors="replace") for line in lines if line.strip()]


class Emitter:
    """Prints the layout list as one JSON line, only when it changed."""

    def __init__(self, out=None):
        self.out = out or sys.stdout
        self.last = None

    def emit(self, layouts):
        line = json.dumps(sorted(layouts, key=lambda e: json.dumps(e["match"], sort_keys=True)),
                          separators=(",", ":"))
        if line == self.last:
            return True
        self.last = line
        try:
            self.out.write(line + "\n")
            self.out.flush()
        except BrokenPipeError:
            return False
        return True
