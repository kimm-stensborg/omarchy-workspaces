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
  property bool hideEmpty: false
  property bool initialHideEmpty: false
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

  function open(payloadJson) {
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
    if (root.opened && !root.dirty) {
      root.reloadFromDisk()
      root.spreadIfUnassigned()
    }
  }

  // Same story for shell.json, which decides where the mode toggle starts.
  onShellConfigChanged: {
    if (!root.opened || root.dirty) return
    root.hideEmpty = root.currentHideEmpty()
    root.initialHideEmpty = root.hideEmpty
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
    root.hideEmpty = root.currentHideEmpty()
    root.initialHideEmpty = root.hideEmpty
    root.dirty = false
  }

  // The widget's own inline setting, read straight off shell.json. The host
  // hands plugins a bar-config snapshot too, but reading the file keeps the
  // toggle honest regardless of what that snapshot chooses to expose.
  property var shellConfig: null

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.shellConfig = JSON.parse(String(text() || "")) }
      catch (error) { root.shellConfig = null }
    }
    onLoadFailed: root.shellConfig = null
  }

  function currentHideEmpty() {
    var bar = root.shellConfig ? root.shellConfig.bar : null
    var layout = bar && bar.layout ? bar.layout : null
    if (!layout) return false
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = layout[sections[s]] || []
      for (var i = 0; i < entries.length; i++) {
        if (entries[i] && entries[i].id === root.pluginId)
          return entries[i].hideEmpty === true
      }
    }
    return false
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
    // `hideEmpty` lives on this widget's entry in shell.json, which belongs to
    // the shell, not to this plugin. `omarchy bar set` is the supported way in;
    // hand-editing that file from here was one more owner of somebody else's
    // state, which is the thing that has bitten this plugin every time.
    if (root.hideEmpty !== root.initialHideEmpty)
      command += " && omarchy bar set " + Util.shellQuote(root.pluginId)
        + " hideEmpty " + (root.hideEmpty ? "true" : "false") + " --json"
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
    visible: root.opened
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
          } else if (event.text === "h" || event.text === "H") {
            root.hideEmpty = !root.hideEmpty
            root.dirty = true
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
        Item {
          width: parent.width
          height: Math.max(titles.implicitHeight, modeToggle.height)

          Column {
            id: titles
            anchors.left: parent.left
            anchors.right: modeToggle.left
            anchors.rightMargin: Style.spacing.panelGap
            anchors.verticalCenter: parent.verticalCenter
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

          // Each bar always draws its own monitor's workspaces. This decides
          // whether it draws all of them or only the ones in use.
          Rectangle {
            id: modeToggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: toggleRow.implicitWidth + Style.spacing.controlPaddingX * 2
            height: Style.spacing.controlHeight
            radius: Style.cornerRadius
            color: root.hideEmpty ? Style.selectedFill
              : (toggleHover.hovered ? Style.hoverFill : "transparent")
            border.width: 1
            border.color: root.hideEmpty ? root.accent : root.hairline

            Row {
              id: toggleRow
              anchors.centerIn: parent
              spacing: Style.spacing.sm

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.hideEmpty ? "\u2713" : "\u00b7"
                color: root.hideEmpty ? root.accent : root.foreground
                opacity: root.hideEmpty ? 1 : 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Hide empty"
                color: root.hideEmpty ? root.accent : root.foreground
                opacity: root.hideEmpty ? 1 : 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
              }
            }

            HoverHandler { id: toggleHover; cursorShape: Qt.PointingHandCursor }
            TapHandler {
              onTapped: {
                root.hideEmpty = !root.hideEmpty
                root.dirty = true
              }
            }
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
