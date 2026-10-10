"""Tests for bin/notify-watch: the pure parsers, and live runs of both sources.

Run: python3 -I tests/test_notify_watch.py
The live tests need a session bus + notify-send (dbus source) and inotifywait
(files source); each is skipped when its tool is missing.
"""
import importlib.machinery
import importlib.util
import json
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "bin", "notify-watch")

loader = importlib.machinery.SourceFileLoader("notify_watch", SCRIPT)
spec = importlib.util.spec_from_loader("notify_watch", loader)
nw = importlib.util.module_from_spec(spec)
loader.exec_module(nw)


def notify_msg(app="chromium", icon="", summary="S", body="B", hints=None, cookie=7, sender=":1.9"):
    return {
        "type": "method_call", "member": "Notify", "cookie": cookie, "sender": sender,
        "timestamp-realtime": 1791590587357067,
        "payload": {"type": "susssasa{sv}i", "data": [app, 0, icon, summary, body, [], hints or {}, -1]},
    }


def hint_y(v): return {"type": "y", "data": v}
def hint_s(v): return {"type": "s", "data": v}
def hint_x(v): return {"type": "x", "data": v}


# ---- pure parsing -----------------------------------------------------------

class HintTests(unittest.TestCase):
    def test_unwraps_busctl_variant(self):
        self.assertEqual(nw.hint({"urgency": hint_y(2)}, "urgency"), 2)

    def test_first_present_name_wins(self):
        self.assertEqual(nw.hint({"image_path": hint_s("b")}, "image-path", "image_path"), "b")

    def test_missing_is_none(self):
        self.assertIsNone(nw.hint({}, "urgency"))

    def test_plain_value_passes_through(self):
        self.assertEqual(nw.hint({"urgency": 2}, "urgency"), 2)


class AncestorTests(unittest.TestCase):
    TREE = {
        500: "500 (ghostty) S 1 500 500 0",
        600: "600 (bash) S 500 600 600 0",
        700: "700 (claude (node)) S 600 700 700 0",   # comm contains spaces and parens
        800: "800 (notify-send) S 700 800 800 0",
    }

    def stat(self, pid):
        if pid not in self.TREE:
            raise OSError("gone")
        return self.TREE[pid]

    def test_parent_of_odd_comm(self):
        self.assertEqual(nw.parent_pid(700, self.stat), 600)

    def test_chain_nearest_first_stops_at_init(self):
        self.assertEqual(nw.ancestors(800, self.stat), [700, 600, 500])

    def test_unknown_pid(self):
        self.assertEqual(nw.parent_pid(999, self.stat), 0)
        self.assertEqual(nw.ancestors(999, self.stat), [])
        self.assertEqual(nw.ancestors(0, self.stat), [])

    def test_cycle_does_not_loop(self):
        loop = {10: "10 (a) S 20 0 0 0", 20: "20 (b) S 10 0 0 0"}
        self.assertEqual(nw.ancestors(10, lambda p: loop[p]), [20, 10])

    def test_limit(self):
        deep = {p: "%d (x) S %d 0 0 0" % (p, p + 1) for p in range(2, 40)}
        self.assertEqual(len(nw.ancestors(2, lambda p: deep[p], limit=5)), 5)


class LookupPidTests(unittest.TestCase):
    def setUp(self):
        nw._pid_cache.clear()

    def test_rejects_anything_that_is_not_a_unique_name(self):
        called = []
        for bad in ("--help", "org.freedesktop.DBus", ":1", ":1.x", ":1.2 ; rm", "", None, ":1.5\n"):
            self.assertEqual(nw.lookup_pid(bad, runner=lambda cmd: called.append(cmd) or "u 1"), 0)
        self.assertEqual(called, [], "an invalid sender must never reach busctl")

    def test_result_is_cached_per_sender(self):
        calls = []
        runner = lambda cmd: calls.append(cmd) or "u 99\n"
        self.assertEqual((nw.lookup_pid(":1.5", runner), nw.lookup_pid(":1.5", runner)), (99, 99))
        self.assertEqual(len(calls), 1)

    def test_failures_are_not_cached(self):
        self.assertEqual(nw.lookup_pid(":1.6", runner=lambda cmd: "oops"), 0)
        self.assertEqual(nw.lookup_pid(":1.6", runner=lambda cmd: "u 5"), 5)

    def test_cache_is_bounded(self):
        for i in range(nw.PID_CACHE_MAX + 20):
            nw.lookup_pid(":1.%d" % i, runner=lambda cmd: "u 1")
        self.assertLessEqual(len(nw._pid_cache), nw.PID_CACHE_MAX)

    def test_parses_busctl_reply(self):
        self.assertEqual(nw.lookup_pid(":1.5", runner=lambda cmd: "u 1234\n"), 1234)

    def test_garbage_and_empty(self):
        self.assertEqual(nw.lookup_pid(":1.5", runner=lambda cmd: "oops"), 0)
        self.assertEqual(nw.lookup_pid("", runner=lambda cmd: "u 1"), 0)

    def test_runner_failure(self):
        def boom(cmd): raise OSError("no busctl")
        self.assertEqual(nw.lookup_pid(":1.5", runner=boom), 0)


