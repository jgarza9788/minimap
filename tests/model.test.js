// Run: node tests/model.test.js
const M = require("../Model.js");
let failed = 0;
function ok(name, cond) { console.log((cond ? "PASS " : "FAIL ") + name); if (!cond) failed++; }

ok("numbers", M.formatWorkspace(7, "numbers") === "7");
ok("roman 4/9/12", M.formatWorkspace(4, "roman") === "IV" && M.formatWorkspace(9, "roman") === "IX" && M.formatWorkspace(12, "roman") === "XII");
ok("japanese 3/10/12/20", M.formatWorkspace(3, "japanese") === "三" && M.formatWorkspace(10, "japanese") === "十"
  && M.formatWorkspace(12, "japanese") === "十二" && M.formatWorkspace(20, "japanese") === "二十");
ok("dots 1-5", ["", ".", ":", ".:", "::", ".::"].slice(1).every((s, i) => M.formatWorkspace(i + 1, "dots") === s));
ok("unknown style falls back", M.formatWorkspace(3, "bogus") === "3");

const c = (a, x, y, w, h) => ({ address: a, x, y, w, h, floating: false, title: a, appClass: a });
const cols = M.groupColumns([c("0xb", 1000, 0, 1000, 500), c("0xa", 0, 0, 1000, 1000), c("0xc", 1000, 500, 1000, 500)], false);
ok("two columns", cols.length === 2);
ok("stack grouped top-to-bottom", cols[1].windows.map(w => w.address).join() === "0xb,0xc");

const built = M.buildColumns([c("0xa", 0, 0, 1000, 1000), c("0xb", 1000, 0, 1000, 500), c("0xc", 1000, 500, 1000, 500)],
  { width: 2000, height: 1000, x: 0, y: 0 }, { start: 0, end: 1000 }, false, "0xb");
ok("column length px", built[0].len === 1000 && built[1].len === 1000);
ok("offscreen column", built[1].visibleFraction === 0 && built[0].visibleFraction === 1);
ok("focus flagged", built[1].windows[0].focused && !built[1].windows[1].focused);
ok("stack offsets/spans", built[1].windows[1].off === 500 && built[1].windows[1].span === 500);

const s = M.resolveSettings({ numberStyle: "roman", maxWidth: 99999 });
ok("settings clamp", s.numberStyle === "roman" && s.maxWidth === 600 && s.gap === 3);
// groups (tabbed windows)
const g = (a, hist) => Object.assign(c(a, 0, 0, 1000, 1000), { grouped: ["0xa1", "0xa2", "0xa3"], focusHistory: hist });
const grp = [g("0xa1", 5), g("0xa2", 1), g("0xa3", 3), c("0xz", 1000, 0, 1000, 1000)];
const folded = M.collapseGroups(grp, "");
ok("group folds to one box", folded.length === 2 && folded[0].tabs.length === 3);
ok("active tab = lowest focusHistory", folded[0].address === "0xa2");
ok("focused member wins", M.collapseGroups(grp, "0xa3")[0].address === "0xa3");
ok("ungrouped has no tabs", folded[1].tabs === null);
const gb = M.buildColumns(grp, { width: 2000, height: 1000, x: 0, y: 0 }, null, false, "0xa1");
ok("one column per group, focus via any tab", gb.length === 2 && gb[0].windows.length === 1 && gb[0].windows[0].focused);
ok("group style fallback", M.resolveGroupStyle("x") === "tabbar" && M.resolveGroupStyle("letter") === "letter");
ok("groupedOf normalizes", M.groupedOf({ grouped: ["ABC", "0xdef", "zz!"] }).join() === "0xabc,0xdef");

// layoutTape
const lt = M.layoutTape(built, { scale: 0.02, gap: 3, stackGap: 3, vertical: false });
ok("tape: 3 rows", lt.items.length === 3);
ok("tape: column x advances by len + gap", lt.items[0].bx === 0 && Math.abs(lt.items[1].bx - (1000 * 0.02 + 3)) < 1e-6);
ok("tape: stacked rows inset on inner edge only", Math.abs(lt.items[1].bh - (500 * 0.02 - 1.5)) < 1e-6 && lt.items[1].by === 0 && Math.abs(lt.items[2].by - (500 * 0.02 + 1.5)) < 1e-6);
ok("tape: total width", Math.abs(lt.total - (2000 * 0.02 + 3)) < 1e-6);
ok("tape: group key stable across active tab", M.buildColumns(grp, { width: 2000, height: 1000, x: 0, y: 0 }, null, false, "0xa1")[0].windows[0].key
  === M.buildColumns(grp, { width: 2000, height: 1000, x: 0, y: 0 }, null, false, "0xa3")[0].windows[0].key);

// animation styles + attention
ok("anim style fallback", M.resolveAnimStyle("x") === "smooth" && M.resolveAnimStyle("magic") === "magic");
ok("motionFor unknown = smooth", M.motionFor("nope") === M.motionFor("smooth"));
ok("every style has motion", M.ANIM_STYLE_ORDER.every(id => M.motionFor(id).k > 0 && M.ANIM_STYLES[id].label));
ok("settings: animStyle + attention default", M.resolveSettings({}).animStyle === "smooth" && M.resolveSettings({}).attention === true
  && M.resolveSettings({ attention: false }).attention === false);
