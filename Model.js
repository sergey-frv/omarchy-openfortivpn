// Pure logic for the OpenFortiVPN bar widget: parsing and validating what the
// `fortivpn` CLI prints, mapping state to the icon and labels, deciding which
// transitions notify, and neutralizing markup before it reaches a sink the
// plugin does not control. Everything from the CLI is untrusted.
//
// Loaded by QML (`import "Model.js" as Model`) and by node for the tests
// (`tests/model.test.mjs`), so it sticks to plain functions and `var`.

var STATES = ["down", "connecting", "up", "failed"]
var MAX_RAW = 65536
var MAX_PROFILE = 64
var MAX_PROFILES = 100
var MAX_MESSAGE = 300
var MAX_URL = 2048
var MAX_SINCE = 1e11
var FAST_POLL_MS = 3000

function translator(tr) {
  return typeof tr === "function" ? tr : function(key, english) { return english }
}

// Replace "%1" with a value without String.replace's "$&"-style patterns.
function fill(template, value) {
  return String(template).replace("%1", function() { return String(value) })
}

// The CLI lives in ~/.local/bin, which the shell's PATH may not include, so
// it is always called by absolute path built from HOME.
function cliPath(home) {
  var value = String(home || "").replace(/\/+$/, "")
  if (value === "" || value.charAt(0) !== "/") return ""
  if (/[\x00-\x1f\x7f]/.test(value)) return ""
  return value + "/.local/bin/fortivpn"
}

// A profile name goes into argv, so it must look like a name and not an
// option: letters, digits, `_` and `-`, not starting with `-`.
function validProfile(value) {
  if (typeof value !== "string") return ""
  if (value.length === 0 || value.length > MAX_PROFILE) return ""
  if (!/^[A-Za-z0-9_-]+$/.test(value)) return ""
  if (value.charAt(0) === "-") return ""
  return value
}

// One line, control characters removed, bounded.
function cleanText(value, max) {
  if (typeof value !== "string") return ""
  var text = value.replace(/[\r\n\t]+/g, " ").replace(/[\x00-\x1f\x7f-\x9f]/g, "")
  text = text.replace(/\s+/g, " ").trim()
  var limit = typeof max === "number" ? max : MAX_MESSAGE
  return text.length > limit ? text.substring(0, limit - 1) + "…" : text
}