class DbusRecordTests(unittest.TestCase):
    def rec(self, **kw):
        return nw.record_from_dbus(notify_msg(**kw), pid_lookup=lambda s: 0, read_stat=lambda p: "%d (x) S 1 0 0 0" % p)

    def test_basic_fields(self):
        r = self.rec(app="chromium", icon="web", summary="Hi", body="There")
        self.assertEqual((r["app"], r["appIcon"], r["source"]), ("chromium", "web", "dbus"))
        self.assertEqual(r["id"], 7)
        self.assertEqual(r["timestamp"], 1791590587357)

    def test_urgency_levels_and_default(self):
        self.assertEqual(self.rec(hints={"urgency": hint_y(0)})["urgency"], 0)
        self.assertEqual(self.rec(hints={"urgency": hint_y(2)})["urgency"], 2)
        self.assertEqual(self.rec()["urgency"], 1)

    def test_urgency_is_clamped(self):
        self.assertEqual(self.rec(hints={"urgency": hint_y(9)})["urgency"], 2)

    def test_extra_names(self):
        r = self.rec(hints={"desktop-entry": hint_s("org.gnome.Nautilus"), "image-path": hint_s("folder")})
        self.assertEqual(r["extraNames"], ["org.gnome.Nautilus", "folder"])

    def test_bus_pid_beats_a_spoofed_hint(self):
        r = nw.record_from_dbus(notify_msg(hints={"sender-pid": hint_x(1)}), pid_lookup=lambda s: 4242, read_stat=lambda p: "%d (x) S 1 0 0 0" % p)
        self.assertEqual(r["pid"], 4242)

    def test_hint_is_only_a_fallback(self):
        r = nw.record_from_dbus(notify_msg(hints={"sender-pid": hint_x(777)}), pid_lookup=lambda s: 0, read_stat=lambda p: "%d (x) S 1 0 0 0" % p, pid_ok=lambda p: True)
        self.assertEqual(r["pid"], 777)

    def test_implausible_hint_is_dropped(self):
        for pid in (1, 0, -4, 4000000):
            r = nw.record_from_dbus(notify_msg(hints={"sender-pid": hint_x(pid)}), pid_lookup=lambda s: 0, read_stat=lambda p: "")
            self.assertEqual(r["pid"], 0, "pid %d should be rejected" % pid)

    def test_plausible_pid(self):
        self.assertTrue(nw.plausible_pid(os.getpid()))
        self.assertFalse(nw.plausible_pid(1))
        self.assertFalse(nw.plausible_pid(0))
        self.assertFalse(nw.plausible_pid(-1))
        self.assertFalse(nw.plausible_pid(4194000))

    def test_negative_or_junk_hint_is_zero(self):
        for bad in (hint_x(-5), hint_s("abc")):
            r = nw.record_from_dbus(notify_msg(hints={"sender-pid": bad}), pid_lookup=lambda s: 0, read_stat=lambda p: "")
            self.assertEqual(r["pid"], 0)

    def test_summary_and_body_are_not_forwarded(self):
        r = self.rec(summary="secret subject", body="secret body")
        self.assertNotIn("summary", r)
        self.assertNotIn("body", r)
        self.assertNotIn("secret", json.dumps(r))

    def test_long_strings_are_clipped(self):
        r = self.rec(app="a" * 5000, icon="i" * 5000, hints={"desktop-entry": hint_s("d" * 5000)})
        self.assertEqual((len(r["app"]), len(r["appIcon"]), len(r["extraNames"][0])), (256, 256, 256))

    def test_pid_falls_back_to_bus_lookup(self):
        r = nw.record_from_dbus(notify_msg(sender=":1.77"), pid_lookup=lambda s: 555 if s == ":1.77" else 0, read_stat=lambda p: "%d (x) S 1 0 0 0" % p)
        self.assertEqual(r["pid"], 555)

    def test_ancestors_attached(self):
        r = nw.record_from_dbus(notify_msg(hints={"sender-pid": hint_x(30)}), pid_lookup=lambda s: 0, pid_ok=lambda p: True,
                                read_stat=lambda p: {30: "30 (a) S 20 0 0 0", 20: "20 (b) S 10 0 0 0", 10: "10 (c) S 1 0 0 0"}[p])
        self.assertEqual(r["ancestors"], [20, 10])

    def test_missing_fields_are_empty_strings(self):
        r = self.rec(app=None, icon=None)
        self.assertEqual((r["app"], r["appIcon"]), ("", ""))

    def test_rejects_other_messages(self):
        self.assertIsNone(nw.record_from_dbus({"member": "GetCapabilities"}))
        self.assertIsNone(nw.record_from_dbus({"member": "Notify", "payload": {"data": ["short"]}}))
        self.assertIsNone(nw.record_from_dbus({"member": "Notify", "payload": {"data": [1, 2, 3, 4, 5, 6, "not-a-dict", 8]}}))
        self.assertIsNone(nw.record_from_dbus("junk"))
        self.assertIsNone(nw.record_from_dbus(None))


