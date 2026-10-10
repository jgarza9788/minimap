// Run: node tests/attention.test.js
// Alerts: urgent events, notification parsing/matching, minor vs critical
// levels, and how alerts turn into per-box cues, the number cue, or nothing.
const M = require("../Model.js");

let failed = 0;
function ok(name, cond) { console.log((cond ? "PASS " : "FAIL ") + name); if (!cond) failed++; }

// ---- levels ---------------------------------------------------------------
ok("urgency 0/1 = minor", M.attentionLevel(0) === 1 && M.attentionLevel(1) === 1);
ok("urgency 2 = critical", M.attentionLevel(2) === 2);
ok("urgency above 2 = critical", M.attentionLevel(3) === 2);
ok("missing/odd urgency = minor", M.attentionLevel(undefined) === 1 && M.attentionLevel("x") === 1 && M.attentionLevel(null) === 1);

// ---- Hyprland urgent event --------------------------------------------------
ok("urgent: bare hex gets 0x", M.urgentAddress("55D1AA") === "0x55d1aa");
ok("urgent: 0x kept", M.urgentAddress("0x55d1aa") === "0x55d1aa");
ok("urgent: first field only", M.urgentAddress("55d1aa,extra") === "0x55d1aa");
ok("urgent: junk/empty", M.urgentAddress("nope!") === "" && M.urgentAddress("") === "" && M.urgentAddress(undefined) === "");

// ---- parsing one notification file ---------------------------------------------
const line = '{"id":9,"originalId":9,"app":"","appIcon":"com.mitchellh.ghostty","summary":"Claude Code","body":"needs approval","urgency":1,"timestamp":1791588854872}';
const n = M.parseNotification(line);
ok("parse: id is timestamp-id", n && n.id === "1791588854872-9");
ok("parse: names are app + icon", n && n.names[0] === "" && n.names[1] === "com.mitchellh.ghostty");
ok("parse: level from urgency", n && n.level === 1);
ok("parse: critical", M.parseNotification('{"id":1,"urgency":2,"timestamp":5}').level === 2);
ok("parse: same toast, same id (dedupe key)", M.parseNotification(line).id === n.id);
ok("parse: garbage -> null", M.parseNotification("not json") === null && M.parseNotification("") === null && M.parseNotification("42") === null);

// ---- matching a notification to a window --------------------------------------
const win = (address, appClass, focusHistory) => ({ address, appClass, focusHistory });
const wins = [win("0xa1", "com.mitchellh.ghostty", 3), win("0xa2", "chromium", 2), win("0xa3", "org.gnome.Nautilus", 5), win("0xa4", "com.microsoft.VSCode", 1)];
ok("match: exact class", M.matchNotificationWindow(["chromium"], wins) === "0xa2");
ok("match: case-insensitive", M.matchNotificationWindow(["Chromium"], wins) === "0xa2");
ok("match: icon name equals class", M.matchNotificationWindow(["", "com.mitchellh.ghostty"], wins) === "0xa1");
ok("match: last dotted segment of class", M.matchNotificationWindow(["Nautilus"], wins) === "0xa3");
ok("match: .desktop suffix ignored", M.matchNotificationWindow(["chromium.desktop"], wins) === "0xa2");
ok("match: loose contains (4+ chars)", M.matchNotificationWindow(["ghostty-terminal"], wins) === "0xa1");
ok("match: short names are not loose-matched", M.matchNotificationWindow(["vs"], wins) === "");
ok("match: unknown app -> none", M.matchNotificationWindow(["slack"], wins) === "");
ok("match: no names / no windows", M.matchNotificationWindow([], wins) === "" && M.matchNotificationWindow(["chromium"], []) === "");
ok("match: undefined entries tolerated", M.matchNotificationWindow([undefined, null, "chromium"], wins) === "0xa2");

const twins = [win("0xb1", "ghostty", 4), win("0xb2", "ghostty", 1), win("0xb3", "ghostty", 7)];
ok("match: twins -> most recently used", M.matchNotificationWindow(["ghostty"], twins) === "0xb2");
ok("match: exact beats a more recent loose match",
  M.matchNotificationWindow(["ghostty"], [win("0xc1", "ghostty", 9), win("0xc2", "ghostty-nightly", 0)]) === "0xc1");