ok("urgentAddress", M.urgentAddress("55D1AA") === "0x55d1aa" && M.urgentAddress("") === "");
const wins = [{ address: "0xa1", appClass: "com.mitchellh.ghostty" }, { address: "0xa2", appClass: "chromium" }, { address: "0xa3", appClass: "org.gnome.Nautilus" }];
ok("notif exact class", M.matchNotificationWindow(["chromium"], wins) === "0xa2");
ok("notif icon name = class", M.matchNotificationWindow(["", "com.mitchellh.ghostty"], wins) === "0xa1");
ok("notif last segment", M.matchNotificationWindow(["Nautilus"], wins) === "0xa3");
ok("notif loose contains", M.matchNotificationWindow(["ghostty-terminal"], wins) === "0xa1");
ok("notif no match", M.matchNotificationWindow(["slack"], wins) === "" && M.matchNotificationWindow([], wins) === "");

ok("attention level", M.attentionLevel(0) === 1 && M.attentionLevel(1) === 1 && M.attentionLevel(2) === 2 && M.attentionLevel(undefined) === 1);

const twins = [{ address: "0xb1", appClass: "ghostty", focusHistory: 4 }, { address: "0xb2", appClass: "ghostty", focusHistory: 1 }, { address: "0xb3", appClass: "ghostty", focusHistory: 7 }];
ok("notif: most recently used twin wins", M.matchNotificationWindow(["ghostty"], twins) === "0xb2");
ok("notif: exact beats more recent loose", M.matchNotificationWindow(["ghostty"], [{ address: "0xc1", appClass: "ghostty", focusHistory: 9 }, { address: "0xc2", appClass: "ghostty-nightly", focusHistory: 0 }]) === "0xc1");

// dots style: one run, no spaces
const dots = n => M.formatWorkspace(n, "dots");
ok("dots 1-9", [".", ":", ".:", "::", ".::", ":::", ".:::", "::::", ".::::"].every((s, i) => dots(i + 1) === s));
ok("dots 10-12", dots(10) === ":::::" && dots(11) === ".:::::" && dots(12) === "::::::");
ok("dots never contain spaces", [1, 5, 10, 11, 16, 20, 30].every(n => dots(n).indexOf(" ") === -1));
ok("dots length = ceil(n/2)", [1, 2, 7, 10, 15, 20].every(n => dots(n).length === Math.ceil(n / 2)));

// ---- 1.1: state flags, settings, box actions, alert target, drag helpers
const flagTops = [{ address: "0xaa", lastIpcObject: { class: "a", at: [0, 0], size: [10, 10], workspace: { id: 1 }, pinned: true, fullscreen: 2, floating: true } },
  { address: "0xbb", lastIpcObject: { class: "b", at: [20, 0], size: [10, 10], workspace: { id: 1 }, fullscreen: 0 } }];
const flagged = M.eligibleClients(flagTops, 1, true);
ok("flags: pinned + fullscreen carried", flagged[0].pinned === true && flagged[0].fullscreen === true && flagged[1].pinned === false && flagged[1].fullscreen === false);
const flagCols = M.buildColumns(flagged, { width: 1000, height: 1000, x: 0, y: 0 }, null, false, "");
const flagTape = M.layoutTape(flagCols, { scale: 0.1, gap: 2, stackGap: 3, vertical: false });
ok("flags: reach the tape rows", flagTape.items[0].pinned === true && flagTape.items[0].fullscreen === true && flagTape.items[0].floating === true && flagTape.items[1].pinned === false);
ok("tape: column bounds for dragging", flagTape.cols.length === 2 && flagTape.cols[0].start === 0 && flagTape.cols[1].start > flagTape.cols[0].len);

const ds = M.resolveSettings({});
ok("settings 1.1 defaults", ds.boxActions === false && ds.dragReorder === false && ds.stateMarkers === true);
const ds2 = M.resolveSettings({ boxActions: true, dragReorder: true, stateMarkers: false });
ok("settings 1.1 values", ds2.boxActions === true && ds2.dragReorder === true && ds2.stateMarkers === false);
ok("settings 1.1 odd values", M.resolveSettings({ boxActions: "yes", dragReorder: 1 }).boxActions === false && M.resolveSettings({ stateMarkers: "no" }).stateMarkers === true);

const ids = w => M.menuItemsFor(w).map(i => i.id).join();
ok("menu: tiled window", ids({}) === "focus,float,fullscreen,pin,moveto,close,settings");
ok("menu: tabbed adds ungroup", ids({ tabbed: true }) === "focus,float,fullscreen,pin,ungroup,moveto,close,settings");
ok("menu: pin needs floating", M.menuItemsFor({}).find(i => i.id === "pin").enabled === false
  && M.menuItemsFor({ floating: true }).find(i => i.id === "pin").enabled === true
  && M.menuItemsFor({ pinned: true }).find(i => i.id === "pin").enabled === true);