class LimiterTests(unittest.TestCase):
    def test_burst_then_drops_then_refills(self):
        now = [0.0]
        lim = nw.Limiter(rate=10, burst=5, clock=lambda: now[0])
        self.assertEqual([lim.allow() for _ in range(8)], [True] * 5 + [False] * 3)
        now[0] += 0.3  # 3 tokens back
        self.assertEqual([lim.allow() for _ in range(4)], [True, True, True, False])

    def test_never_exceeds_burst(self):
        now = [0.0]
        lim = nw.Limiter(rate=100, burst=3, clock=lambda: now[0])
        now[0] += 60
        self.assertEqual(sum(lim.allow() for _ in range(10)), 3)


class SafeReadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="nwtest-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def path(self, name): return os.path.join(self.tmp, name)

    def test_regular_file(self):
        with open(self.path("a.json"), "w") as f: f.write('{"id":1}')
        self.assertEqual(nw.read_file_safe(self.path("a.json")), '{"id":1}')

    def test_missing_file(self):
        self.assertIsNone(nw.read_file_safe(self.path("nope.json")))

    def test_symlink_is_refused(self):
        with open(self.path("real.json"), "w") as f: f.write("{}")
        os.symlink(self.path("real.json"), self.path("link.json"))
        self.assertIsNone(nw.read_file_safe(self.path("link.json")))

    def test_fifo_is_refused_without_blocking(self):
        os.mkfifo(self.path("pipe.json"))
        start = time.time()
        self.assertIsNone(nw.read_file_safe(self.path("pipe.json")))
        self.assertLess(time.time() - start, 1.0)

    def test_directory_is_refused(self):
        os.mkdir(self.path("dir.json"))
        self.assertIsNone(nw.read_file_safe(self.path("dir.json")))

    def test_big_file_is_read_only_up_to_the_cap(self):
        with open(self.path("big.json"), "w") as f: f.write("x" * (nw.MAX_FILE * 3))
        self.assertEqual(len(nw.read_file_safe(self.path("big.json"))), nw.MAX_FILE)

    def test_invalid_utf8_does_not_crash(self):
        with open(self.path("bin.json"), "wb") as f: f.write(b'{"id":1,"app":"\xff\xfe"}')
        self.assertIsInstance(nw.read_file_safe(self.path("bin.json")), str)