ok("match: missing focusHistory sorts last",
  M.matchNotificationWindow(["ghostty"], [{ address: "0xd1", appClass: "ghostty" }, win("0xd2", "ghostty", 8)]) === "0xd2");

// ---- row keys and alert reconciliation --------------------------------------------
const col = (windows) => ({ windows });
const columns = [
  col([{ key: "0xa1", address: "0xa1" }]),
  col([{ key: "0xa2", address: "0xa2" }, { key: "0xa3", address: "0xa3" }]),
  col([{ key: "0xe1", address: "0xe2", tabs: [{ address: "0xe1" }, { address: "0xe2" }, { address: "0xe3" }] }])
];
const everything = { "0xa1": true, "0xa2": true, "0xa3": true, "0xe1": true, "0xe2": true, "0xe3": true, "0xff": true };

ok("rowKey: plain window", M.rowKeyFor(columns, "0xa3") === "0xa3");
ok("rowKey: any tab of a group", M.rowKeyFor(columns, "0xe3") === "0xe1" && M.rowKeyFor(columns, "0xe2") === "0xe1");
ok("rowKey: not on this workspace", M.rowKeyFor(columns, "0xff") === "");

let r = M.reconcileAlerts({ "0xa2": 1 }, everything, "0xa1", columns);
ok("reconcile: alert becomes a box cue", r.attention["0xa2"] === 1 && r.otherLevel === 0 && !r.changed);

r = M.reconcileAlerts({ "0xa2": 2 }, everything, "0xa1", columns);
ok("reconcile: critical level kept", r.attention["0xa2"] === 2);

r = M.reconcileAlerts({ "0xa2": 1 }, everything, "0xa2", columns);
ok("reconcile: focusing the window clears its alert", r.attention["0xa2"] === undefined && r.alerts["0xa2"] === undefined && r.changed);

r = M.reconcileAlerts({ "0xe1": 1 }, everything, "0xe3", columns);
ok("reconcile: focusing another tab of the group clears it", Object.keys(r.attention).length === 0 && r.changed);

r = M.reconcileAlerts({ "0xe3": 2 }, everything, "0xa1", columns);
ok("reconcile: alert on a background tab lights the group box", r.attention["0xe1"] === 2);

r = M.reconcileAlerts({ "0xa2": 1 }, { "0xa1": true }, "0xa1", columns);
ok("reconcile: closed window drops its alert", Object.keys(r.attention).length === 0 && r.changed);

r = M.reconcileAlerts({ "0xff": 1 }, everything, "0xa1", columns);
ok("reconcile: other-workspace alert goes to the number", r.otherLevel === 1 && Object.keys(r.attention).length === 0 && r.alerts["0xff"] === 1);

r = M.reconcileAlerts({ "0xff": 1, "0xa2": 2 }, everything, "0xa1", columns);
ok("reconcile: box cue and number cue together", r.attention["0xa2"] === 2 && r.otherLevel === 1);

r = M.reconcileAlerts({ "0xff": 1, "0xf1": 2 }, Object.assign({ "0xf1": true }, everything), "0xa1", columns);
ok("reconcile: number takes the highest level", r.otherLevel === 2);

r = M.reconcileAlerts({ "0xa1": 1 }, everything, "", columns);
ok("reconcile: no focused window clears nothing", r.attention["0xa1"] === 1);

r = M.reconcileAlerts({}, everything, "0xa1", columns);
ok("reconcile: empty alerts", r.otherLevel === 0 && Object.keys(r.attention).length === 0 && !r.changed);

r = M.reconcileAlerts(undefined, everything, "0xa1", undefined);
ok("reconcile: tolerates missing inputs", r.otherLevel === 0 && !r.changed);

// ---- settings --------------------------------------------------------------------------
ok("settings: attention on by default", M.resolveSettings({}).attention === true);
ok("settings: attention can be turned off", M.resolveSettings({ attention: false }).attention === false);
ok("settings: odd value keeps it on", M.resolveSettings({ attention: "no" }).attention === true);

