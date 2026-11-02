#!/usr/bin/env python3
"""tmux pane provider for the jgarza.minimap widget.  # provider: tmux, push

Reports the panes of the window each tmux client (`tmux attach` running in a
terminal window) is showing.

Push, not poll: for every session a terminal is attached to, a read-only
control-mode client (`tmux -C attach -r -f no-output,ignore-size,read-only`)
is kept open. tmux sends it %layout-change, %window-pane-changed and friends
as they happen, and the layout is re-read through the same pipe, so steady
state starts no processes. Control clients only hear layout changes for their
own session, hence one per viewed session. `ignore-size` keeps them from
affecting window sizes; they do show up in `tmux list-clients`.

The process list is read every few seconds to notice tmux clients appearing;
with none running, no tmux server is touched at all.

Usage: tmux.py [--rescan SECONDS]
"""
import argparse
import os
import selectors
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _common as C  # noqa: E402

DEBOUNCE = 0.03
CLIENT_FMT = "C|#{client_pid}|#{client_control_mode}|#{session_id}|#{window_id}|#{window_zoomed_flag}|#{window_width}|#{window_height}"
# The pane title goes last: it is free text and may contain "|".
PANE_FMT = "P|#{window_id}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{pane_active}|#{pane_id}|#{pane_current_command}|#{host_short}|#{pane_title}"
QUERY = ["list-clients -F '%s'" % CLIENT_FMT, "list-panes -a -F '%s'" % PANE_FMT]
# Notifications that mean the client list itself changed, not just a layout.
RESCAN_ON = (b"%client-session-changed", b"%sessions-changed", b"%session-changed", b"%client-detached")


def socket_dir():
    return os.path.join(os.environ.get("TMUX_TMPDIR") or "/tmp", "tmux-%d" % os.getuid())


def server_socket(argv):
    """The socket a tmux command line talks to (-S path, -L name, else default)."""
    path, name = None, "default"
    i = 1
    while i < len(argv):
        a = argv[i]
        if a in ("-S", "-L") and i + 1 < len(argv):
            if a == "-S":
                path = argv[i + 1]
            else:
                name = argv[i + 1]
            i += 2
            continue
        if a.startswith("-S") and len(a) > 2:
            path = a[2:]
        elif a.startswith("-L") and len(a) > 2:
            name = a[2:]
        elif not a.startswith("-"):
            break
        i += 1
    return path or os.path.join(socket_dir(), name)


def pane_label(command, host, title):
    """A pane's title, unless it is still tmux's default (the host name): then what it runs."""
    title = title.strip()
    if title and title != host and not title.startswith(host + "."):
        return title
    return command


def parse_query(lines):
    """Output of QUERY -> [(client_pid, session_id, area, panes, zoomed)] for the terminal clients."""
    clients, panes = [], {}
    for line in lines:
        f = line.split("|", 10)
        try:
            if f[0] == "C" and len(f) == 8 and f[2] != "1":
                clients.append((int(f[1]), f[3], f[4], f[5] == "1", int(f[6]), int(f[7])))
            elif f[0] == "P" and len(f) == 11:
                panes.setdefault(f[1], []).append(C.pane(f[2], f[3], f[4], f[5], f[6] == "1",
                                                         label=pane_label(f[8], f[9], f[10]), id=f[7]))
        except ValueError:
            continue
    out = []
    for pid, session, window, zoomed, w, h in clients:
        out.append((pid, session, {"x": 0, "y": 0, "width": w, "height": h}, panes.get(window, []), zoomed))
    return out