class FileRecordTests(unittest.TestCase):
    LINE = '{"id":9,"app":"","appIcon":"com.mitchellh.ghostty","summary":"Claude Code","body":"b","urgency":2,"timestamp":1791588854872}'

    def test_no_summary_or_body(self):
        r = nw.record_from_file("/x/1-9.json", self.LINE)
        self.assertNotIn("summary", r)
        self.assertNotIn("body", r)

    def test_odd_types_fall_back_to_safe_values(self):
        r = nw.record_from_file("/x/7-7.json", '{"id":{"a":1},"urgency":"loud","timestamp":"soon","app":["x"]}')
        self.assertEqual((r["id"], r["urgency"]), ("7-7.json", 1))
        self.assertIsInstance(r["timestamp"], int)

    def test_urgency_clamped(self):
        self.assertEqual(nw.record_from_file("/x/a.json", '{"urgency":9}')["urgency"], 2)
        self.assertEqual(nw.record_from_file("/x/a.json", '{"urgency":-3}')["urgency"], 0)

    def test_omarchy_file(self):
        r = nw.record_from_file("/x/1-9.json", self.LINE)
        self.assertEqual((r["id"], r["appIcon"], r["urgency"], r["timestamp"], r["source"]), (9, "com.mitchellh.ghostty", 2, 1791588854872, "files"))
        self.assertEqual((r["pid"], r["ancestors"], r["extraNames"]), (0, [], []))

    def test_bad_files(self):
        self.assertIsNone(nw.record_from_file("/x/a.json", "not json"))
        self.assertIsNone(nw.record_from_file("/x/a.json", "[1,2]"))
        self.assertIsNone(nw.record_from_file("/x/a.json", ""))


# ---- live: run the real script ------------------------------------------------

def tearDownModule():
    """No test may leave a watcher behind."""
    time.sleep(0.3)
    leftovers = []
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            try:
                with open("/proc/%s/cmdline" % entry, "rb") as f:
                    cmd = f.read().replace(b"\0", b" ").decode("utf-8", "replace")
            except OSError:
                continue
            argv0 = cmd.split(" ", 1)[0].rsplit("/", 1)[-1]
            if argv0 == "inotifywait" and "/tmp/nwtest-" in cmd:
                leftovers.append((entry, cmd))
    if leftovers:
        raise AssertionError("leftover test processes: %r" % leftovers)


class Stream:
    """notify-watch as a subprocess; a reader thread feeds a queue so lines that
    arrive together are never lost to buffering."""
    def __init__(self, *args, env=None):
        self.proc = subprocess.Popen([sys.executable, "-I", SCRIPT, *args], stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, env=env)
        self.lines = queue.Queue()
        self.thread = threading.Thread(target=self._pump, daemon=True)
        self.thread.start()

    def _pump(self):
        for line in self.proc.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def next(self, timeout=6.0, match=None):
        end = time.time() + timeout
        while time.time() < end:
            try:
                line = self.lines.get(timeout=0.2)
            except queue.Empty:
                continue
            if line is None:
                return None
            rec = json.loads(line)
            if match is None or match(rec):
                return rec
        return None

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(3)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.thread.join(2)
        self.proc.stdout.close()
        self.proc.stderr.close()


@unittest.skipUnless(shutil.which("busctl") and shutil.which("notify-send") and os.environ.get("DBUS_SESSION_BUS_ADDRESS", "x"),
                     "needs busctl + notify-send + a session bus")
class LiveDbusTests(unittest.TestCase):
    def setUp(self):
        self.stream = Stream("--source", "dbus")
        time.sleep(1.0)  # let busctl attach before sending

    def tearDown(self):
        self.stream.close()

    def send(self, *args):
        subprocess.run(["notify-send", *args], check=True, timeout=5)

    def test_critical_notification_reaches_us_with_pid(self):
        tag = "nwtest-crit-%d" % os.getpid()
        rec = None
        # notify-send exits within milliseconds; once in a while it is gone before the watcher can
        # vouch for it (pid stays 0 - by design). Everything else must hold on every attempt, and
        # a pid must show up within a few attempts.
        for attempt in range(6):
            self.send("-a", tag, "-u", "critical", "Deploy failed", "see logs")
            rec = self.stream.next(match=lambda r: r["app"] == tag)
            self.assertIsNotNone(rec, "no notification arrived over D-Bus")
            self.assertEqual((rec["urgency"], rec["source"]), (2, "dbus"))
            self.assertNotIn("summary", rec)
            self.assertNotIn("body", rec)
            if rec["pid"] > 0:
                break
        self.assertGreater(rec["pid"], 0, "no attempt got a verified pid")
        self.assertIn(os.getpid(), rec["ancestors"], "the sender's parent chain should include this test process")

    def test_minor_levels(self):
        tag = "nwtest-low-%d" % os.getpid()
        self.send("-a", tag + "-low", "-u", "low", "quiet")
        self.assertEqual(self.stream.next(match=lambda r: r["app"] == tag + "-low")["urgency"], 0)
        self.send("-a", tag + "-normal", "-u", "normal", "normal")
        self.assertEqual(self.stream.next(match=lambda r: r["app"] == tag + "-normal")["urgency"], 1)

    def test_desktop_entry_hint_becomes_extra_name(self):
        tag = "nwtest-de-%d" % os.getpid()
        self.send("-a", tag, "-h", "string:desktop-entry:org.gnome.Nautilus", "x")
        rec = self.stream.next(match=lambda r: r["app"] == tag)
        self.assertIn("org.gnome.Nautilus", rec["extraNames"])

    def test_burst_is_not_dropped(self):
        tag = "nwtest-burst-%d" % os.getpid()
        for i in range(5):
            self.send("-a", "%s-%d" % (tag, i), "n")
        seen = {self.stream.next(match=lambda r: r["app"].startswith(tag))["app"] for _ in range(5)}
        self.assertEqual(seen, {"%s-%d" % (tag, i) for i in range(5)})