// ---- every style has the motion numbers the cues rely on -------------------------
ok("styles: all five exist", M.ANIM_STYLE_ORDER.join() === "smooth,cyberpunk,fun,magic,ripple");
ok("styles: motion params are numbers",
  M.ANIM_STYLE_ORDER.every(id => ["k", "d", "popTo", "popOvershoot", "popIn", "popOut", "hover", "swapOut", "swapIn", "wobble"]
    .every(f => typeof M.motionFor(id)[f] === "number")));

// ---- process-based matching (sender pid and its ancestors) ------------------------
const pw = (address, appClass, pid, focusHistory) => ({ address, appClass, pid, focusHistory });
const pwins = [pw("0xf1", "com.mitchellh.ghostty", 500, 4), pw("0xf2", "com.mitchellh.ghostty", 500, 1), pw("0xf3", "slack", 900, 6), pw("0xf4", "chromium", 700, 2)];
ok("pid: sender owns a window", M.matchNotificationWindow(["whatever"], pwins, [900]) === "0xf3");
ok("pid: wins over a conflicting name", M.matchNotificationWindow(["chromium"], pwins, [900]) === "0xf3");
ok("pid: terminal ancestor found for a script", M.matchNotificationWindow(["notify-send"], pwins, [4242, 4000, 500, 1]) === "0xf2");
ok("pid: nearest ancestor with a window wins", M.matchNotificationWindow([], pwins, [4242, 700, 500]) === "0xf4");
ok("pid: unknown pids fall back to the name", M.matchNotificationWindow(["slack"], pwins, [31337]) === "0xf3");
ok("pid: none and no name -> none", M.matchNotificationWindow([], pwins, [31337]) === "");
ok("pid: empty list = name matching only", M.matchNotificationWindow(["slack"], pwins, []) === "0xf3");
ok("pid: windows with no pid are ignored", M.matchNotificationWindow([], [{ address: "0xaa", appClass: "x", focusHistory: 0 }], [0]) === "");

// ---- the focused window is not the sender --------------------------------------------
const ghosts = [{ address: "0xa1", appClass: "ghostty", focusHistory: 0 }, { address: "0xa2", appClass: "ghostty", focusHistory: 3 },
  { address: "0xa3", appClass: "ghostty", focusHistory: 1 }];
ok("name: another window of the app beats the focused one", M.matchNotificationWindow(["ghostty"], ghosts, []) === "0xa3");
ok("name: loose match also skips the focused window", M.matchNotificationWindow(["com.mitchellh.ghostty"], ghosts, []) === "0xa3");
ok("name: only the focused window -> still returned", M.matchNotificationWindow(["ghostty"], [ghosts[0]], []) === "0xa1");
ok("pid: same-pid windows skip the focused one", M.matchNotificationWindow([], [{ address: "0xb1", pid: 9, focusHistory: 0 }, { address: "0xb2", pid: 9, focusHistory: 2 }], [9]) === "0xb2");

// ---- the record notify-watch emits ---------------------------------------------------
const rec = M.parseNotification(JSON.stringify({ id: 7, timestamp: 1791590587357, app: "notify-send", appIcon: "", urgency: 2,
  extraNames: ["org.gnome.Nautilus", "folder"], pid: 4242, ancestors: [4000, 500, 1], source: "dbus" }));
ok("record: names include extras", rec.names.join() === "notify-send,,org.gnome.Nautilus,folder");
ok("record: pids are sender then ancestors, init dropped", rec.pids.join() === "4242,4000,500");
ok("record: critical", rec.level === 2);
ok("record: file records have no pids", M.parseNotification('{"id":1,"app":"a","urgency":1,"timestamp":2}').pids.length === 0);
ok("record: eligibleClients carries pid", M.eligibleClients([{ address: "0xaa", lastIpcObject: { class: "x", at: [0, 0], size: [10, 10], workspace: { id: 1 }, pid: 321 } }], 1)[0].pid === 321);

console.log(failed ? `\n${failed} FAILED` : "\nall passed");
process.exit(failed ? 1 : 0);
