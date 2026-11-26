import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// OpenFortiVPN bar widget: a shield in the bar and a keyboard panel with the
// tunnel state and the profiles. Every action goes through the `fortivpn`
// CLI (see Service.qml). Text from the CLI is untrusted: every Text here is
// PlainText, and notifications go through Model.neutralizeMarkup.
Panel {
  id: root
  moduleName: "sergey-frv.openfortivpn"
  ipcTarget: "sergey-frv.openfortivpn"
  manageIpc: false

  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null

  // Cursor over a flat list: the state actions first (login link, log),
  // then the profile rows.
  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barDim: Qt.darker(barForeground, 1.55)
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Commons.Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Commons.Color.accent) : "transparent"

  readonly property string viewState: vpn.displayState
  readonly property string stateText: Model.stateLabel(viewState, catalog.t)
  readonly property bool canDisconnect: vpn.installed && (viewState === "up" || viewState === "connecting" || viewState === "failed")
  readonly property var actionItems: {
    var items = []
    if (!vpn.installed) return items
    if (viewState === "connecting" && vpn.loginUrl !== "") items.push("login")
    if (viewState === "failed") items.push("log")
    return items
  }
  readonly property var profileItems: vpn.installed ? Model.displayProfiles(vpn.profiles, vpn.profile) : []
  readonly property int navCount: actionItems.length + profileItems.length

  Commons.Translations {
    id: catalog
    directory: Qt.resolvedUrl("i18n")
  }

  function ensureCursor() {
    if (cursorIndex >= navCount) cursorIndex = Math.max(0, navCount - 1)
    if (cursorIndex < 0) cursorIndex = 0
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (navCount === 0) return
    if (dy !== 0) cursorIndex = Math.max(0, Math.min(navCount - 1, cursorIndex + (dy > 0 ? 1 : -1)))
    ensureCursor()
    scrollCursorIntoView()
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = index
  }

  function activateIndex(index) {
    if (index < 0 || index >= navCount) return
    var action = index < actionItems.length ? actionItems[index] : ""
    if (action === "login") vpn.openLoginUrl()
    else if (action === "log") openLog()
    else chooseProfile(profileItems[index - actionItems.length])
  }

  function activateCursor() {
    ensureCursor()
    activateIndex(cursorIndex)
  }

  // Clicking the profile that is already up or connecting does nothing; the
  // row's Disconnect button is the way out. A failed profile is retried.
  function chooseProfile(name) {
    var target = Model.validProfile(name)
    if (target === "") return
    if (target === vpn.profile && (viewState === "up" || viewState === "connecting")) return
    vpn.up(target)
  }

  function disconnect() {
    if (canDisconnect) vpn.down()
  }

  // The log opens in a terminal, so get the panel out of the way.
  function openLog() {
    vpn.openLog()
    close()
  }

  function scrollCursorIntoView() {
    if (!panelFlick || !panel.loadedContent) return
    var column = panel.loadedContent.navColumn
    var item = null
    if (cursorIndex < actionItems.length) item = panel.loadedContent.actionRow
    else if (column && cursorIndex - actionItems.length < column.children.length) item = column.children[cursorIndex - actionItems.length]
    if (!item) return
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    vpn.refresh()
    vpn.refreshProfiles()
    vpn.refreshPublicIp(false)
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }
  onNavCountChanged: ensureCursor()

  // The plugin's service, which the shell creates once for all bars. Until it
  // exists the panel reads pendingService: nothing installed yet, every action
  // a no-op.
  readonly property var liveService: bar && bar.shell ? bar.shell.serviceFor("sergey-frv.openfortivpn") : null
  readonly property var vpn: liveService || pendingService

  QtObject {
    id: pendingService
    readonly property string displayState: "down"
    readonly property bool installed: false
    readonly property bool installChecked: false
    readonly property string loginUrl: ""
    readonly property var profiles: []
    readonly property string profile: ""
    readonly property string lastError: ""
    readonly property string message: ""
    readonly property string statusText: "down"
    readonly property string tunnelIp: ""
    readonly property int tunnelSince: 0
    function refresh() {}
    function refreshProfiles() {}
    function up(name) {}
    function down() {}
    function openLoginUrl() {}
    function openLog() {}
    function copyIp() { return false }
    readonly property bool publicIpLookup: false
    readonly property string publicIp: ""
    readonly property bool publicIpChecked: false
    function refreshPublicIp(force) {}
    function copyPublicIp() { return false }
  }

  // Which address chip reads "Copied" for a moment after a copy: "vpn",
  // "public" or "".
  property string copiedAddress: ""
  Timer {
    id: copiedTimer
    interval: 1500
    onTriggered: root.copiedAddress = ""
  }

  function markCopied(which) {
    root.copiedAddress = which
    copiedTimer.restart()
  }

  function copyIp() {
    if (vpn.copyIp()) markCopied("vpn")
  }

  function copyPublicIp() {
    if (vpn.copyPublicIp()) markCopied("public")
  }

  // Wall clock for the uptime in the header, ticking only while it is on screen.
  property real nowSec: Date.now() / 1000
  Timer {
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.opened && root.viewState === "up"
    onTriggered: root.nowSec = Date.now() / 1000
  }

  Binding {
    target: root.liveService
    property: "settings"
    value: root.settings
    when: root.liveService !== null
  }

  Commons.ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { vpn.refresh(); vpn.refreshProfiles(); return "ok" }
    function down(): string { vpn.down(); return "ok" }
    function status(): string { return vpn.statusText }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: Model.tooltipText(root.viewState, vpn.profile, catalog.t)
    iconComponent: Component {
      Item {
        ShieldIcon {
          x: (parent.width - width) / 2
          y: (parent.height - height) / 2
          iconSize: button.iconSize
          fontFamily: root.fontFamily
          vpnState: root.viewState
          dimColor: root.barDim
          normalColor: root.barForeground
          accentColor: root.accent
          errorColor: root.urgent
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) {
        vpn.refresh()
        vpn.refreshProfiles()
      } else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(520))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      property alias navColumn: profileColumn
      property alias actionRow: actionRow
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "d" || t === "D") root.disconnect()
        else if (t === "r" || t === "R") { vpn.refresh(); vpn.refreshProfiles() }
        else if ((t === "o" || t === "O") && root.actionItems.indexOf("login") !== -1) vpn.openLoginUrl()
        else if ((t === "l" || t === "L") && vpn.installed) root.openLog()
        else if (t === "c" || t === "C") root.copyIp()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: vpn.profile !== "" ? vpn.profile : "OpenFortiVPN"
            meta: root.stateText
            // Uptime and address share the trailing slot, so they sit on one
            // line: the hero's own detail pill rides the title row instead.
            trailingControl: Component {
              Row {
                visible: root.viewState === "up" && (uptimeText.text !== "" || vpn.tunnelIp !== "")
                spacing: Style.space(6)

                // No border: only the address is a control. Same padding as
                // the address chip, so both texts share a line.
                Item {
                  visible: uptimeText.text !== ""
                  implicitWidth: uptimeText.implicitWidth + Style.space(10)
                  implicitHeight: uptimeText.implicitHeight + Style.space(4)

                  Text {
                    id: uptimeText
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: root.viewState === "up" ? Model.uptimeText(vpn.tunnelSince, root.nowSec) : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }

                AddressChip {
                  visible: vpn.tunnelIp !== ""
                  address: vpn.tunnelIp
                  copied: root.copiedAddress === "vpn"
                  tooltip: catalog.t("panel.copyIp")
                  onActivated: root.copyIp()
                }
              }
            }
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.viewState === "down" || root.viewState === "missing" ? 0.5 : 1.0
            iconComponent: Component {
              ShieldIcon {
                iconSize: Style.font.display
                fontFamily: root.fontFamily
                vpnState: root.viewState
                dimColor: root.dim
                normalColor: root.foreground
                accentColor: root.accent
                errorColor: root.urgent
              }
            }
          }

          // The address the internet sees while the tunnel is up.
          RowLayout {
            visible: root.viewState === "up" && vpn.publicIpLookup
            width: parent.width
            spacing: Style.space(8)

            PlainLabel {
              text: catalog.t("panel.publicIp")
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
            }

            PlainLabel {
              visible: vpn.publicIp === ""
              text: vpn.publicIpChecked ? catalog.t("panel.publicIpUnknown") : "…"
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              Layout.alignment: Qt.AlignVCenter
            }

            AddressChip {
              visible: vpn.publicIp !== ""
              address: vpn.publicIp
              copied: root.copiedAddress === "public"
              tooltip: catalog.t("panel.copyPublicIp")
              onActivated: root.copyPublicIp()
              Layout.alignment: Qt.AlignVCenter
            }
          }

          CursorSurface {
            visible: vpn.installChecked && !vpn.installed
            width: parent.width
            implicitHeight: missingText.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            PlainLabel {
              id: missingText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              text: catalog.t("panel.notInstalled")
              color: root.dim
              wrapMode: Text.WordWrap
            }
          }

          PlainLabel {
            visible: vpn.installed && vpn.lastError !== ""
            width: parent.width
            text: catalog.t("panel.statusFailed").arg(vpn.lastError)
            color: root.urgent
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PlainLabel {
            visible: vpn.installed && root.viewState === "connecting"
            width: parent.width
            text: catalog.t("panel.waitingLogin")
            color: root.dim
            wrapMode: Text.WordWrap
          }

          PlainLabel {
            visible: vpn.installed && root.viewState === "failed" && vpn.message !== ""
            width: parent.width
            text: vpn.message
            color: root.urgent
            wrapMode: Text.WordWrap
            maximumLineCount: 6
            elide: Text.ElideRight
          }

          Row {
            id: actionRow
            visible: root.actionItems.length > 0
            spacing: Style.space(8)

            Button {
              visible: root.actionItems.indexOf("login") !== -1
              text: catalog.t("panel.openLogin")
              iconText: "󰌆"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.cursorIndex === root.actionItems.indexOf("login")
              onHovered: function(on) { if (on) root.setCursor(root.actionItems.indexOf("login")) }
              onClicked: vpn.openLoginUrl()
            }

            Button {
              visible: root.actionItems.indexOf("log") !== -1
              text: catalog.t("panel.log")
              iconText: "󰈙"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              hasCursor: root.cursorActive && root.cursorIndex === root.actionItems.indexOf("log")
              onHovered: function(on) { if (on) root.setCursor(root.actionItems.indexOf("log")) }
              onClicked: root.openLog()
            }
          }

          PanelSeparator {
            visible: vpn.installed
            foreground: root.foreground
          }

          Column {
            visible: vpn.installed
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: catalog.t("panel.profiles")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            PlainLabel {
              visible: root.profileItems.length === 0
              width: parent.width
              text: catalog.t("panel.noProfiles")
              color: root.dim
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: profileColumn
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.profileItems
                ProfileRow {
                  required property var modelData
                  required property int index
                  width: profileColumn.width
                  name: String(modelData)
                  rowIndex: root.actionItems.length + index
                }
              }
            }
          }
        }
      }
    }
  }

  // A Text that never promotes itself to rich text.
  component PlainLabel: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  component ProfileRow: CursorSurface {
    id: profileRow
    property string name: ""
    property int rowIndex: 0
    readonly property bool activeProfile: name !== "" && name === vpn.profile && root.viewState !== "down"
    readonly property bool connected: activeProfile && root.viewState === "up"
    readonly property bool connecting: activeProfile && root.viewState === "connecting"
    readonly property bool failed: activeProfile && root.viewState === "failed"

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    current: connected
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill

    implicitHeight: Math.max(rowInner.implicitHeight, disconnectButton.visible ? disconnectButton.implicitHeight : 0) + Style.spacing.xl

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(profileRow.rowIndex)
      onClicked: root.chooseProfile(profileRow.name)
    }

    RowLayout {
      id: rowInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      PlainLabel {
        text: profileRow.connected ? "󰄬" : (profileRow.failed ? "󰀦" : "󰒙")
        color: profileRow.connected || profileRow.connecting ? root.accent : (profileRow.failed ? root.urgent : root.dim)
        horizontalAlignment: Text.AlignHCenter
        Layout.preferredWidth: Style.space(22)
        Layout.alignment: Qt.AlignVCenter
      }

      PlainLabel {
        text: profileRow.name
        font.bold: profileRow.connected
        elide: Text.ElideRight
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
      }

      PlainLabel {
        visible: profileRow.connecting || profileRow.failed
        text: root.stateText
        color: profileRow.failed ? root.urgent : root.dim
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }

      Button {
        id: disconnectButton
        visible: profileRow.activeProfile && root.canDisconnect
        text: catalog.t("panel.disconnect")
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        bordered: true
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.disconnect()
      }
    }

    PanelToolTip {
      visible: rowMouse.containsMouse && !profileRow.activeProfile
      text: catalog.t("panel.connect")
      fontFamily: root.fontFamily
    }
  }

  // An address that copies itself on click, as the address in Omarchy's
  // network panel does; reads "Copied" while `copied` is set.
  component AddressChip: BorderSurface {
    id: chip
    property string address: ""
    property bool copied: false
    property string tooltip: ""
    signal activated()

    implicitWidth: chipText.implicitWidth + Style.space(10)
    implicitHeight: chipText.implicitHeight + Style.space(4)
    color: chipMouse.containsMouse ? root.hoverFill : "transparent"
    borderSpec: Border.controlSpec(chipMouse.containsMouse ? "hover" : "normal", root.foreground, Commons.Color.accent)
    radius: Style.cornerRadius

    Text {
      id: chipText
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: chip.copied ? catalog.t("panel.copied") : chip.address
      color: chip.copied ? root.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.activated()
    }

    PanelToolTip {
      visible: chipMouse.containsMouse && !chip.copied && chip.tooltip !== ""
      text: chip.tooltip
      fontFamily: root.fontFamily
    }
  }
}