@unittest.skipUnless(shutil.which("inotifywait"), "needs inotifywait")
class LiveFilesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="nwtest-")
        self.stream = Stream("--source", "files", "--dir", self.tmp)
        time.sleep(0.8)  # inotifywait must be watching before we write

    def tearDown(self):
        self.stream.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, rel, text, atomic=False):
        path = os.path.join(self.tmp, rel)
        if atomic:
            tmp = path + ".part"
            with open(tmp, "w") as f: f.write(text)
            os.rename(tmp, path)  # moved_to
        else:
            with open(path, "w") as f: f.write(text)  # close_write

    N = '{"id":%d,"app":"%s","appIcon":"","summary":"s","urgency":%d,"timestamp":%d}'

    def test_direct_write_in_popup_dir(self):
        self.write("1-1.json", self.N % (1, "chromium", 1, 111))
        rec = self.stream.next()
        self.assertEqual((rec["app"], rec["urgency"], rec["source"]), ("chromium", 1, "files"))

    def test_atomic_rename_is_seen(self):
        self.write("2-2.json", self.N % (2, "slack", 2, 222), atomic=True)
        self.assertEqual(self.stream.next()["urgency"], 2)

    def test_history_dir_is_watched(self):
        self.write("history/3-3.json", self.N % (3, "mail", 1, 333))
        self.assertEqual(self.stream.next()["app"], "mail")

    def test_non_json_and_garbage_are_ignored_then_stream_continues(self):
        self.write("note.txt", "hello")
        self.write("4-4.json", "{not json")
        self.write("5-5.json", self.N % (5, "after", 1, 555))
        rec = self.stream.next()
        self.assertEqual(rec["app"], "after")

    def test_missing_dir_is_created(self):
        self.assertTrue(os.path.isdir(os.path.join(self.tmp, "history")))


def alive(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return False


def children_of(pid):
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
    return [int(p) for p in out]


def wait_dead(pids, timeout=4.0):
    end = time.time() + timeout
    while time.time() < end:
        if not any(alive(p) for p in pids):
            return True
        time.sleep(0.1)
    return False


class ProcessHygieneTests(unittest.TestCase):
    def watcher(self, *args):
        stream = Stream(*args)
        time.sleep(1.0)
        kids = children_of(stream.proc.pid)
        self.assertTrue(kids, "the watcher should have a child process")
        return stream, kids

    @unittest.skipUnless(shutil.which("inotifywait"), "needs inotifywait")
    def test_sigterm_takes_the_children_with_it(self):
        tmp = tempfile.mkdtemp(prefix="nwtest-")
        stream, kids = self.watcher("--source", "files", "--dir", tmp)
        try:
            stream.proc.terminate()
            stream.proc.wait(5)
            self.assertTrue(wait_dead(kids), "inotifywait outlived notify-watch (SIGTERM)")
        finally:
            stream.close()
            shutil.rmtree(tmp, ignore_errors=True)

    @unittest.skipUnless(shutil.which("busctl") and shutil.which("notify-send"), "needs busctl")
    def test_sigterm_takes_busctl_with_it(self):
        stream, kids = self.watcher("--source", "dbus")
        try:
            stream.proc.terminate()
            stream.proc.wait(5)
            self.assertTrue(wait_dead(kids), "busctl outlived notify-watch (SIGTERM)")
        finally:
            stream.close()

    @unittest.skipUnless(shutil.which("inotifywait"), "needs inotifywait")
    def test_parent_death_takes_everything_down(self):
        tmp = tempfile.mkdtemp(prefix="nwtest-")
        code = ("import subprocess,sys,time;"
                "p=subprocess.Popen([sys.executable,'-I',%r,'--source','files','--dir',%r]);"
                "print(p.pid,flush=True);time.sleep(60)") % (SCRIPT, tmp)
        wrapper = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True)
        try:
            watcher_pid = int(wrapper.stdout.readline())
            time.sleep(1.0)
            kids = children_of(watcher_pid)
            self.assertTrue(kids)
            wrapper.kill()          # SIGKILL: no chance to clean up
            wrapper.wait()
            self.assertTrue(wait_dead([watcher_pid] + kids, timeout=6), "notify-watch survived its parent")
        finally:
            wrapper.stdout.close()
            shutil.rmtree(tmp, ignore_errors=True)


