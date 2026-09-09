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
// on screen matches the one on the desk. Workspaces are chips you drag from one
// monitor to another; whatever is left over sits in the unassigned tray and
// falls back to Hyprland's default placement.
//
// Nothing is written until Apply. The whole layout then goes out in a single
// `omarchy-workspaces set-layout` call, so a half-applied arrangement is not a
// state this can leave behind.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "kimm-stensborg.workspaces"
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/workspaces.json"

  property bool opened: false

  // Working copy, discarded on cancel. Keyed by live output name, because that
  // is what the stage draws and what the CLI translates back into a stable
  // desc: selector on save.
  property var assignments: ({})
  property var unassigned: []
  property string profileName: ""
  property string showMode: "own"
  property string initialShowMode: "own"
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
    root.opened = true
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
  onConfigChanged: if (root.opened && !root.dirty) root.reloadFromDisk()

  // Same story for shell.json, which decides where the mode toggle starts.
  onShellConfigChanged: {
    if (!root.opened || root.dirty) return
    root.showMode = root.currentShowMode()
    root.initialShowMode = root.showMode
  }

  function parseConfig(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      return parsed && parsed.version === 1 && Array.isArray(parsed.profiles) ? parsed : null
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

  readonly property var monitors: root.opened ? monitorList() : []

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

  // Build the working copy: the first fully-connected profile, translated from
  // stable selectors into the output names the stage draws.
  function reloadFromDisk() {
    var candidates = monitorList()
    var next = ({})
    var taken = []
    root.profileName = ""

    var profiles = root.config ? root.config.profiles : []
    for (var p = 0; p < profiles.length; p++) {
      var entries = profiles[p].monitors || {}
      var resolved = ({})
      var complete = true
      for (var selector in entries) {
        var name = root.resolveSelector(selector, candidates)
        if (!name) { complete = false; break }
        resolved[name] = (entries[selector] || []).slice()
      }
      if (complete) {
        next = resolved
        root.profileName = String(profiles[p].name || "")
        break
      }
    }

    for (var m = 0; m < candidates.length; m++) {
      if (!next[candidates[m].name]) next[candidates[m].name] = []
      next[candidates[m].name].sort(function (a, b) { return a - b })
      taken = taken.concat(next[candidates[m].name])
    }

    var left = []
    for (var id = 1; id <= 10; id++) if (taken.indexOf(id) === -1) left.push(id)

    root.assignments = next
    root.unassigned = left
    root.showMode = root.currentShowMode()
    root.initialShowMode = root.showMode
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

  function currentShowMode() {
    var bar = root.shellConfig ? root.shellConfig.bar : null
    var layout = bar && bar.layout ? bar.layout : null
    if (!layout) return "own"
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = layout[sections[s]] || []
      for (var i = 0; i < entries.length; i++) {
        if (entries[i] && entries[i].id === root.pluginId)
          return entries[i].show === "all" ? "all" : "own"
      }
    }
    return "own"
  }

  // ── editing ───────────────────────────────────────────────────────────────

  // A workspace belongs to exactly one place, so a move is always a remove from
  // everywhere followed by a single insert.
  function moveWorkspace(id, targetName) {
    var next = ({})
    for (var name in root.assignments) {
      next[name] = root.assignments[name].filter(function (value) { return value !== id })
    }
    var left = root.unassigned.filter(function (value) { return value !== id })

    if (targetName === "") left.push(id)
    else if (next[targetName]) next[targetName].push(id)
    else return

    for (var key in next) next[key].sort(function (a, b) { return a - b })
    left.sort(function (a, b) { return a - b })

    root.assignments = next
    root.unassigned = left
    root.dirty = true
  }

  // Click, rather than drag, walks a workspace to the next monitor. Same result
  // as a drag for the common "just move it one over" case, and it keeps the
  // editor usable from the number keys alone.
  function cycleWorkspace(id) {
    var order = root.monitors.map(function (monitor) { return monitor.name }).concat([""])
    var current = ""
    for (var name in root.assignments) {
      if (root.assignments[name].indexOf(id) !== -1) { current = name; break }
    }
    root.moveWorkspace(id, order[(order.indexOf(current) + 1) % order.length])
  }

  function spread() {
    var candidates = root.monitors
    if (candidates.length === 0) return
    var next = ({})
    for (var m = 0; m < candidates.length; m++) next[candidates[m].name] = []
    for (var id = 1; id <= 10; id++) {
      next[candidates[Math.floor((id - 1) * candidates.length / 10)].name].push(id)
    }
    root.assignments = next
    root.unassigned = []
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
    var command = "omarchy-workspaces set-layout --base64 "
      + Qt.btoa(JSON.stringify(payload)) + " --quiet"
    if (root.showMode !== root.initialShowMode)
      command += " && omarchy-workspaces show " + root.showMode + " --quiet"
    command += " && omarchy-workspaces apply --quiet"

    Quickshell.execDetached(["bash", "-lc", command])

    root.dismiss()
  }

  // ── stage geometry ────────────────────────────────────────────────────────

  readonly property real deskLeft: {
    var value = 0
    for (var i = 0; i < monitors.length; i++)
      value = i === 0 ? monitors[i].x : Math.min(value, monitors[i].x)
    return value
  }
  readonly property real deskTop: {
    var value = 0
    for (var i = 0; i < monitors.length; i++)
      value = i === 0 ? monitors[i].y : Math.min(value, monitors[i].y)
    return value
  }
  readonly property real deskWidth: {
    var value = 1
    for (var i = 0; i < monitors.length; i++)
      value = Math.max(value, monitors[i].x + monitors[i].width - deskLeft)
    return value
  }
  readonly property real deskHeight: {
    var value = 1
    for (var i = 0; i < monitors.length; i++)
      value = Math.max(value, monitors[i].y + monitors[i].height - deskTop)
    return value
  }

  // ── drag state ────────────────────────────────────────────────────────────
  //
  // Chips are never reparented while dragging. A ghost follows the cursor and
  // the drop target is hit-tested on release, which keeps the Flow layouts
  // still and makes "what is under the pointer" one obvious calculation.

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
    var trayPoint = tray.mapFromGlobal(globalX, globalY)
    root.hoverTarget = ""
    root.hoverValid = trayPoint.x >= 0 && trayPoint.y >= 0
      && trayPoint.x <= tray.width && trayPoint.y <= tray.height
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
          } else if (event.text >= "0" && event.text <= "9" && event.text.length === 1) {
            root.cycleWorkspace(event.text === "0" ? 10 : parseInt(event.text))
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
          height: Math.max(titles.implicitHeight, modeToggle.implicitHeight)

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
                ? "Drag a workspace onto a monitor, or click one to send it to the next."
                : "Only one monitor is connected, so everything lives here."
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
              elide: Text.ElideRight
            }
          }

          // Which workspaces each monitor's bar draws. One setting for the
          // widget, not one per monitor — there is a single widget entry in
          // shell.json and every bar surface reads it.
          Row {
            id: modeToggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.hairline

            Repeater {
              model: [
                { key: "own", label: "This monitor" },
                { key: "all", label: "All monitors" }
              ]

              Rectangle {
                required property var modelData
                readonly property bool active: root.showMode === modelData.key

                width: modeLabel.implicitWidth + Style.spacing.controlPaddingX * 2
                height: Style.spacing.controlHeight
                radius: Style.cornerRadius
                color: active ? Style.selectedFill : (modeHover.hovered ? Style.hoverFill : "transparent")
                border.width: 1
                border.color: active ? root.accent : root.hairline

                Text {
                  id: modeLabel
                  anchors.centerIn: parent
                  text: modelData.label
                  color: parent.active ? root.accent : root.foreground
                  opacity: parent.active ? 1 : 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  textFormat: Text.PlainText
                }

                HoverHandler { id: modeHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                  onTapped: {
                    root.showMode = modelData.key
                    root.dirty = true
                  }
                }
              }
            }
          }
        }

        // ── the desk ────────────────────────────────────────────────────────
        Item {
          id: stage
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
            model: root.monitors

            Rectangle {
              id: screenCard
              required property var modelData

              readonly property string monitorName: modelData.name
              readonly property bool targeted: root.dragging && root.hoverValid
                && root.hoverTarget === monitorName

              x: stage.offsetX + (modelData.x - root.deskLeft) * stage.scaleFactor
              y: stage.offsetY + (modelData.y - root.deskTop) * stage.scaleFactor
              width: Math.max(Style.space(96), modelData.width * stage.scaleFactor)
              height: Math.max(Style.space(84), modelData.height * stage.scaleFactor)

              radius: Style.cornerRadius
              color: targeted ? Style.selectedFill : Style.normalFill
              border.width: targeted ? 2 : 1
              border.color: targeted ? root.accent : root.hairline

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

        // ── unassigned tray ─────────────────────────────────────────────────
        Rectangle {
          id: tray
          width: parent.width
          height: Math.max(Style.space(54), trayRow.implicitHeight + Style.spacing.md * 2)
          radius: Style.cornerRadius
          readonly property bool targeted: root.dragging && root.hoverValid && root.hoverTarget === ""
          color: targeted ? Style.selectedFill : "transparent"
          border.width: 1
          border.color: targeted ? root.accent
            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

          Row {
            id: trayRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.md
            anchors.rightMargin: Style.spacing.md
            spacing: Style.spacing.md

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.unassigned.length > 0
                ? "Unpinned — Hyprland places these wherever you are"
                : "Unpinned — drop a workspace here to let it roam"
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            Repeater {
              model: root.unassigned
              WorkspaceChip { ui: root; muted: true }
            }
          }
        }

        // ── footer ──────────────────────────────────────────────────────────
        Item {
          width: parent.width
          height: Style.spacing.controlHeight

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.profileName
              ? "Profile: " + root.profileName
              : "No profile matches the connected monitors"
            color: root.foreground
            opacity: 0.5
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.controlGap

            OverlayButton { ui: root; label: "Spread evenly"; onActivated: root.spread() }
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
            text: root.dragId === 10 ? "0" : String(root.dragId)
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

    width: ui.chipSize
    height: ui.chipSize
    radius: Style.cornerRadius
    color: chipHover.hovered || lifted ? Style.hoverFill : Style.normalFill
    border.width: 1
    border.color: Qt.rgba(ui.foreground.r, ui.foreground.g, ui.foreground.b, lifted ? 0.1 : 0.3)
    opacity: lifted ? 0.3 : (muted ? 0.65 : 1)

    Text {
      anchors.centerIn: parent
      text: chip.modelData === 10 ? "0" : String(chip.modelData)
      color: chip.ui.foreground
      font.family: chip.ui.fontFamily
      font.pixelSize: Style.font.subtitle
      textFormat: Text.PlainText
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
          chip.ui.cycleWorkspace(chip.modelData)
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
