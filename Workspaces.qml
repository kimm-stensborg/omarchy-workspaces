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
  moduleName: "kimm-stensborg.workspaces"

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/workspaces.json"

  // "own"  — only the workspaces assigned to this monitor (default)
  // "all"  — every assigned workspace, grouped, with this monitor's group lit
  readonly property string mode: setting("show", "own")
  readonly property bool showSeparators: setting("separators", true) === true

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
  function activeGroups() {
    if (!config) return null
    var monitors = monitorList()
    for (var p = 0; p < config.profiles.length; p++) {
      var assignments = config.profiles[p].monitors || {}
      var groups = []
      var complete = true
      for (var selector in assignments) {
        var name = resolveSelector(selector, monitors)
        if (!name) { complete = false; break }
        var ids = (assignments[selector] || []).slice().sort(function (a, b) { return a - b })
        groups.push({ screen: name, ids: ids })
      }
      if (complete && groups.length > 0) return groups
    }
    return null
  }

  // ── model ─────────────────────────────────────────────────────────────────

  // Flat list of { id, own, groupStart } rows. `groupStart` marks the first
  // entry of each monitor's block so "all" mode can draw separators.
  readonly property var rows: {
    var groups = activeGroups()

    // No usable config: fall back to the stock behaviour rather than an empty
    // bar, so a broken or missing file is survivable.
    if (!groups) return fallbackRows()

    groups.sort(function (left, right) { return left.ids[0] - right.ids[0] })

    var out = []
    for (var g = 0; g < groups.length; g++) {
      var own = groups[g].screen === root.screenName
      if (root.mode === "own" && !own) continue
      for (var i = 0; i < groups[g].ids.length; i++) {
        out.push({ id: groups[g].ids[i], own: own, groupStart: i === 0 && out.length > 0 })
      }
    }
    return out.length > 0 ? out : fallbackRows()
  }

  function fallbackRows() {
    var ids = [1, 2, 3, 4, 5]
    var values = Hyprland.workspaces ? Hyprland.workspaces.values : []
    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > 0 && id <= 10 && ids.indexOf(id) === -1) ids.push(id)
    }
    ids.sort(function (left, right) { return left - right })
    return ids.map(function (id) { return { id: id, own: true, groupStart: false } })
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces ? Hyprland.workspaces.values : []
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  // ── layout ────────────────────────────────────────────────────────────────

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.rows.length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.rows

      WidgetButton {
        required property var modelData

        readonly property int workspaceId: modelData.id
        readonly property var workspace: root.workspaceById(workspaceId)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null
          && Hyprland.focusedWorkspace.id === workspaceId

        bar: root.bar
        text: focused ? "󱓻" : (workspaceId === 10 ? "0" : String(workspaceId))
        // Three tiers: the focused/occupied workspaces on this monitor read at
        // full strength, its empty ones sit back, and another monitor's block
        // (only visible in "all" mode) is dimmer still.
        opacity: !modelData.own ? 0.3 : (occupied || focused ? 1 : 0.5)
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function () { root.focusWorkspace(workspaceId) }

        // Separator between monitor blocks, drawn on the leading edge so it
        // never adds width past the last button.
        Rectangle {
          visible: root.showSeparators && root.mode === "all" && modelData.groupStart
          color: root.bar ? root.bar.foreground : "white"
          opacity: 0.25
          width: root.vertical ? parent.width * 0.5 : 1
          height: root.vertical ? 1 : parent.height * 0.45
          anchors.horizontalCenter: root.vertical ? parent.horizontalCenter : undefined
          anchors.verticalCenter: root.vertical ? undefined : parent.verticalCenter
          anchors.left: root.vertical ? undefined : parent.left
          anchors.top: root.vertical ? parent.top : undefined
        }
      }
    }
  }
}
