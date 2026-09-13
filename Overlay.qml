import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Visual workspace-to-monitor editor.
//
// Monitors are drawn to scale in their real desktop arrangement, so the picture
// on screen matches the one on the desk. Every workspace lives on exactly one
// monitor: drag a chip to move it to another, click it to switch it off.
//
// Where the monitors themselves sit is read, never written. That belongs to
// ~/.config/hypr/monitors.lua, and an editor that rewrites someone's hand-made
// Lua is a worse idea than it sounds — see the note in the README.
//
// A workspace that is off keeps its place in the picture but gets no rule and
// no keybinding, so it cannot be reached or created at all. That is the whole
// of "off" — there is no third state where Hyprland places a workspace itself,
// because a workspace with no home is the thing this plugin exists to prevent.
//
// Nothing is written until Apply. The whole layout then goes out in a single
// `set-layout` call to the bundled CLI, so a half-applied arrangement is not a
// state this can leave behind.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "io.github.kimm-stensborg.workspaces"
  // The CLI ships inside the plugin folder rather than on PATH, so that adding
  // the plugin is the whole install. Resolve it the way the host tells us where
  // we were loaded from, and fall back to the conventional location only when
  // the manifest was not injected.
  readonly property string pluginDir: root.manifest && root.manifest.__sourceDir
    ? String(root.manifest.__sourceDir)
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.pluginId
  readonly property string cli: root.pluginDir + "/bin/omarchy-workspaces"
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/workspaces.json"

  // Omarchy binds SUPER+1..SUPER+0, so ten is how many workspaces a keyboard
  // can reach — a fact about Omarchy, not a choice here. It is why `0` labels
  // workspace 10. How many workspaces this setup *has* is `count`.
  readonly property int keySlots: 10
  readonly property int workspaceCount: {
    var n = root.config ? Number(root.config.count) : NaN
    return (isFinite(n) && n > 0) ? Math.floor(n) : root.keySlots
  }

  function keyLabel(id) {
    return id === root.keySlots ? "0" : String(id)
  }

  property bool opened: false

  // Working copy, discarded on cancel. Keyed by live output name, because that
  // is what the stage draws and what the CLI translates back into a stable
  // desc: selector on save.
  property var assignments: ({})
  // Workspace ids that are switched off. They still belong to a monitor.
  property var disabled: []

  // How many workspaces the config itself placed, counted before the gap-fill
  // below moves the leftovers onto the leftmost monitor. Without this, an
  // entirely empty layout is indistinguishable from a full one by the time
  // anything gets to look, because the fill has already placed all ten.
  property int placedByConfig: 0
  // The desk arrangement being edited, keyed by live output name. Seeded from
  // Hyprland, moved by dragging a monitor, written back as the `position` of
  // each monitor in ~/.config/hypr/monitors.lua.
  property var geometry: ({})
  property var initialGeometry: ({})
  property bool dirty: false

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color borderColor: Color.menu.border
  property color scrim: Color.menu.scrim
  property color accent: Color.accent
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  readonly property string fontFamily: Style.font.menuFamily
  readonly property color hairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.25)

  readonly property int chipSize: Math.max(Style.space(30), Style.font.subtitle * 2)

  // ── lifecycle ─────────────────────────────────────────────────────────────

  // The same overlay is two things: the editor, and the overview that the bar
  // button and the shortcut open. The payload says which, so `{}` — what every
  // existing menu entry and binding sends — still means the editor.
  property string view: "editor"

  // The overview's shortcut as the keyboard prints it ("SUPER + ½"), for the
  // editor's footer. Asked again on every open, since Plugin Manager can move
  // it at any time; empty when there is none.
  property string overviewShortcut: ""

  Process {
    id: overviewKeyProc
    command: ["bash", root.cli, "overview-key"]
    stdout: StdioCollector { onStreamFinished: root.overviewShortcut = text.trim() }
    onExited: function (code) { if (code !== 0) root.overviewShortcut = "" }
  }

  function open(payloadJson) {
    var payload = ({})
    try {
      payload = JSON.parse(String(payloadJson || "{}")) || ({})
    } catch (error) {
      console.warn(root.pluginId, "ignoring unreadable payload", payloadJson)
    }
    if (payload.view === "overview") {
      // The shortcut and the bar button summon rather than toggle, and the
      // toggling happens here, where an echo can be told from a second press.
      // An input method in the path — fcitx5's virtual keyboard, for one — can
      // deliver a single press twice, 60–200 ms apart, and a toggle in the
      // shell would open the overview and shut it again before it was seen.
      if (root.overviewShown) {
        if (Date.now() - root.overviewOpenedAt > root.echoWindow) root.dismiss()
        return
      }
      root.openOverview(String(payload.screen || ""))
      return
    }

    root.view = "editor"
    overviewKeyProc.running = true
    reloadFromDisk()
    // After `opened`, not before: `monitors` reads as empty until then, and a
    // spread across no monitors is a silent no-op.
    root.opened = true
    spreadIfUnassigned()   // no-op until the config lands; see onConfigChanged
    Qt.callLater(function () { keys.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ── config ────────────────────────────────────────────────────────────────

  property var config: null

  FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.config = root.parseConfig(text())
    onLoadFailed: root.config = null
  }

  // The file loads asynchronously, and the editor is built fresh on every
  // summon, so open() usually runs before there is anything to show. Rebuilding
  // when the config arrives covers that, and also picks up an edit made
  // elsewhere while the editor sits open — but never on top of unsaved changes.
  // The config is read asynchronously, so a freshly summoned editor runs
  // open() before it has arrived. Both paths land here, and the spread is
  // decided only once there is a config to judge — otherwise "this layout
  // assigns nothing" and "the file has not been read yet" look identical.
  onConfigChanged: {
    if (root.opened && root.view === "editor" && !root.dirty) {
      root.reloadFromDisk()
      root.spreadIfUnassigned()
    }
  }

  function parseConfig(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      return parsed && parsed.version === 1 && parsed.monitors ? parsed : null
    } catch (error) {
      console.warn(root.pluginId, "ignoring unreadable config", root.configPath, error)
      return null
    }
  }

  function monitorList() {
    var out = []
    var values = Hyprland.monitors ? Hyprland.monitors.values : []
    for (var i = 0; i < values.length; i++) {
      var monitor = values[i]
      var ipc = monitor.lastIpcObject || {}
      out.push({
        name: String(monitor.name || ""),
        description: String(monitor.description || ipc.description || ""),
        x: Number(monitor.x !== undefined ? monitor.x : ipc.x) || 0,
        y: Number(monitor.y !== undefined ? monitor.y : ipc.y) || 0,
        width: Number(monitor.width !== undefined ? monitor.width : ipc.width) || 1920,
        height: Number(monitor.height !== undefined ? monitor.height : ipc.height) || 1080
      })
    }
    out.sort(function (left, right) { return left.x - right.x })
    return out
  }

  // The desk as the editor currently believes it looks: the live monitors with
  // any in-progress arrangement laid over them.
  readonly property var monitors: {
    if (!root.opened) return []
    var live = root.monitorList()
    var out = []
    for (var i = 0; i < live.length; i++) {
      var monitor = live[i]
      var geo = root.geometry[monitor.name]
      out.push({
        name: monitor.name,
        description: monitor.description,
        x: geo ? geo.x : monitor.x,
        y: geo ? geo.y : monitor.y,
        width: monitor.width,
        height: monitor.height
      })
    }
    out.sort(function (left, right) { return (left.x - right.x) || (left.y - right.y) })
    return out
  }

  // What the stage's Repeater is actually given. `monitors` is rebuilt on every
  // pixel of a monitor drag, and handing that to a Repeater would destroy and
  // re-create the delegate out from under the pointer mid-drag. This changes
  // only when the set of monitors does; the delegates read their own position
  // out of `geometry`.
  property var stageMonitors: []

  readonly property string monitorKey: root.monitors.map(function (monitor) {
    return monitor.name + ":" + monitor.width + "x" + monitor.height
  }).join("|")

  onMonitorKeyChanged: root.syncStageMonitors()

  function syncStageMonitors() {
    root.stageMonitors = root.monitorList().map(function (monitor) {
      return { name: monitor.name, width: monitor.width, height: monitor.height }
    })
  }

  function cloneGeometry(source) {
    var out = ({})
    for (var name in source) {
      out[name] = { x: source[name].x, y: source[name].y,
                    width: source[name].width, height: source[name].height }
    }
    return out
  }

  function seedGeometry() {
    var live = root.monitorList()
    var geo = ({})
    for (var i = 0; i < live.length; i++) {
      geo[live[i].name] = { x: live[i].x, y: live[i].y,
                            width: live[i].width, height: live[i].height }
    }
    root.geometry = geo
    root.initialGeometry = root.cloneGeometry(geo)
  }


  function resolveSelector(selector, candidates) {
    if (selector.indexOf("desc:") === 0) {
      var wanted = selector.substring(5)
      for (var i = 0; i < candidates.length; i++) {
        if (candidates[i].description === wanted
            || candidates[i].description.indexOf(wanted) === 0) return candidates[i].name
      }
      return ""
    }
    for (var j = 0; j < candidates.length; j++) {
      if (candidates[j].name === selector) return candidates[j].name
    }
    return ""
  }

  // Build the working copy from the one layout on disk, translated from stable
  // selectors into the output names the stage draws.
  //
  // A monitor in the layout that is not plugged in is skipped here: the editor
  // draws the desk as it is, and the compositor reflows those workspaces onto
  // a monitor that exists. They are not lost — `set-layout` leaves untouched
  // monitors alone, so editing while undocked cannot drop them.
  function reloadFromDisk() {
    var candidates = root.monitorList()
    var next = ({})
    var taken = []

    var mons = (root.config && root.config.monitors) || ({})
    for (var selector in mons) {
      var name = root.resolveSelector(selector, candidates)
      if (!name) continue
      next[name] = (mons[selector] || []).slice()
    }

    for (var m = 0; m < candidates.length; m++) {
      if (!next[candidates[m].name]) next[candidates[m].name] = []
      next[candidates[m].name].sort(function (a, b) { return a - b })
      taken = taken.concat(next[candidates[m].name])
    }

    root.placedByConfig = taken.length

    // Every workspace has to be somewhere for the picture to be complete, so
    // anything unclaimed lands on the leftmost monitor rather than vanishing.
    if (candidates.length > 0) {
      var home = candidates[0].name
      for (var id = 1; id <= root.workspaceCount; id++) {
        if (taken.indexOf(id) === -1) next[home].push(id)
      }
      next[home].sort(function (a, b) { return a - b })
    }

    root.assignments = next
    root.disabled = ((root.config && root.config.disabled) || []).slice()
    // The stage draws monitors at their real positions, and both of these
    // rebuild that picture. Dropping them stacks every card at the origin.
    root.seedGeometry()
    root.syncStageMonitors()
    root.dirty = false
  }

  // ── editing ───────────────────────────────────────────────────────────────

  // A workspace belongs to exactly one place, so a move is always a remove from
  // everywhere followed by a single insert.
  function moveWorkspace(id, targetName) {
    if (!root.assignments[targetName]) return

    var next = ({})
    for (var name in root.assignments) {
      next[name] = root.assignments[name].filter(function (value) { return value !== id })
    }
    next[targetName].push(id)
    for (var key in next) next[key].sort(function (a, b) { return a - b })

    root.assignments = next
    root.dirty = true
  }

  function isDisabled(id) {
    return root.disabled.indexOf(id) !== -1
  }

  // Dragging is how a workspace changes monitor, so a click is free to mean
  // the other thing you want from a pill: whether the workspace exists at all.
  function toggleWorkspace(id) {
    var next = root.disabled.filter(function (value) { return value !== id })
    if (next.length === root.disabled.length) next.push(id)
    next.sort(function (a, b) { return a - b })
    root.disabled = next
    root.dirty = true
  }

  // An even spread is what a fresh config already gets from `detect`, so the
  // only time the editor needs to do it is when it opens on a layout that
  // assigns nothing at all — a hand-written config, or one whose monitors have
  // all been replaced. Then it is the difference between a usable starting
  // point and an empty picture, which is not a decision worth a button.
  function spreadIfUnassigned() {
    if (!root.config || root.placedByConfig > 0) return
    // monitorList() rather than the `monitors` binding: that one is gated on
    // `opened`, and whether it has caught up by the time open() gets here is
    // a question about binding order, not about monitors. Asking Hyprland
    // directly has no such question in it.
    root.spread(root.monitorList())
  }

  function spread(candidates) {
    if (candidates === undefined) candidates = root.monitors
    if (!candidates || candidates.length === 0) return
    var next = ({})
    for (var m = 0; m < candidates.length; m++) next[candidates[m].name] = []
    for (var id = 1; id <= root.workspaceCount; id++) {
      var slot = Math.floor((id - 1) * candidates.length / root.workspaceCount)
      next[candidates[slot].name].push(id)
    }
    root.assignments = next
    root.dirty = true
  }

  function apply() {
    var payload = ({})
    for (var name in root.assignments) {
      if (root.assignments[name].length > 0) payload[name] = root.assignments[name]
    }

    // Everything goes through the CLI, so the overlay, the TUI and a terminal
    // all write config the same single way. base64 keeps a monitor name from
    // ever being read as shell syntax.
    var run = "bash " + Util.shellQuote(root.cli) + " "
    var command = ""

    command += run + "set-layout --base64 "
      + Qt.btoa(JSON.stringify(payload))
      + " --disabled-base64 " + Qt.btoa(JSON.stringify(root.disabled)) + " --quiet"
    command += " && " + run + "apply --quiet"

    Quickshell.execDetached(["bash", "-c", command])

    root.dismiss()
  }

  // ── stage geometry ────────────────────────────────────────────────────────

  readonly property var deskBounds: {
    var list = root.monitors
    if (list.length === 0) return { left: 0, top: 0, width: 1, height: 1 }
    var left = list[0].x, top = list[0].y
    var right = list[0].x + list[0].width, bottom = list[0].y + list[0].height
    for (var i = 1; i < list.length; i++) {
      left = Math.min(left, list[i].x)
      top = Math.min(top, list[i].y)
      right = Math.max(right, list[i].x + list[i].width)
      bottom = Math.max(bottom, list[i].y + list[i].height)
    }
    return { left: left, top: top,
             width: Math.max(1, right - left), height: Math.max(1, bottom - top) }
  }

  readonly property real deskLeft: root.deskBounds.left
  readonly property real deskTop: root.deskBounds.top
  readonly property real deskWidth: root.deskBounds.width
  readonly property real deskHeight: root.deskBounds.height

  // ── rearranging the desk ──────────────────────────────────────────────────


  // Which screen is which. The editor names monitors the way Hyprland does
  // (DP-5, DP-7), and those names carry no hint about where the panel actually
  // stands on the desk — on two identical displays they can even swap between
  // boots. Identify answers it the only way that cannot be misread: by putting
  // the name on the glass.
  property bool identifying: false

  function identify() {
    root.identifying = true
    identifyTimeout.restart()
  }

  Timer {
    id: identifyTimeout
    interval: 3000
    repeat: false
    onTriggered: root.identifying = false
  }

  function monitorIndex(name) {
    for (var i = 0; i < root.monitors.length; i++) {
      if (root.monitors[i].name === String(name)) return i + 1
    }
    return 0
  }

  property bool dragging: false
  property int dragId: 0
  property real dragX: 0
  property real dragY: 0
  property bool hoverValid: false
  property string hoverTarget: ""

  function updateHover(globalX, globalY) {
    for (var i = 0; i < screens.count; i++) {
      var item = screens.itemAt(i)
      if (!item) continue
      var local = item.mapFromGlobal(globalX, globalY)
      if (local.x >= 0 && local.y >= 0 && local.x <= item.width && local.y <= item.height) {
        root.hoverTarget = item.monitorName
        root.hoverValid = true
        return
      }
    }
    // Off the monitors entirely: no drop target, so the drag is a no-op and
    // the workspace stays where it was.
    root.hoverTarget = ""
    root.hoverValid = false
  }

  // The chips call these rather than touching the card or the stage. Inline
  // QML components cannot see ids declared outside themselves, so every piece
  // of the drag that needs the surrounding scene lives here.
  function beginDrag(id) {
    root.dragId = id
    root.dragging = true
  }

  function updateDrag(globalX, globalY) {
    var cardPoint = card.mapFromGlobal(globalX, globalY)
    root.dragX = cardPoint.x
    root.dragY = cardPoint.y
    root.updateHover(globalX, globalY)
  }

  function endDrag(globalX, globalY, id) {
    root.updateHover(globalX, globalY)
    if (root.hoverValid) root.moveWorkspace(id, root.hoverTarget)
    root.cancelDrag()
  }

  function cancelDrag() {
    root.dragging = false
    root.hoverValid = false
  }

  // ── surface ───────────────────────────────────────────────────────────────

  // One label per screen, shown for a few seconds. A separate window per
  // screen rather than something drawn inside the editor, because the whole
  // point is to appear on the physical panel being named — the editor itself
  // only ever occupies one of them.
  //
  // keyboardFocus None matters: these must not take focus from the editor
  // underneath, or Esc and the number keys would stop working while they show.
  Variants {
    model: root.identifying ? Quickshell.screens : []

    PanelWindow {
      id: identifyPanel
      required property var modelData

      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "omarchy-workspaces-identify"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      // Click-through, so the editor stays usable while the labels are up.
      mask: Region {}

      Rectangle {
        anchors.centerIn: parent
        width: identifyColumn.implicitWidth + Style.spacing.panelPadding * 2
        height: identifyColumn.implicitHeight + Style.spacing.panelPadding * 2
        radius: Style.cornerRadius
        color: root.background
        border.width: Math.max(1, Style.space(2))
        border.color: root.accent

        Column {
          id: identifyColumn
          anchors.centerIn: parent
          spacing: Style.spacing.sm

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: String(root.monitorIndex(identifyPanel.modelData.name))
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle * 4
            font.bold: true
            textFormat: Text.PlainText
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: String(identifyPanel.modelData.name)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            textFormat: Text.PlainText
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: identifyPanel.modelData.width + " x " + identifyPanel.modelData.height
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
          }
        }
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened && root.view === "editor"
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-workspaces-editor"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(940), panel.width - Style.gapsOut * 4)
      height: content.implicitHeight + contentTopInset + contentBottomInset
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      // Swallow clicks so they never reach the dismiss layer underneath.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.dirty) root.apply()
            event.accepted = true
          } else if (event.text >= "0" && event.text <= "9" && event.text.length === 1) {
            root.toggleWorkspace(event.text === "0" ? 10 : parseInt(event.text))
            event.accepted = true
          }
        }
      }

      Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: Style.spacing.panelGap

        // ── header ──────────────────────────────────────────────────────────
        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          Text {
            text: "Workspaces"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            textFormat: Text.PlainText
          }
          Text {
            width: parent.width
            text: root.monitors.length > 1
              ? "Drag a workspace to another monitor. Click one to switch it off."
              : "One monitor, so everything lives here. Click a workspace to switch it off."
            color: root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
            elide: Text.ElideRight
          }
        }

        // ── the desk ────────────────────────────────────────────────────────
        Item {
          id: stage
          clip: true
          width: parent.width
          // Monitors are drawn to scale, but a very wide desk would squash the
          // chips out of existence, so the stage keeps a workable height range.
          height: Math.max(Style.space(180),
                    Math.min(Style.space(400), width * root.deskHeight / root.deskWidth))

          readonly property real scaleFactor: Math.min(width / root.deskWidth, height / root.deskHeight)
          readonly property real offsetX: (width - root.deskWidth * scaleFactor) / 2
          readonly property real offsetY: (height - root.deskHeight * scaleFactor) / 2

          Repeater {
            id: screens
            model: root.stageMonitors

            Rectangle {
              id: screenCard
              required property var modelData

              readonly property string monitorName: modelData.name
              readonly property var geo: root.geometry[monitorName]
              readonly property bool targeted: root.dragging && root.hoverValid
                && root.hoverTarget === monitorName

              x: stage.offsetX + ((geo ? geo.x : 0) - root.deskLeft) * stage.scaleFactor
              y: stage.offsetY + ((geo ? geo.y : 0) - root.deskTop) * stage.scaleFactor
              width: Math.max(Style.space(96), modelData.width * stage.scaleFactor)
              height: Math.max(Style.space(84), modelData.height * stage.scaleFactor)

              radius: Style.cornerRadius
              color: targeted ? Style.selectedFill : Style.normalFill
              border.width: targeted ? 2 : 1
              border.color: targeted ? root.accent : root.hairline

              // The number Identify puts on the glass, so the two pictures can
              // be matched up. Pointless with one screen — there is nothing to
              // tell apart — so it only appears once there are two.
              Rectangle {
                visible: root.monitors.length > 1
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: Style.spacing.sm
                width: Math.max(badge.implicitWidth + Style.spacing.sm, badge.implicitHeight + Style.spacing.xxs * 2)
                height: badge.implicitHeight + Style.spacing.xxs * 2
                radius: Style.cornerRadius
                color: "transparent"
                border.width: 1
                border.color: root.hairline

                Text {
                  id: badge
                  anchors.centerIn: parent
                  text: String(root.monitorIndex(screenCard.monitorName))
                  color: root.foreground
                  opacity: 0.55
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                }
              }

              Column {
                anchors.fill: parent
                anchors.margins: Style.spacing.md
                spacing: Style.spacing.sm

                Text {
                  width: parent.width
                  text: screenCard.modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: screenCard.modelData.width + " x " + screenCard.modelData.height
                  color: root.foreground
                  opacity: 0.45
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                }

                Flow {
                  width: parent.width
                  spacing: Style.spacing.sm

                  Repeater {
                    model: root.assignments[screenCard.monitorName] || []
                    WorkspaceChip { ui: root }
                  }
                }
              }
            }
          }
        }

        // ── footer ──────────────────────────────────────────────────────────
        Item {
          width: parent.width
          height: Style.spacing.controlHeight

          // Where the overview is, since this is where people come to set
          // things up. The shortcut is whatever it is now, not what it was
          // first bound to — Plugin Manager can move it.
          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.overviewShortcut ? "Overview" : "Overview: 󰖳 in the bar"
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            Rectangle {
              visible: root.overviewShortcut !== ""
              anchors.verticalCenter: parent.verticalCenter
              width: shortcutLabel.implicitWidth + Style.spacing.sm * 2
              height: shortcutLabel.implicitHeight + Style.spacing.xxs * 2
              radius: Style.cornerRadius
              color: Style.normalFill
              border.width: 1
              border.color: root.hairline

              Text {
                id: shortcutLabel
                anchors.centerIn: parent
                text: root.overviewShortcut
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
              }
            }

            Text {
              visible: root.overviewShortcut !== ""
              anchors.verticalCenter: parent.verticalCenter
              text: "or 󰖳 in the bar"
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.controlGap

            OverlayButton { ui: root; label: "Identify"; onActivated: root.identify() }
            OverlayButton { ui: root; label: "Cancel"; onActivated: root.dismiss() }
            OverlayButton {
              ui: root
              label: "Apply"
              primary: true
              active: root.dirty
              onActivated: root.apply()
            }
          }
        }
      }

      // The ghost that follows the cursor. Parented to the card so its
      // coordinates are the card's, and stacked above everything in it.
      Loader {
        active: root.dragging && root.opened
        z: 100

        sourceComponent: Rectangle {
          x: root.dragX - width / 2
          y: root.dragY - height / 2
          width: root.chipSize
          height: root.chipSize
          radius: Style.cornerRadius
          color: Style.selectedFill
          border.width: 1
          border.color: root.accent

          Text {
            anchors.centerIn: parent
            text: root.keyLabel(root.dragId)
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            textFormat: Text.PlainText
          }
        }
      }
    }
  }

  // ── the overview ──────────────────────────────────────────────────────────
  //
  // Every workspace at once, full screen, on the monitor you are looking at:
  // one row per monitor, a tile per workspace, and in each tile its windows
  // where they really sit, as live thumbnails. Click one, or press its number,
  // and you are there.
  //
  // It draws what Hyprland has rather than what the config asks for. The two
  // agree once the rules have settled, and when they do not, a picture you
  // navigate by has to show where things are, not where they should be.

  readonly property bool overviewShown: root.opened && root.view === "overview"

  // A PanelWindow takes a Quickshell screen, not an output name, so the name
  // is resolved once at open time.
  property var overviewScreen: null
  property int overviewSelected: 0

  // When the overview last opened, and how long after that a summon counts
  // as the same press arriving twice rather than a second press. A quick tap
  // is well under this; two deliberate presses are well over it.
  property real overviewOpenedAt: 0
  readonly property int echoWindow: 400

  function screenFor(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var hypr = typeof Hyprland.monitorFor === "function" ? Hyprland.monitorFor(screens[i]) : null
      var candidate = hypr && hypr.name ? String(hypr.name) : String(screens[i].name || "")
      if (candidate === name) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  // The bar button says which screen it was clicked on. A key says nothing,
  // and then the focused monitor is the one you are looking at.
  function openOverview(screenName) {
    // Window positions come from Hyprland's last report, which can be as old
    // as the last event the shell happened to receive. Asking again is cheap,
    // and the tiles move into place when the answer lands.
    Hyprland.refreshMonitors()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()

    var name = screenName
      || (Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : "")
    root.overviewScreen = root.screenFor(name)
    root.overviewSelected = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 0
    root.overviewOpenedAt = Date.now()
    root.view = "overview"
    root.opened = true
    Qt.callLater(function () { overviewKeys.forceActiveFocus() })
  }

  // A monitor's size in the units Hyprland positions windows in: the mode
  // divided by the scale, turned on its side for a rotated panel. Measured in
  // mode pixels instead, a scaled screen would draw its windows too small and
  // in the wrong place.
  function logicalSize(monitor) {
    var ipc = monitor.lastIpcObject || {}
    var scale = Number(monitor.scale || ipc.scale) || 1
    var width = (Number(monitor.width) || 1920) / scale
    var height = (Number(monitor.height) || 1080) / scale
    return (Number(ipc.transform) || 0) % 2 === 1
      ? { width: height, height: width }
      : { width: width, height: height }
  }

  // One row per monitor, left to right, holding the workspaces Hyprland has
  // on it. Special workspaces (negative ids) are scratchpads, not places, and
  // a monitor with nothing on it gets no row.
  readonly property var overviewRows: {
    if (!root.overviewShown) return []
    var monitors = []
    var values = Hyprland.monitors ? Hyprland.monitors.values : []
    for (var i = 0; i < values.length; i++) monitors.push(values[i])
    monitors.sort(function (left, right) { return (left.x - right.x) || (left.y - right.y) })

    var workspaces = root.hyprWorkspaces
    var rows = []
    for (var m = 0; m < monitors.length; m++) {
      var monitor = monitors[m]
      var ids = []
      for (var w = 0; w < workspaces.length; w++) {
        var workspace = workspaces[w]
        if (workspace.id > 0 && workspace.monitor && workspace.monitor.name === monitor.name)
          ids.push(workspace.id)
      }
      if (ids.length === 0) continue
      ids.sort(function (a, b) { return a - b })
      var size = root.logicalSize(monitor)
      rows.push({ name: String(monitor.name), x: monitor.x, y: monitor.y,
                  width: size.width, height: size.height, workspaces: ids })
    }
    return rows
  }

  readonly property var hyprWorkspaces: Hyprland.workspaces ? Hyprland.workspaces.values : []

  function liveWorkspace(id) {
    var values = root.hyprWorkspaces
    for (var i = 0; i < values.length; i++) if (values[i].id === id) return values[i]
    return null
  }

  // Shown on its monitor right now, focused or not.
  function isShown(id) {
    var values = Hyprland.monitors ? Hyprland.monitors.values : []
    for (var i = 0; i < values.length; i++) {
      if (values[i].activeWorkspace && values[i].activeWorkspace.id === id) return true
    }
    return false
  }

  // Tiled windows first and floating ones over them, each group oldest-focused
  // first, so the window you used last ends up on top — as it is on screen.
  // A window hidden inside a group has no place of its own to draw.
  function windowsOn(workspace) {
    var out = []
    var values = workspace && workspace.toplevels ? workspace.toplevels.values : []
    for (var i = 0; i < values.length; i++) {
      var ipc = values[i].lastIpcObject || {}
      if (ipc.hidden || !ipc.size) continue
      out.push(values[i])
    }
    out.sort(function (left, right) {
      var a = left.lastIpcObject, b = right.lastIpcObject
      return ((a.floating ? 1 : 0) - (b.floating ? 1 : 0))
        || ((Number(b.focusHistoryID) || 0) - (Number(a.focusHistoryID) || 0))
    })
    return out
  }

  function overviewPosition(id) {
    var rows = root.overviewRows
    for (var r = 0; r < rows.length; r++) {
      var column = rows[r].workspaces.indexOf(id)
      if (column !== -1) return { row: r, column: column }
    }
    return { row: 0, column: -1 }
  }

  // Left and right run on into the next row, so every tile is reachable with
  // two keys; up and down keep the column as far as the row is long.
  function moveSelection(rowStep, columnStep) {
    var rows = root.overviewRows
    if (rows.length === 0) return
    var at = root.overviewPosition(root.overviewSelected)
    var row = at.row
    var column = at.column + columnStep
    if (column < 0 && row > 0 && columnStep !== 0) {
      row--
      column = rows[row].workspaces.length - 1
    } else if (column >= rows[row].workspaces.length && row < rows.length - 1) {
      row++
      column = 0
    }
    row = Math.max(0, Math.min(rows.length - 1, row + rowStep))
    column = Math.max(0, Math.min(rows[row].workspaces.length - 1, column))
    root.overviewSelected = rows[row].workspaces[column]
  }

  // The same dispatch the bar uses. A pinned workspace takes focus to its own
  // monitor rather than coming to this one, which is the plugin working.
  function jumpTo(id) {
    if (root.overviewPosition(id).column === -1) return
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ workspace = \"" + id + "\" })"])
    root.dismiss()
  }

  PanelWindow {
    id: overviewPanel
    visible: root.overviewShown
    screen: root.overviewScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-workspaces-overview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    readonly property real margin: Style.space(56)
    readonly property real rowGap: Style.space(28)
    readonly property real tileGap: Style.space(16)
    readonly property real labelHeight: Style.font.bodySmall * 1.5 + Style.spacing.sm
    readonly property real hintHeight: Style.font.caption * 1.5 + Style.spacing.md

    // One height for every tile, each as wide as its monitor's shape: the
    // largest that lets the rows stack and the longest row fit. Two
    // workspaces on a big screen would otherwise fill it, and past a point a
    // bigger tile is not a clearer one.
    readonly property real tileHeight: {
      var rows = root.overviewRows
      if (rows.length === 0) return 0
      var availableWidth = width - margin * 2
      var availableHeight = height - margin * 2 - hintHeight
      var best = (availableHeight - rows.length * labelHeight - (rows.length - 1) * rowGap) / rows.length
      for (var i = 0; i < rows.length; i++) {
        var count = rows[i].workspaces.length
        var aspect = rows[i].width / rows[i].height
        best = Math.min(best, (availableWidth - (count - 1) * tileGap) / (count * aspect))
      }
      return Math.max(Style.space(48), Math.min(best, availableHeight * 0.3))
    }

    // Nearly opaque, not the editor's scrim. The scrim dims a desktop you are
    // meant to still see; here the desktop behind would be read as part of
    // the picture, and every thumbnail would compete with the real windows.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.94)
    }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    Item {
      id: overviewKeys
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function (event) {
        var key = event.key
        if (key === Qt.Key_Escape) root.dismiss()
        else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space)
          root.jumpTo(root.overviewSelected)
        else if (key === Qt.Key_Left || key === Qt.Key_H) root.moveSelection(0, -1)
        else if (key === Qt.Key_Right || key === Qt.Key_L) root.moveSelection(0, 1)
        else if (key === Qt.Key_Up || key === Qt.Key_K) root.moveSelection(-1, 0)
        else if (key === Qt.Key_Down || key === Qt.Key_J) root.moveSelection(1, 0)
        else if (event.text.length === 1 && event.text >= "0" && event.text <= "9")
          root.jumpTo(event.text === "0" ? root.keySlots : parseInt(event.text))
        else return
        event.accepted = true
      }
    }

    Column {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -overviewPanel.hintHeight / 2
      spacing: overviewPanel.rowGap

      Repeater {
        model: root.overviewRows

        Column {
          id: overviewRow
          required property var modelData
          spacing: Style.spacing.sm

          Text {
            height: overviewPanel.labelHeight - Style.spacing.sm
            verticalAlignment: Text.AlignBottom
            text: overviewRow.modelData.name
            color: root.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }

          Row {
            spacing: overviewPanel.tileGap

            Repeater {
              model: overviewRow.modelData.workspaces
              WorkspaceTile {
                ui: root
                monitor: overviewRow.modelData
                height: overviewPanel.tileHeight
              }
            }
          }
        }
      }
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: overviewPanel.margin / 2
      text: "Click or press 1–0 to go there  ·  arrows and Enter  ·  Esc to close"
      color: root.foreground
      opacity: 0.45
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
    }
  }

  // ── pieces ────────────────────────────────────────────────────────────────

  component WorkspaceChip: Rectangle {
    id: chip

    // Filled by the Repeater. Declaring it required means it resolves as this
    // object's own property rather than an inherited context property, which
    // matters here: the enclosing monitor delegate has a `modelData` of its own
    // that would otherwise shadow it.
    required property int modelData

    // An inline component is its own scope and cannot see the file's root id,
    // so the host hands itself in. Every use site sets `ui: root`.
    required property var ui
    property bool muted: false

    readonly property bool lifted: ui.dragging && ui.dragId === modelData
    readonly property bool off: ui.isDisabled(modelData)

    width: ui.chipSize
    height: ui.chipSize
    radius: Style.cornerRadius
    color: off ? "transparent" : (chipHover.hovered || lifted ? Style.hoverFill : Style.normalFill)
    border.width: 1
    border.color: off
      ? Qt.rgba(ui.foreground.r, ui.foreground.g, ui.foreground.b, 0.2)
      : Qt.rgba(ui.foreground.r, ui.foreground.g, ui.foreground.b, lifted ? 0.1 : 0.3)
    opacity: lifted ? 0.3 : 1

    Text {
      anchors.centerIn: parent
      text: chip.ui.keyLabel(chip.modelData)
      color: chip.ui.foreground
      // Off has to read as off at a glance, across a row of ten. Dimming the
      // number alone is too quiet next to a filled neighbour, so the fill goes
      // too and what is left is an outline.
      opacity: chip.off ? 0.35 : 1
      font.family: chip.ui.fontFamily
      font.pixelSize: Style.font.subtitle
      textFormat: Text.PlainText
    }

    // A line through the number, so the state survives a colourblind reading
    // and a dim screen.
    Rectangle {
      visible: chip.off
      anchors.centerIn: parent
      width: parent.width * 0.52
      height: 1
      color: chip.ui.foreground
      opacity: 0.35
    }

    HoverHandler { id: chipHover; cursorShape: Qt.OpenHandCursor }

    MouseArea {
      anchors.fill: parent
      preventStealing: true

      property real pressX: 0
      property real pressY: 0
      property bool moved: false

      onPressed: function (mouse) {
        pressX = mouse.x
        pressY = mouse.y
        moved = false
      }

      onPositionChanged: function (mouse) {
        // A few pixels of slop, so a click with a shaky hand stays a click.
        if (!moved) {
          if (Math.abs(mouse.x - pressX) < 4 && Math.abs(mouse.y - pressY) < 4) return
          moved = true
          chip.ui.beginDrag(chip.modelData)
        }
        var point = chip.mapToGlobal(mouse.x, mouse.y)
        chip.ui.updateDrag(point.x, point.y)
      }

      onReleased: function (mouse) {
        if (!moved) {
          chip.ui.toggleWorkspace(chip.modelData)
          return
        }
        var point = chip.mapToGlobal(mouse.x, mouse.y)
        chip.ui.endDrag(point.x, point.y, chip.modelData)
      }

      onCanceled: chip.ui.cancelDrag()
    }
  }

  // One workspace in the overview: its monitor's shape, its windows where they
  // sit, and its number in the corner.
  component WorkspaceTile: Rectangle {
    id: tile

    required property int modelData
    required property var ui
    // The row it belongs to: the monitor's name, position and logical size.
    required property var monitor

    readonly property var workspace: ui.liveWorkspace(modelData)
    readonly property var windows: ui.windowsOn(workspace)
    readonly property bool focused: Hyprland.focusedWorkspace !== null
      && Hyprland.focusedWorkspace.id === modelData
    readonly property bool shown: ui.isShown(modelData)
    readonly property bool selected: ui.overviewSelected === modelData
    readonly property real unit: height / monitor.height

    width: height * monitor.width / monitor.height
    radius: Style.cornerRadius
    clip: true
    color: Qt.rgba(ui.foreground.r, ui.foreground.g, ui.foreground.b, tileHover.hovered ? 0.12 : 0.06)
    border.width: selected ? 2 : 1
    border.color: selected ? ui.accent
      : Qt.rgba(ui.foreground.r, ui.foreground.g, ui.foreground.b, shown ? 0.5 : 0.2)

    // An empty workspace is still a place you can go, so it keeps its number
    // where the windows would be.
    Text {
      visible: tile.windows.length === 0
      anchors.centerIn: parent
      text: tile.ui.keyLabel(tile.modelData)
      color: tile.ui.foreground
      opacity: 0.25
      font.family: tile.ui.fontFamily
      font.pixelSize: Math.max(Style.font.subtitle, tile.height * 0.3)
      textFormat: Text.PlainText
    }

    Repeater {
      model: tile.windows

      Item {
        id: shotFrame
        required property var modelData
        readonly property var ipc: modelData.lastIpcObject || ({})
        readonly property var at: ipc.at || [0, 0]
        readonly property var size: ipc.size || [0, 0]

        x: (at[0] - tile.monitor.x) * tile.unit
        y: (at[1] - tile.monitor.y) * tile.unit
        width: Math.max(1, size[0] * tile.unit)
        height: Math.max(1, size[1] * tile.unit)

        // Until the first frame arrives, and for anything that cannot be
        // captured, the window's class stands in for it.
        Rectangle {
          visible: !shot.hasContent
          anchors.fill: parent
          radius: Math.max(2, Style.cornerRadius / 2)
          color: Qt.rgba(tile.ui.foreground.r, tile.ui.foreground.g, tile.ui.foreground.b, 0.1)
          border.width: 1
          border.color: Qt.rgba(tile.ui.foreground.r, tile.ui.foreground.g, tile.ui.foreground.b, 0.2)

          Text {
            anchors.fill: parent
            anchors.margins: Style.spacing.xxs
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: String(shotFrame.ipc.class || shotFrame.modelData.title || "")
            color: tile.ui.foreground
            opacity: 0.6
            font.family: tile.ui.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
            elide: Text.ElideRight
          }
        }

        ScreencopyView {
          id: shot
          anchors.fill: parent
          captureSource: tile.ui.overviewShown ? shotFrame.modelData.wayland : null
          live: true
        }
      }
    }

    // The number, over the windows, so a full workspace is still findable.
    Rectangle {
      visible: tile.windows.length > 0
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.margins: Style.spacing.sm
      width: Math.max(number.implicitWidth + Style.spacing.sm * 2, height)
      height: number.implicitHeight + Style.spacing.xxs * 2
      radius: Style.cornerRadius
      color: tile.ui.background
      border.width: 1
      border.color: tile.focused ? tile.ui.accent : tile.ui.hairline

      Text {
        id: number
        anchors.centerIn: parent
        text: tile.ui.keyLabel(tile.modelData)
        color: tile.focused ? tile.ui.accent : tile.ui.foreground
        font.family: tile.ui.fontFamily
        font.pixelSize: Style.font.bodySmall * 2
        font.bold: true
        textFormat: Text.PlainText
      }
    }

    // Hovering selects, so the mouse and the arrow keys never disagree about
    // which tile Enter would take you to.
    HoverHandler {
      id: tileHover
      cursorShape: Qt.PointingHandCursor
      onHoveredChanged: if (hovered) tile.ui.overviewSelected = tile.modelData
    }
    TapHandler { onTapped: tile.ui.jumpTo(tile.modelData) }
  }

  component OverlayButton: Rectangle {
    id: button

    required property var ui
    property string label: ""
    property bool primary: false
    property bool active: true
    signal activated()

    width: buttonLabel.implicitWidth + Style.spacing.controlPaddingX * 2
    height: Style.spacing.controlHeight
    radius: Style.cornerRadius
    opacity: active ? 1 : 0.4
    color: primary && active ? Style.selectedFill : (buttonHover.hovered ? Style.hoverFill : "transparent")
    border.width: 1
    border.color: primary && active ? ui.accent : ui.hairline

    Text {
      id: buttonLabel
      anchors.centerIn: parent
      text: button.label
      color: button.primary && button.active ? button.ui.accent : button.ui.foreground
      font.family: button.ui.fontFamily
      font.pixelSize: Style.font.bodySmall
      textFormat: Text.PlainText
    }

    HoverHandler { id: buttonHover; enabled: button.active; cursorShape: Qt.PointingHandCursor }
    TapHandler { enabled: button.active; onTapped: button.activated() }
  }
}
