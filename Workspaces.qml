import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Workspace indicators that know which monitor they are on.
//
// The stock widget renders the same list on every screen, so a three-monitor
// desk shows ten identical buttons three times over. This one reads the same
// ~/.config/omarchy/workspaces.json that generates the Hyprland workspace
// rules, so the bar on each monitor shows exactly the workspaces that monitor
// owns — and shows them whether or not they currently hold a window.
BarWidget {
  id: root
  moduleName: "io.github.kimm-stensborg.workspaces"

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/workspaces.json"

  // Omarchy binds SUPER+1..SUPER+0, so ten is how many workspaces a keyboard
  // can reach, and why `0` labels workspace 10.
  readonly property int keySlots: 10

  property var config: null

  // ── config ────────────────────────────────────────────────────────────────

  FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.config = root.parseConfig(text())
    onLoadFailed: root.config = null
  }

  function parseConfig(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      return parsed && parsed.version === 1 && parsed.monitors ? parsed : null
    } catch (error) {
      console.warn(moduleName, "ignoring unreadable config", configPath, error)
      return null
    }
  }

  // ── monitors ──────────────────────────────────────────────────────────────

  // The bar builds one surface per screen, so the window this widget lives in
  // is what tells us which monitor we are speaking for.
  readonly property string screenName: {
    var window = root.QsWindow ? root.QsWindow.window : null
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  function monitorList() {
    var out = []
    var values = Hyprland.monitors ? Hyprland.monitors.values : []
    for (var i = 0; i < values.length; i++) {
      var monitor = values[i]
      var ipc = monitor.lastIpcObject
      out.push({
        name: String(monitor.name || ""),
        description: String(monitor.description || (ipc ? ipc.description : "") || "")
      })
    }
    return out
  }

  // Config stores "desc:<description>" for stable displays and a bare output
  // name otherwise. Identical monitor models only differ by the serial carried
  // in the description, which is exactly why desc: is the preferred form.
  function resolveSelector(selector, monitors) {
    if (selector.indexOf("desc:") === 0) {
      var wanted = selector.substring(5)
      for (var i = 0; i < monitors.length; i++) {
        if (monitors[i].description === wanted
            || monitors[i].description.indexOf(wanted) === 0) return monitors[i].name
      }
      return ""
    }
    for (var j = 0; j < monitors.length; j++) {
      if (monitors[j].name === selector) return monitors[j].name
    }
    return ""
  }

  // The one layout on disk, filtered to this screen. A switched-off workspace
  // has no rule and no keybinding, so it cannot be reached at all; drawing a
  // button for it would offer something that does not work, so they are
  // filtered out rather than dimmed.
  //
  // A monitor in the layout that is unplugged is simply absent here, and the
  // workspaces the compositor reflowed onto this screen show up through the
  // live Hyprland state rather than through the config.
  function assignedIds() {
    if (!config || !config.monitors) return null
    var monitors = monitorList()
    var off = config.disabled || []
    for (var selector in config.monitors) {
      if (resolveSelector(selector, monitors) !== root.screenName) continue
      return (config.monitors[selector] || []).filter(function (id) {
        return off.indexOf(id) === -1
      })
    }
    return null
  }

  // ── model ─────────────────────────────────────────────────────────────────

  function workspaceById(id) {
    var values = Hyprland.workspaces ? Hyprland.workspaces.values : []
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  function isOccupied(id) {
    var workspace = workspaceById(id)
    return workspace !== null && workspace.toplevels.values.length > 0
  }

  function isFocused(id) {
    return Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === id
  }

  readonly property var ids: {
    var assigned = assignedIds()

    // No usable config for this screen: fall back to the stock behaviour rather
    // than an empty bar, so a broken or missing file is survivable.
    if (assigned === null) assigned = fallbackIds()

    // Assigned workspaces are persistent, so they exist whether or not
    // anything is in them, and the bar draws all of them. That fixed width is
    // the point: nothing appears or moves under the pointer as you work.
    assigned.sort(function (left, right) { return left - right })
    return assigned
  }

  function fallbackIds() {
    var out = [1, 2, 3, 4, 5]
    var values = Hyprland.workspaces ? Hyprland.workspaces.values : []
    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > 0 && id <= root.keySlots && out.indexOf(id) === -1) out.push(id)
    }
    return out
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  // ── layout ────────────────────────────────────────────────────────────────

  readonly property real trailingGap: root.ids.length === 0
    ? 0 : (root.vertical ? 0 : Style.spaceReal(1.5))

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : Math.max(1, root.ids.length)
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.ids

      WidgetButton {
        required property int modelData

        readonly property bool occupied: root.isOccupied(modelData)
        readonly property bool focused: root.isFocused(modelData)

        bar: root.bar
        text: focused ? "󱓻" : (modelData === root.keySlots ? "0" : String(modelData))
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function () { root.focusWorkspace(modelData) }
      }
    }
  }
}
