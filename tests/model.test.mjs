// Tests for Model.js. Run: node --test tests/model.test.mjs
import { test } from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const Model = require("../Model.js")

const MARKUP = '<img src="https://example.invalid/x">'

function status(obj) {
  return JSON.stringify(obj)
}

function track(...lines) {
  // Feeds status lines through the reducer, collecting notices.
  let tracker = Model.initialTracker()
  const notices = []
  for (const line of lines) {
    const parsed = Model.parseStatus(typeof line === "string" ? line : status(line.s))
    if (!parsed.ok) continue
    const step = Model.reduceStatus(tracker, parsed, line.expectingDrop === true)
    tracker = step.tracker
    if (step.notice) notices.push(step.notice)
  }
  return { tracker, notices }
}

test("parseStatus accepts the CLI contract", () => {
  const r = Model.parseStatus(status({ profile: "work", state: "up", url: null, message: null }))
  assert.deepEqual(r, { ok: true, state: "up", profile: "work", url: "", message: "" })
  const down = Model.parseStatus(status({ profile: null, state: "down", url: null, message: null }))
  assert.equal(down.ok, true)
  assert.equal(down.profile, "")
})

test("bad JSON and unknown shapes are rejected so the last state is kept", () => {
  for (const raw of ["", "   ", "{", "not json", "[]", "null", "42", '"up"', status({ state: "exploded" }), status({ profile: "x" }), "x".repeat(70000)]) {
    assert.equal(Model.parseStatus(raw).ok, false, raw.slice(0, 40))
  }
  assert.equal(Model.parseStatus(undefined).ok, false)
  // A garbled line between two good ones leaves the tracker on the good state
  // and does not count as a transition.
  const { tracker, notices } = track(
    { s: { profile: "work", state: "up" } },
    "{garbage",
    { s: { profile: "work", state: "up" } }
  )
  assert.equal(tracker.last.state, "up")
  assert.deepEqual(notices, [])
})

test("profile names are validated before reaching argv", () => {
  assert.equal(Model.validProfile("work"), "work")
  assert.equal(Model.validProfile("work_2-eu"), "work_2-eu")
  for (const bad of ["", "-rf", "--help", "a b", "a;b", "$(id)", "../x", MARKUP, "x".repeat(65), null, 5, {}]) {
    assert.equal(Model.validProfile(bad), "", String(bad))
  }
  assert.equal(Model.validProfile("x".repeat(64)), "x".repeat(64))
  const r = Model.parseStatus(status({ profile: MARKUP, state: "up" }))
  assert.equal(r.ok, true)
  assert.equal(r.profile, "")
})

test("parseProfiles drops invalid names, folds duplicates and bounds the list", () => {
  const r = Model.parseProfiles(JSON.stringify(["work", "work", MARKUP, "-x", 7, null, "test"]))
  assert.deepEqual(r, { ok: true, profiles: ["work", "test"] })
  assert.equal(Model.parseProfiles("{").ok, false)
  assert.equal(Model.parseProfiles('{"a":1}').ok, false)
  const many = Array.from({ length: 500 }, (_, i) => "p" + i)
  assert.equal(Model.parseProfiles(JSON.stringify(many)).profiles.length, 100)
})

test("displayProfiles adds the current profile when the list lags", () => {
  assert.deepEqual(Model.displayProfiles(["a", "b"], "c"), ["c", "a", "b"])
  assert.deepEqual(Model.displayProfiles(["a", "b"], "a"), ["a", "b"])
  assert.deepEqual(Model.displayProfiles(null, ""), [])
})

test("only https login URLs with a plain host are opened", () => {
  assert.equal(Model.isSafeLoginUrl("https://vpn.example.com/remote/saml/start?redirect=1"), true)
  assert.equal(Model.isSafeLoginUrl("https://vpn.example.com:10443/x"), true)
  assert.equal(Model.isSafeLoginUrl("https://127.0.0.1:8020"), true)
  for (const bad of [
    "http://vpn.example.com/",
    "javascript:alert(1)",
    "file:///etc/passwd",
    "HTTPS://vpn.example.com",
    "https://",
    "https://good.example@evil.example/",
    "https://vpn.example.com/a b",
    "https://vpn.example.com/\nx",
    " https://vpn.example.com/",
    "--new-window",
    "https://" + "a".repeat(3000),
    MARKUP,
    null,
    42
  ]) {
    assert.equal(Model.isSafeLoginUrl(bad), false, String(bad))
    assert.deepEqual(Model.browserArgv(bad), [])
  }
  assert.deepEqual(Model.browserArgv("https://vpn.example.com/x"), ["omarchy-launch-browser", "https://vpn.example.com/x"])
  // A non-https url in status is dropped, not passed on.
  const r = Model.parseStatus(status({ profile: "work", state: "connecting", url: "http://vpn.example.com/" }))
  assert.equal(r.url, "")
})

