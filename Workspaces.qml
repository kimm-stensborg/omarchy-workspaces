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

  // Assigned workspaces are persistent, so they exist in Hyprland whether or
  // not anything is in them. That is what keeps the bar from reflowing as you
  // work — but on a single monitor, ten permanent buttons is a lot of bar for
  // very little news. `hideEmpty` trades the stable width back for a list of
  // only what is actually running.
  readonly property bool hideEmpty: setting("hideEmpty", false) === true

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
      return parsed && parsed.version === 1 && Array.isArray(parsed.profiles) ? parsed : null
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

  // First profile whose every monitor is connected wins — the same rule the
  // generated Lua uses, so the bar and the compositor never disagree.
  function assignedIds() {
    if (!config) return null
    var monitors = monitorList()
    for (var p = 0; p < config.profiles.length; p++) {
      var assignments = config.profiles[p].monitors || {}
      var mine = null
      var complete = true
      for (var selector in assignments) {
        var name = resolveSelector(selector, monitors)
        if (!name) { complete = false; break }
        if (name === root.screenName) mine = (assignments[selector] || []).slice()
      }
      if (complete) return mine
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

    assigned.sort(function (left, right) { return left - right })

    // The workspace you are standing in is never hidden, however empty — losing
    // your own position off the bar is worse than the button it saves.
    if (!root.hideEmpty) return assigned
    return assigned.filter(function (id) { return root.isOccupied(id) || root.isFocused(id) })
  }

  function fallbackIds() {
    var out = [1, 2, 3, 4, 5]
    var values = Hyprland.workspaces ? Hyprland.workspaces.values : []
    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > 0 && id <= 10 && out.indexOf(id) === -1) out.push(id)
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
        text: focused ? "󱓻" : (modelData === 10 ? "0" : String(modelData))
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