class Control:
    """A read-only control-mode client attached to one session."""

    def __init__(self, tmux, sock, session, sel, server):
        self.server = server
        self.proc = subprocess.Popen(
            [tmux, "-S", sock, "-C", "attach", "-r", "-t", session, "-f", "no-output,ignore-size,read-only"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.buf = b""
        self.block = None          # lines of the command reply being read
        self.ours = False
        self.blocks_left = 0
        self.reply = []
        self.sel = sel
        sel.register(self.proc.stdout, selectors.EVENT_READ, self)

    def ask(self, commands):
        if self.blocks_left:
            return False
        try:
            self.proc.stdin.write(("\n".join(commands) + "\n").encode())
            self.proc.stdin.flush()
        except OSError:
            return False
        self.blocks_left = len(commands)
        self.reply = []
        return True

    def readable(self):
        try:
            data = os.read(self.proc.stdout.fileno(), 65536)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if not data:
            self.close()
            self.server.dirty = self.server.rescan = True
            return
        self.buf += data
        *lines, self.buf = self.buf.split(b"\n")
        for line in lines:
            self.line(line)

    def line(self, line):
        if self.block is not None:
            if line.startswith((b"%end ", b"%error ")):
                if self.ours:
                    self.reply.extend(self.block)
                    self.blocks_left -= 1
                    if self.blocks_left == 0:
                        self.server.answer(self.reply)
                self.block = None
            else:
                self.block.append(line.decode(errors="replace"))
            return
        if line.startswith(b"%begin "):
            # flags 1 = a reply to our own command; 0 = the attach itself
            self.block = []
            self.ours = line.rstrip().endswith(b" 1")
            return
        if line.startswith(b"%exit"):
            self.close()
            self.server.dirty = self.server.rescan = True
            return
        if line.startswith(b"%"):
            self.server.dirty = True
            if line.startswith(RESCAN_ON):
                self.server.rescan = True

    def close(self):
        if self.proc is None:
            return
        if self.blocks_left:                 # a query died with us: let the server ask again
            self.blocks_left = 0
            self.server.asked = False
            self.server.dirty = True
        try:
            self.sel.unregister(self.proc.stdout)
        except Exception:
            pass
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        self.proc.terminate()
        try:
            self.proc.wait(timeout=1)
        except Exception:
            self.proc.kill()
        self.proc = None

    @property
    def alive(self):
        return self.proc is not None and self.proc.poll() is None


class Server:
    """One tmux server: a control client per viewed session and the latest layouts."""

    def __init__(self, tmux, sock, sel):
        self.tmux, self.sock, self.sel = tmux, sock, sel
        self.controls = {}         # session id -> Control
        self.layouts = []          # parse_query() result
        self.dirty = True
        self.rescan = True
        self.asked = False

    def query(self):
        self.dirty = False
        for c in self.controls.values():
            if c.alive and c.ask(QUERY):
                self.asked = True
                return
        # No control client yet (first sight of this server): ask once the plain way.
        lines = []
        for fmt, cmd in ((CLIENT_FMT, ["list-clients"]), (PANE_FMT, ["list-panes", "-a"])):
            try:
                r = subprocess.run([self.tmux, "-S", self.sock] + cmd + ["-F", fmt],
                                   capture_output=True, timeout=2, text=True)
                lines += r.stdout.splitlines()
            except Exception:
                pass
        self.answer(lines)

    def answer(self, lines):
        self.asked = False
        self.layouts = parse_query(lines)
        wanted = {session for _, session, _, _, _ in self.layouts}
        for session in list(self.controls):
            if session not in wanted or not self.controls[session].alive:
                self.controls.pop(session).close()
        for session in wanted:
            if session not in self.controls:
                self.controls[session] = Control(self.tmux, self.sock, session, self.sel, self)

    def close(self):
        for c in self.controls.values():
            c.close()
        self.controls = {}
        self.layouts = []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rescan", type=float, default=3.0)
    args = ap.parse_args()
    C.die_with_parent()
    out = C.Emitter()
    tmux = shutil.which("tmux")
    if not tmux:
        out.emit([])
        while True:
            time.sleep(3600)

    sel = selectors.DefaultSelector()
    commands = C.Commands(sel)
    servers = {}               # socket path -> Server
    rescan_at = 0.0
    dirty_since = None
    me = os.getpid()

    while True:
        now = time.monotonic()
        if now >= rescan_at or any(s.rescan for s in servers.values()):
            rescan_at = now + max(0.5, args.rescan)
            clients = {pid: argv for pid, argv in C.processes({"tmux: client"}).items()
                       if C.ppid_of(pid) != me}
            wanted = {server_socket(argv) for argv in clients.values()}
            for path in list(servers):
                if path not in wanted:
                    servers.pop(path).close()
            for path in wanted:
                if path not in servers and os.path.exists(path):
                    servers[path] = Server(tmux, path, sel)
            for s in servers.values():
                if s.rescan:
                    s.rescan = False
                    s.dirty = True

        if any(s.dirty for s in servers.values()):
            if dirty_since is None:
                dirty_since = now
            if now - dirty_since >= DEBOUNCE:
                dirty_since = None
                for s in servers.values():
                    if s.dirty and not s.asked:
                        s.query()

        if not any(s.dirty or s.asked for s in servers.values()):
            layouts = []
            for s in servers.values():
                for pid, _, area, panes, zoomed in s.layouts:
                    if panes:
                        layouts.append(C.layout("tmux", {"pids": C.ancestors(pid)}, area, panes, zoomed))
            if not out.emit(layouts):
                break

        timeout = rescan_at - time.monotonic()
        if dirty_since is not None:
            timeout = min(timeout, DEBOUNCE)
        for key, _ in sel.select(max(0.0, timeout)):
            if key.data is commands:
                if "refresh" in commands.readable():
                    for s in servers.values():
                        s.dirty = True
            else:
                key.data.readable()

    for s in servers.values():
        s.close()


if __name__ == "__main__":
    main()