ok("menu: labels follow state", M.menuItemsFor({ floating: true }).find(i => i.id === "float").label === "Make tiled"
  && M.menuItemsFor({ fullscreen: true }).find(i => i.id === "fullscreen").label === "Exit fullscreen"
  && M.menuItemsFor({ pinned: true }).find(i => i.id === "pin").label === "Unpin");
ok("menu: close is the only danger row", M.menuItemsFor({}).filter(i => i.danger).map(i => i.id).join() === "close");

const cmd = (id, addr, lua, arg) => M.actionCommand(id, addr, lua, arg);
ok("cmd: close targets the address (lua)", cmd("close", "0xAB12", true).join("|") === 'hl.dsp.window.close({ window = "address:0xab12" })');
ok("cmd: close (legacy)", cmd("close", "ab12", false).join("|") === "closewindow address:0xab12");
ok("cmd: float is explicit", cmd("float", "0xab12", true)[0].indexOf('window = "address:0xab12"') !== -1 && cmd("float", "0xab12", false)[0] === "togglefloating address:0xab12");
ok("cmd: fullscreen/pin/ungroup focus first", ["fullscreen", "pin", "ungroup"].every(id => cmd(id, "0xab12", true).length === 2 && cmd(id, "0xab12", true)[0].indexOf("hl.dsp.focus") === 0));
ok("cmd: move to workspace", cmd("moveto", "0xab12", true, 4)[1] === 'hl.dsp.window.move({ workspace = "4" })' && cmd("moveto", "0xab12", false, 10)[1] === "movetoworkspace 10");
ok("cmd: bad workspace refused", [0, 11, -1, 2.5, "x", undefined].every(n => cmd("moveto", "0xab12", true, n).length === 0));
ok("cmd: bad address refused", ["", "nope!", '0xab" }) os.execute("x', undefined, "0xg1"].every(a => cmd("close", a, true).length === 0));
ok("cmd: unknown action refused", cmd("format-disk", "0xab12", true).length === 0 && cmd("settings", "0xab12", true).length === 0);
ok("cmd: no injection through the address", cmd("focus", '0xab12" }) hl.exit({', true).length === 0);

const meta = { "0xa1": 1, "0xa2": 2, "0xa3": 2 };
ok("alert target: critical, then newest", M.pickAlertTarget(meta, { "0xa1": 900, "0xa2": 100, "0xa3": 200 }) === "0xa3");
ok("alert target: minor when only minor", M.pickAlertTarget({ "0xa1": 1, "0xa2": 1 }, { "0xa1": 5, "0xa2": 9 }) === "0xa2");
ok("alert target: critical beats a newer minor", M.pickAlertTarget({ "0xa1": 1, "0xa2": 2 }, { "0xa1": 999, "0xa2": 1 }) === "0xa2");
ok("alert target: none", M.pickAlertTarget({}, {}) === "" && M.pickAlertTarget(undefined, undefined) === "");

const cols3 = [{ start: 0, len: 100 }, { start: 110, len: 200 }, { start: 320, len: 100 }];
ok("slotAt: nearest centre", M.slotAt(cols3, 10) === 0 && M.slotAt(cols3, 200) === 1 && M.slotAt(cols3, 400) === 2);
ok("slotAt: outside the row clamps", M.slotAt(cols3, -500) === 0 && M.slotAt(cols3, 9999) === 2);
ok("slotAt: empty", M.slotAt([], 5) === -1);
ok("swapPlan: right/left/none", M.swapPlan(0, 2).join() === "r,r" && M.swapPlan(3, 1).join() === "l,l" && M.swapPlan(2, 2).length === 0);
ok("swapPlan: invalid", M.swapPlan(-1, 2).length === 0 && M.swapPlan("x", 2).length === 0 && M.swapPlan(1, NaN).length === 0);

ok("swapCommands: lua + legacy", M.swapCommands(["r", "l"], true).join("|") === 'hl.dsp.layout("swapcol r")|hl.dsp.layout("swapcol l")'
  && M.swapCommands(["r"], false)[0] === "layoutmsg swapcol r");
ok("swapCommands: junk refused", M.swapCommands(["r", "x"], true).length === 0 && M.swapCommands(undefined, true).length === 0 && M.swapCommands(['r" ) exit(', "l"], true).length === 0);

// Stale toplevels (not in hyprctl's live set) are dropped.
;(function () {
  var M = require("../Model.js")
  var mk = function (a) { return { address: a, lastIpcObject: { mapped: true, workspace: { id: 1 }, at: [0, 0], size: [10, 10] } } }
  var tops = [mk("61ba1"), mk("61ba2")]
  var assert = require("assert")
  assert.strictEqual(M.eligibleClients(tops, 1, false).length, 2)
  assert.deepStrictEqual(M.eligibleClients(tops, 1, false, { "0x61ba1": true }).map(function (c) { return c.address }), ["0x61ba1"])
  console.log("ok live filter")
})()

process.exit(failed ? 1 : 0);