@unittest.skipUnless(shutil.which("busctl") and shutil.which("notify-send"), "needs busctl + notify-send")
class LiveDbusHardeningTests(unittest.TestCase):
    def setUp(self):
        self.stream = Stream("--source", "dbus")
        time.sleep(1.0)

    def tearDown(self):
        self.stream.close()

    def test_a_spoofed_sender_pid_hint_is_ignored(self):
        tag = "nwtest-spoof-%d" % os.getpid()
        subprocess.run(["notify-send", "-a", tag, "-h", "int:sender-pid:1", "x"], check=True, timeout=5)
        rec = self.stream.next(match=lambda r: r["app"] == tag)
        self.assertIsNotNone(rec)
        self.assertNotEqual(rec["pid"], 1, "pid 1 must never be accepted from a hint")

    def test_flood_is_capped_and_the_stream_survives(self):
        tag = "nwtest-flood-%d" % os.getpid()
        subprocess.run(["sh", "-c", "for i in $(seq 200); do notify-send -a %s f$i; done" % tag], check=True, timeout=60)
        time.sleep(1.5)
        got = 0
        while self.stream.next(timeout=0.6, match=lambda r: r["app"] == tag):
            got += 1
        self.assertGreater(got, 0)
        self.assertLess(got, 200, "the rate limit should have dropped part of the flood")
        time.sleep(2.5)  # tokens refill
        subprocess.run(["notify-send", "-a", tag + "-after", "ok"], check=True, timeout=5)
        self.assertIsNotNone(self.stream.next(match=lambda r: r["app"] == tag + "-after"), "stream stalled after the flood")


@unittest.skipUnless(shutil.which("inotifywait"), "needs inotifywait")
class AutoFallbackTests(unittest.TestCase):
    def test_auto_uses_files_when_busctl_is_missing(self):
        tmp = tempfile.mkdtemp(prefix="nwtest-")
        bindir = tempfile.mkdtemp(prefix="nwbin-")
        os.symlink(shutil.which("inotifywait"), os.path.join(bindir, "inotifywait"))
        stream = Stream("--source", "auto", "--dir", tmp, env={"PATH": bindir, "HOME": os.environ.get("HOME", "/")})
        try:
            time.sleep(1.0)
            with open(os.path.join(tmp, "9-9.json"), "w") as f:
                f.write('{"id":9,"app":"fallback","summary":"s","urgency":1,"timestamp":1}')
            rec = stream.next()
            self.assertIsNotNone(rec, "auto mode did not fall back to files")
            self.assertEqual((rec["app"], rec["source"]), ("fallback", "files"))
        finally:
            stream.close()
            shutil.rmtree(tmp, ignore_errors=True)
            shutil.rmtree(bindir, ignore_errors=True)

    def test_fails_cleanly_with_no_tools_at_all(self):
        bindir = tempfile.mkdtemp(prefix="nwbin-")
        try:
            proc = subprocess.run([sys.executable, "-I", SCRIPT], capture_output=True, text=True, timeout=10,
                                  env={"PATH": bindir, "HOME": os.environ.get("HOME", "/")})
            self.assertEqual(proc.returncode, 1)
            self.assertIn("neither busctl nor inotifywait", proc.stderr)
        finally:
            shutil.rmtree(bindir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