// Only https links with a plain host open in the browser. Userinfo
// ("https://good@evil"), whitespace and control characters are refused.
function isSafeLoginUrl(value) {
  if (typeof value !== "string") return false
  if (value.length < 9 || value.length > MAX_URL) return false
  if (/[\s\x00-\x1f\x7f-\x9f]/.test(value)) return false
  return /^https:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?([\/?#]|$)/.test(value)
}

function safeLoginUrl(value) {
  return isSafeLoginUrl(value) ? value : ""
}

// For sinks that interpret markup and whose text format the plugin cannot
// set: the notification body is markup by spec, and the daemon decodes
// entities, keeps a tag subset and turns bare URLs into links. Swap the
// markup characters for look-alikes, so neither tags nor entities survive,
// and break "://" so no link is made from untrusted text.
function neutralizeMarkup(value, max) {
  var text = cleanText(typeof value === "string" ? value : String(value === undefined || value === null ? "" : value), max)
  return text
    .replace(/&/g, "＆")
    .replace(/</g, "‹")
    .replace(/>/g, "›")
    .replace(/:\/\//g, ":​//")
}

// `fortivpn status --json`. Bad output returns ok:false and the caller keeps
// its last state.
function parseStatus(raw) {
  var text = typeof raw === "string" ? raw.trim() : ""
  if (text === "" || text.length > MAX_RAW) return { ok: false, error: "empty or oversized status" }
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return { ok: false, error: "status is not JSON" }
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) return { ok: false, error: "status is not an object" }
  var state = typeof data.state === "string" ? data.state : ""
  if (STATES.indexOf(state) === -1) return { ok: false, error: "unknown state" }
  var up = state === "up"
  return {
    ok: true,
    state: state,
    profile: validProfile(data.profile),
    url: safeLoginUrl(data.url),
    message: cleanText(data.message, MAX_MESSAGE),
    ip: up ? validIpv4(data.ip) : "",
    since: up ? validSince(data.since) : 0
  }
}

// A dotted IPv4 address, or "" for anything else.
function validIpv4(value) {
  if (typeof value !== "string" || !/^\d{1,3}(\.\d{1,3}){3}$/.test(value)) return ""
  var parts = value.split(".")
  for (var i = 0; i < parts.length; i++)
    if (parseInt(parts[i], 10) > 255) return ""
  return value
}

// Unix seconds the tunnel came up, or 0 for anything that is not one.
function validSince(value) {
  if (typeof value !== "number" || !isFinite(value) || value <= 0 || value >= MAX_SINCE) return 0
  return Math.floor(value)
}

// Elapsed time as h:mm:ss, or m:ss under an hour; "" when unknown.
function formatUptime(seconds) {
  if (typeof seconds !== "number" || !isFinite(seconds) || seconds < 0) return ""
  var s = Math.floor(seconds)
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var sec = s % 60
  var mm = h > 0 && m < 10 ? "0" + m : String(m)
  var ss = sec < 10 ? "0" + sec : String(sec)
  return h > 0 ? h + ":" + mm + ":" + ss : mm + ":" + ss
}

// The panel's detail line for an up tunnel: "10.0.0.42 · 1:02:03". A clock
// behind `since` shows no uptime rather than a negative one.
function tunnelDetail(ip, since, nowSec) {
  var parts = []
  var address = validIpv4(ip)
  if (address !== "") parts.push(address)
  var start = validSince(since)
  if (start > 0 && typeof nowSec === "number" && nowSec >= start) parts.push(formatUptime(nowSec - start))
  return parts.join(" · ")
}

// Whether a notice is sent: "connected" can be switched off in the widget's
// settings; failures and unexpected drops always notify.
function wantsNotice(notice, notifyOnConnect) {
  if (!notice) return false
  if (notice.kind === "connected" && notifyOnConnect === false) return false
  return true
}

// `fortivpn profiles --json`: an array of names. Invalid names are dropped,
// duplicates folded, and the list bounded.
function parseProfiles(raw) {
  var text = typeof raw === "string" ? raw.trim() : ""
  if (text === "" || text.length > MAX_RAW) return { ok: false, profiles: [] }
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return { ok: false, profiles: [] }
  }
  if (!Array.isArray(data)) return { ok: false, profiles: [] }
  var result = []
  for (var i = 0; i < data.length && result.length < MAX_PROFILES; i++) {
    var name = validProfile(data[i])
    if (name !== "" && result.indexOf(name) === -1) result.push(name)
  }
  return { ok: true, profiles: result }
}

// The list the panel shows: the CLI's profiles, plus the current one if the
// list has not caught up with it.
function displayProfiles(profiles, current) {
  var result = []
  var list = Array.isArray(profiles) ? profiles : []
  for (var i = 0; i < list.length; i++) {
    var name = validProfile(list[i])
    if (name !== "" && result.indexOf(name) === -1) result.push(name)
  }
  var active = validProfile(current)
  if (active !== "" && result.indexOf(active) === -1) result.unshift(active)
  return result
}

function initialTracker() {
  return { last: null, stickyFailed: false, failedProfile: "", failedMessage: "" }
}

// Which notification, if any, a status change deserves.
//   → up                         "connected" (also up on a different profile)
//   → failed                     "failed: <message>"; this covers an up tunnel
//                                that dropped into failed, so it is one
//                                notification rather than two
//   up → down, not expected      "disconnected"
// expectingDrop is true while the user's own Disconnect (or a switch to
// another profile) is playing out; it silences the drop it caused.
// The first status after start has nothing to compare with and is silent.
function transitionNotice(prev, next, expectingDrop) {
  if (!prev || !next) return null
  var ps = prev.state
  var ns = next.state
  if (ns === "up") {
    if (ps !== "up" || prev.profile !== next.profile) return { kind: "connected", profile: next.profile || "" }
    return null
  }
  if (ns === "failed") {
    if (ps === "failed") return null
    if (ps === "up" && expectingDrop === true) return null
    return { kind: "failed", profile: next.profile || prev.profile || "", message: next.message || "" }
  }
  if (ns === "down") {
    if (ps === "up" && expectingDrop !== true) return { kind: "disconnected", profile: prev.profile || "" }
    return null
  }
  return null
}

// Folds one parsed status into the tracker. A failure stays visible ("sticky")
// after the CLI falls back to down, until the user acts or the tunnel comes
// back up or starts connecting.
function reduceStatus(tracker, next, expectingDrop) {
  var prev = tracker || initialTracker()
  var notice = transitionNotice(prev.last, next, expectingDrop)
  var sticky = prev.stickyFailed === true
  var failedProfile = prev.failedProfile || ""
  var failedMessage = prev.failedMessage || ""
  if (next.state === "failed") {
    sticky = true
    failedProfile = next.profile || (prev.last ? prev.last.profile : "") || failedProfile
    failedMessage = next.message || ""
  } else if (next.state === "up" || next.state === "connecting") {
    sticky = false
    failedProfile = ""
    failedMessage = ""
  }
  return {
    tracker: { last: next, stickyFailed: sticky, failedProfile: failedProfile, failedMessage: failedMessage },
    notice: notice
  }
}

// The user acted (up or down): the red icon has served its purpose.
function acknowledgeFailure(tracker) {
  var prev = tracker || initialTracker()
  return { last: prev.last, stickyFailed: false, failedProfile: "", failedMessage: "" }
}

// The state the widget shows: "missing" when the CLI is not installed, and
// "failed" while a failure is sticky.
function displayState(installed, tracker) {
  if (installed !== true) return "missing"
  var t = tracker || initialTracker()
  var state = t.last ? t.last.state : "down"
  if (state === "down" && t.stickyFailed === true) return "failed"
  return state
}

function displayProfile(tracker) {
  var t = tracker || initialTracker()
  var current = t.last ? t.last.profile : ""
  if (current === "" && displayState(true, t) === "failed") return t.failedProfile || ""
  return current || ""
}

function displayMessage(tracker) {
  var t = tracker || initialTracker()
  if (t.last && t.last.state === "failed") return t.last.message || ""
  return t.stickyFailed === true ? (t.failedMessage || "") : ""
}

// Shield in every state; color and motion carry the state.
//   tone: "dim" | "normal" | "accent" | "error"; "normal" is the color of the other bar icons
function iconSpec(state) {
  var glyph = "\uDB81\uDC98"  // U+F0498 nf-md-shield
  if (state === "up") return { glyph: glyph, tone: "normal", pulse: false }
  if (state === "connecting") return { glyph: glyph, tone: "accent", pulse: true }
  if (state === "failed") return { glyph: glyph, tone: "error", pulse: false }
  return { glyph: glyph, tone: "dim", pulse: false }
}

var STATE_LABELS = {
  missing: ["state.missing", "not installed"],
  down: ["state.down", "disconnected"],
  connecting: ["state.connecting", "connecting"],
  up: ["state.up", "connected"],
  failed: ["state.failed", "failed"]
}

function stateLabel(state, tr) {
  var entry = STATE_LABELS[state] || STATE_LABELS.down
  return translator(tr)(entry[0], entry[1])
}

// "VPN: work — connected" or "VPN: disconnected". The bar tooltip renders
// plain text; the profile is a validated name anyway.
function tooltipText(state, profile, tr) {
  var t = translator(tr)
  var label = stateLabel(state, tr)
  var name = validProfile(profile)
  if (name !== "" && state !== "missing") {
    return fill(t("tooltip.withProfile", "VPN: %1 — %2").replace("%2", function() { return label }), name)
  }
  return fill(t("tooltip.noProfile", "VPN: %1"), label)
}

var NOTICE_GLYPH = "\uDB81\uDC98"  // U+F0498 nf-md-shield, as on the bar

// The argv for a notice. Summary and body pass through neutralizeMarkup, as
// the daemon reads the body as markup, and "--" ends option parsing so text
// can never be taken for a flag.
function noticeArgv(notice, tr) {
  if (!notice) return []
  var t = translator(tr)
  var profile = validProfile(notice.profile)
  var summary = ""
  var body = ""
  if (notice.kind === "connected") {
    summary = profile !== "" ? fill(t("notify.connected", "VPN %1 connected"), profile) : t("notify.connectedNoProfile", "VPN connected")
  } else if (notice.kind === "failed") {
    summary = profile !== "" ? fill(t("notify.failed", "VPN %1 failed"), profile) : t("notify.failedNoProfile", "VPN failed")
    body = String(notice.message || "")
  } else if (notice.kind === "disconnected") {
    summary = profile !== "" ? fill(t("notify.disconnected", "VPN %1 disconnected"), profile) : t("notify.disconnectedNoProfile", "VPN disconnected")
  } else {
    return []
  }
  // A summary that opens with a glyph and two spaces shows that glyph in place
  // of the card's icon slot, which otherwise holds the app name's first letter.
  var argv = ["notify-send", "-a", "OpenFortiVPN", "--", NOTICE_GLYPH + "  " + neutralizeMarkup(summary, 120)]
  var safeBody = neutralizeMarkup(body, MAX_MESSAGE)
  if (safeBody !== "") argv.push(safeBody)
  return argv
}

// Poll fast while a login is in flight or an action has just been sent,
// otherwise at the configured interval.
function pollIntervalMs(state, refreshIntervalSec, fastTicks) {
  if (state === "connecting" || (typeof fastTicks === "number" && fastTicks > 0)) return FAST_POLL_MS
  var n = parseInt(String(refreshIntervalSec), 10)
  if (!isFinite(n)) n = 15
  if (n < 5) n = 5
  if (n > 3600) n = 3600
  return n * 1000
}

// Single-quote for bash; the floating terminal launcher runs its argument
// through `bash -c`.
function shellQuote(value) {
  return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'"
}

function logArgv(cli) {
  if (!cli) return []
  return ["omarchy-launch-floating-terminal-with-presentation", shellQuote(cli) + " log"]
}

function browserArgv(url) {
  return isSafeLoginUrl(url) ? ["omarchy-launch-browser", url] : []
}

if (typeof module !== "undefined") {
  module.exports = {
    STATES: STATES,
    MAX_MESSAGE: MAX_MESSAGE,
    MAX_PROFILE: MAX_PROFILE,
    FAST_POLL_MS: FAST_POLL_MS,
    cliPath: cliPath,
    validProfile: validProfile,
    cleanText: cleanText,
    isSafeLoginUrl: isSafeLoginUrl,
    safeLoginUrl: safeLoginUrl,
    neutralizeMarkup: neutralizeMarkup,
    parseStatus: parseStatus,
    validIpv4: validIpv4,
    validSince: validSince,
    formatUptime: formatUptime,
    tunnelDetail: tunnelDetail,
    wantsNotice: wantsNotice,
    parseProfiles: parseProfiles,
    displayProfiles: displayProfiles,
    initialTracker: initialTracker,
    transitionNotice: transitionNotice,
    reduceStatus: reduceStatus,
    acknowledgeFailure: acknowledgeFailure,
    displayState: displayState,
    displayProfile: displayProfile,
    displayMessage: displayMessage,
    iconSpec: iconSpec,
    stateLabel: stateLabel,
    tooltipText: tooltipText,
    noticeArgv: noticeArgv,
    pollIntervalMs: pollIntervalMs,
    shellQuote: shellQuote,
    logArgv: logArgv,
    browserArgv: browserArgv
  }
}