test("neutralizeMarkup leaves no tags, entities or auto-links", () => {
  const out = Model.neutralizeMarkup(MARKUP)
  assert.doesNotMatch(out, /[<>&]/)
  assert.doesNotMatch(out, /https?:\/\//)
  for (const raw of ["<b>bold</b>", "&lt;img src=x&gt;", "&amp;lt;a href=&quot;https://x&quot;&gt;", "<a href=\"https://evil.example\">ok</a>", "Tom & Jerry", "see https://evil.example/phish"]) {
    const n = Model.neutralizeMarkup(raw)
    assert.doesNotMatch(n, /[<>&]/, raw)
    assert.doesNotMatch(n, /https?:\/\//, raw)
  }
  assert.equal(Model.neutralizeMarkup("line1\nline2\u0007"), "line1 line2")
  assert.ok(Model.neutralizeMarkup("x".repeat(1000)).length <= Model.MAX_MESSAGE)
})

test("status message is bounded and flattened", () => {
  const r = Model.parseStatus(status({ profile: "work", state: "failed", message: "a\nb" + "x".repeat(1000) }))
  assert.ok(r.message.length <= Model.MAX_MESSAGE)
  assert.doesNotMatch(r.message, /\n/)
  assert.equal(Model.parseStatus(status({ state: "failed", message: { toString: 1 } })).message, "")
})

test("transitions: down → connecting → up notifies connected once", () => {
  const { notices } = track(
    { s: { profile: null, state: "down" } },
    { s: { profile: "work", state: "connecting", url: "https://vpn.example.com/" } },
    { s: { profile: "work", state: "up" } },
    { s: { profile: "work", state: "up" } }
  )
  assert.deepEqual(notices, [{ kind: "connected", profile: "work" }])
})

test("transitions: the first status after start is silent", () => {
  assert.deepEqual(track({ s: { profile: "work", state: "up" } }).notices, [])
  assert.deepEqual(track({ s: { profile: "work", state: "failed", message: "x" } }).notices, [])
})

test("transitions: → failed notifies with the message, once", () => {
  const { notices, tracker } = track(
    { s: { profile: "work", state: "connecting" } },
    { s: { profile: "work", state: "failed", message: "SAML timeout" } },
    { s: { profile: "work", state: "failed", message: "SAML timeout" } }
  )
  assert.deepEqual(notices, [{ kind: "failed", profile: "work", message: "SAML timeout" }])
  assert.equal(Model.displayState(true, tracker), "failed")
})

test("transitions: an unexpected drop from up notifies disconnected", () => {
  const { notices } = track({ s: { profile: "work", state: "up" } }, { s: { profile: null, state: "down" } })
  assert.deepEqual(notices, [{ kind: "disconnected", profile: "work" }])
})

test("transitions: up → failed is one failed notice carrying the message", () => {
  const { notices } = track({ s: { profile: "work", state: "up" } }, { s: { profile: null, state: "failed", message: "peer reset" } })
  assert.deepEqual(notices, [{ kind: "failed", profile: "work", message: "peer reset" }])
})

test("transitions: the user's own Disconnect does not notify", () => {
  const { notices } = track({ s: { profile: "work", state: "up" } }, { s: { profile: null, state: "down" }, expectingDrop: true })
  assert.deepEqual(notices, [])
  const failedOnDown = track({ s: { profile: "work", state: "up" } }, { s: { profile: "work", state: "failed" }, expectingDrop: true })
  assert.deepEqual(failedOnDown.notices, [])
})

test("transitions: switching profiles notifies the new one", () => {
  const { notices } = track({ s: { profile: "a", state: "up" } }, { s: { profile: "b", state: "up" } })
  assert.deepEqual(notices, [{ kind: "connected", profile: "b" }])
})

test("transitions: connecting → down (login abandoned) is silent", () => {
  assert.deepEqual(track({ s: { profile: "a", state: "connecting" } }, { s: { profile: null, state: "down" } }).notices, [])
})

test("failure stays visible after the CLI falls back to down, until the user acts", () => {
  let { tracker } = track(
    { s: { profile: "work", state: "connecting" } },
    { s: { profile: "work", state: "failed", message: "bad cookie" } },
    { s: { profile: null, state: "down" } }
  )
  assert.equal(Model.displayState(true, tracker), "failed")
  assert.equal(Model.displayProfile(tracker), "work")
  assert.equal(Model.displayMessage(tracker), "bad cookie")
  tracker = Model.acknowledgeFailure(tracker)
  assert.equal(Model.displayState(true, tracker), "down")
  assert.equal(Model.displayMessage(tracker), "")
  // Coming back up clears it too.
  const back = track(
    { s: { profile: "work", state: "failed", message: "x" } },
    { s: { profile: "work", state: "up" } }
  )
  assert.equal(Model.displayState(true, back.tracker), "up")
})

test("displayState is missing when the CLI is not installed", () => {
  assert.equal(Model.displayState(false, Model.initialTracker()), "missing")
  assert.equal(Model.displayState(true, Model.initialTracker()), "down")
})

test("icon and labels per state", () => {
  assert.deepEqual(Model.iconSpec("down").tone, "dim")
  assert.deepEqual(Model.iconSpec("missing").tone, "dim")
  assert.deepEqual(Model.iconSpec("up"), { glyph: "\u{F0498}", tone: "normal", pulse: false })
  assert.equal(Model.iconSpec("connecting").pulse, true)
  assert.equal(Model.iconSpec("connecting").tone, "accent")
  assert.equal(Model.iconSpec("failed").tone, "error")
  assert.equal(Model.tooltipText("up", "work"), "VPN: work — connected")
  assert.equal(Model.tooltipText("down", ""), "VPN: disconnected")
  assert.equal(Model.tooltipText("up", MARKUP), "VPN: connected")
  // A translator that reorders placeholders still gets both values.
  const tr = (key, en) => (key === "tooltip.withProfile" ? "%2 (%1)" : en)
  assert.equal(Model.tooltipText("connecting", "work", tr), "connecting (work)")
  // "$&" in a value is not treated as a replacement pattern.
  const tr2 = (key, en) => (key === "state.up" ? "$&$1" : en)
  assert.equal(Model.tooltipText("up", "work", tr2), "VPN: work — $&$1")
})

test("notification argv: neutralized, -- before text, never a shell string", () => {
  const G = "\u{F0498}  "
  const argv = Model.noticeArgv({ kind: "failed", profile: "work", message: MARKUP + " see https://evil.example/" })
  assert.deepEqual(argv.slice(0, 4), ["notify-send", "-a", "OpenFortiVPN", "--"])
  assert.equal(argv[4], G + "VPN work failed")
  assert.doesNotMatch(argv[5], /[<>&]/)
  assert.doesNotMatch(argv[5], /https?:\/\//)
  assert.deepEqual(Model.noticeArgv({ kind: "connected", profile: "work" }), ["notify-send", "-a", "OpenFortiVPN", "--", G + "VPN work connected"])
  assert.deepEqual(Model.noticeArgv({ kind: "disconnected", profile: "" }), ["notify-send", "-a", "OpenFortiVPN", "--", G + "VPN disconnected"])
  assert.deepEqual(Model.noticeArgv({ kind: "connected", profile: MARKUP }), ["notify-send", "-a", "OpenFortiVPN", "--", G + "VPN connected"])
  assert.deepEqual(Model.noticeArgv(null), [])
  assert.deepEqual(Model.noticeArgv({ kind: "other" }), [])
  // A message that looks like an option stays after "--".
  const opt = Model.noticeArgv({ kind: "failed", profile: "a", message: "-u critical" })
  assert.equal(opt[3], "--")
  assert.equal(opt[5], "-u critical")
})

test("poll interval: 3 s while connecting or right after an action", () => {
  assert.equal(Model.pollIntervalMs("connecting", 15, 0), 3000)
  assert.equal(Model.pollIntervalMs("down", 15, 3), 3000)
  assert.equal(Model.pollIntervalMs("up", 15, 0), 15000)
  assert.equal(Model.pollIntervalMs("up", 1, 0), 5000)
  assert.equal(Model.pollIntervalMs("up", 99999, 0), 3600000)
  assert.equal(Model.pollIntervalMs("up", "junk", 0), 15000)
})

test("CLI path is absolute from HOME and the log command is quoted", () => {
  assert.equal(Model.cliPath("/home/sf"), "/home/sf/.local/bin/fortivpn")
  assert.equal(Model.cliPath("/home/sf/"), "/home/sf/.local/bin/fortivpn")
  assert.equal(Model.cliPath(""), "")
  assert.equal(Model.cliPath("relative"), "")
  assert.equal(Model.cliPath(undefined), "")
  assert.deepEqual(Model.logArgv("/home/sf/.local/bin/fortivpn"), ["omarchy-launch-floating-terminal-with-presentation", "'/home/sf/.local/bin/fortivpn' log"])
  assert.deepEqual(Model.logArgv("/home/o'brien/.local/bin/fortivpn")[1], "'/home/o'\\''brien/.local/bin/fortivpn' log")
  assert.deepEqual(Model.logArgv(""), [])
})
