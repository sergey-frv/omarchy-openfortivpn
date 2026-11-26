import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "Model.js" as Model

// State of the tunnel as the `fortivpn` CLI reports it. Every action goes
// through the CLI by absolute path; nothing here talks to systemd. Output of
// the CLI is untrusted and is parsed and bounded in Model.js.
//
// The shell creates this service once for the plugin, while every bar draws
// its own copy of the widget (Panel.qml), so one poll and one notification
// serve all monitors.
Item {
  id: root

  // Set by the shell on creation.
  property var shell: null
  property var manifest: null

  // Settings of the bar widget, which the widget passes in.
  property var settings: ({})

  Commons.Translations {
    id: catalog
    directory: Qt.resolvedUrl("i18n")
  }
  // For notification text.
  readonly property var strings: catalog

  readonly property string cliPath: Model.cliPath(Quickshell.env("HOME"))
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 5, 3600)

  property bool installed: false
  property bool installChecked: false
  property var tracker: Model.initialTracker()
  property var profiles: []
  property string lastError: ""

  // Raw CLI state of the last good status, and what the widget shows.
  readonly property string vpnState: tracker.last ? tracker.last.state : "down"
  readonly property string displayState: installChecked ? Model.displayState(installed, tracker) : "down"
  readonly property string profile: Model.displayProfile(tracker)
  readonly property string loginUrl: tracker.last && tracker.last.state === "connecting" ? tracker.last.url : ""
  readonly property string message: Model.displayMessage(tracker)
  // Address and start time of an up tunnel; "" and 0 in every other state.
  readonly property string tunnelIp: tracker.last && tracker.last.state === "up" ? (tracker.last.ip || "") : ""
  readonly property int tunnelSince: tracker.last && tracker.last.state === "up" ? (tracker.last.since || 0) : 0
  readonly property bool notifyOnConnect: setting("notifyOnConnect", true) !== false
  readonly property bool busy: checkProcess.running || statusProcess.running || profilesProcess.running

  // Polls left at the fast rate after an action, so the state change that
  // follows is seen within seconds rather than at the next slow tick.
  property int fastPollTicks: 0
  // True while the user's own Disconnect (or a switch to another profile)
  // is playing out, so the drop it causes does not notify.
  property bool expectingDrop: false
  property bool _profilesWanted: true
  property string _statusOutput: ""
  property string _statusError: ""
  property string _profilesOutput: ""

  // English, for the IPC status() call.
  readonly property string statusText: displayState + (profile !== "" ? " " + profile : "")

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function tr(key, english) {
    return root.strings ? root.strings.t(key, english) : english
  }

  function refresh() {
    if (root.cliPath === "") {
      root.installChecked = true
      root.installed = false
      return
    }
    if (checkProcess.running || statusProcess.running) return
    // Checked on every poll, so removing the CLI flips the widget to "not
    // installed" instead of polling a missing binary.
    checkProcess.command = ["test", "-x", root.cliPath]
    checkProcess.running = true
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  function refreshProfiles() {
    if (!root.installed) {
      root._profilesWanted = true
      return
    }
    if (profilesProcess.running) return
    profilesProcess.command = [root.cliPath, "profiles", "--json"]
    profilesProcess.running = true
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  function startStatus() {
    if (statusProcess.running) return
    statusProcess.command = [root.cliPath, "status", "--json"]
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      // Keep the last good state; a garbled line is not a disconnect.
      console.warn("sergey-frv.openfortivpn", parsed.error)
      return
    }
    var prevState = root.vpnState
    var step = Model.reduceStatus(root.tracker, parsed, root.expectingDrop)
    root.tracker = step.tracker
    root.lastError = ""
    if (root.expectingDrop && parsed.state !== prevState) {
      root.expectingDrop = false
      expectDropTimer.stop()
    }
    notify(step.notice)
  }

  function notify(notice) {
    if (!Model.wantsNotice(notice, root.notifyOnConnect)) return
    var argv = Model.noticeArgv(notice, root.tr)
    if (argv.length > 0) Quickshell.execDetached(argv)
  }

  function afterAction() {
    root.fastPollTicks = 10
    delayedRefresh.restart()
  }

  function up(name) {
    var target = Model.validProfile(name)
    if (!root.installed || target === "") return
    root.expectingDrop = root.vpnState === "up" && target !== (root.tracker.last ? root.tracker.last.profile : "")
    if (root.expectingDrop) expectDropTimer.restart()
    root.tracker = Model.acknowledgeFailure(root.tracker)
    // Detached: `fortivpn up` waits for the SAML login and must outlive a
    // plugin reload.
    Quickshell.execDetached([root.cliPath, "up", target])
    afterAction()
  }

  function down() {
    if (!root.installed) return
    root.expectingDrop = root.vpnState === "up"
    if (root.expectingDrop) expectDropTimer.restart()
    root.tracker = Model.acknowledgeFailure(root.tracker)
    Quickshell.execDetached([root.cliPath, "down"])
    afterAction()
  }

  function openLoginUrl() {
    var argv = Model.browserArgv(root.loginUrl)
    if (argv.length > 0) Quickshell.execDetached(argv)
  }

  function openLog() {
    if (!root.installed) return
    var argv = Model.logArgv(root.cliPath)
    if (argv.length > 0) Quickshell.execDetached(argv)
  }

  Timer {
    id: pollTimer
    interval: Model.pollIntervalMs(root.vpnState, root.refreshIntervalSec, root.fastPollTicks)
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      if (root.fastPollTicks > 0) root.fastPollTicks -= 1
      root.refresh()
    }
  }

  Timer {
    id: delayedRefresh
    interval: 700
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    // A Disconnect that never takes effect must not silence a real drop
    // later on.
    id: expectDropTimer
    interval: 60000
    repeat: false
    onTriggered: root.expectingDrop = false
  }

  Timer {
    // Every poll is skipped while its own process still runs, so one that
    // hangs would stop the widget refreshing for good. Reap it well inside
    // the fast poll cadence's patience.
    id: pollWatchdog
    interval: 10000
    repeat: false
    onTriggered: {
      if (checkProcess.running) checkProcess.running = false
      if (statusProcess.running) statusProcess.running = false
      if (profilesProcess.running) profilesProcess.running = false
    }
  }

  Process {
    id: checkProcess
    running: false
    command: []
    onExited: function(exitCode) {
      var wasInstalled = root.installed
      root.installed = exitCode === 0
      root.installChecked = true
      if (!root.installed) {
        root.tracker = Model.initialTracker()
        root.profiles = []
        root.lastError = ""
        return
      }
      if (!wasInstalled || root._profilesWanted) {
        root._profilesWanted = false
        root.refreshProfiles()
      }
      root.startStatus()
    }
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onStarted: {
      root._statusOutput = ""
      root._statusError = ""
    }
    onExited: function(exitCode) {
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) root.applyStatus(stdout)
      else root.lastError = Model.cleanText(stderr || ("exit " + exitCode), 200)
    }
  }

  Process {
    id: profilesProcess
    running: false
    command: []
    stdout: StdioCollector { id: profilesStdout; waitForEnd: true; onStreamFinished: root._profilesOutput = text }
    onStarted: root._profilesOutput = ""
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var parsed = Model.parseProfiles(String(profilesStdout.text || root._profilesOutput || ""))
      // Bad output keeps the last list.
      if (parsed.ok) root.profiles = parsed.profiles
    }
  }
}
