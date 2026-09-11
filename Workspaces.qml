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

  // Read as a property, not only inside a function, so `ids` re-evaluates when
  // Hyprland finishes enumerating monitors. A function call from a binding is
  // easy for QML to treat as a constant — which is how the bar could open on
  // the stock 1–10 fallback and never leave it, even after the config loaded.
  readonly property var hyprMonitors: Hyprland.monitors ? Hyprland.monitors.values : []
  readonly property var hyprWorkspaces: Hyprland.workspaces ? Hyprland.workspaces.values : []

  readonly property var windowScreen: {
    var window = root.QsWindow ? root.QsWindow.window : null
    return window && window.screen ? window.screen : null
  }

  // Hyprland.monitorFor maps a Quickshell screen onto the compositor's output
  // name. Comparing screen.name to monitor.name directly is the same string on
  // a good day and an empty match after a plugin reload — every bar then falls
  // through to the stock 1–10 list, which is how the overlay and the bar stop
  // agreeing.
  readonly property string screenName: {
    var screen = root.windowScreen
    if (!screen) return ""
    if (typeof Hyprland.monitorFor === "function") {
      var hypr = Hyprland.monitorFor(screen)
      if (hypr && hypr.name) return String(hypr.name)
    }
    return String(screen.name || "")
  }

  function monitorList() {
    var out = []
    var values = root.hyprMonitors
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

  // The one layout on disk, filtered to this screen — the same placement the
  // generated Lua uses, so the bar and the compositor never disagree.
  //
  // A switched-off workspace has no rule and no keybinding, so it cannot be
  // reached at all; drawing a button for it would offer something that does
  // not work, so they are filtered out rather than dimmed.
  //
  // A monitor that is not plugged in has its workspaces reflow onto the
  // nearest one that is (nearest in layout order, preferring left), matching
  // the compositor. Returning null is reserved for "there is no config"; an
  // empty list means "this screen is not ready or holds nothing", which must
  // not fall through to the stock 1–10 buttons.
  function assignedIds() {
    var name = root.screenName
    var values = root.hyprMonitors
    if (!root.config || !root.config.monitors) return null
    if (!name || !values || values.length === 0) return []

    var monitors = root.monitorList()
    var off = root.config.disabled || []
    var groups = []
    for (var selector in root.config.monitors) {
      groups.push({
        name: root.resolveSelector(selector, monitors),
        workspaces: (root.config.monitors[selector] || []).filter(function (id) {
          return off.indexOf(id) === -1
        })
      })
    }

    var present = []
    for (var i = 0; i < groups.length; i++) if (groups[i].name) present.push(i)
    if (present.length === 0) return []

    function nearest(from) {
      var best = present[0], bestDistance = 1e9
      for (var p = 0; p < present.length; p++) {
        var idx = present[p]
        var distance = Math.abs(idx - from) * 2 + (idx > from ? 1 : 0)
        if (distance < bestDistance) { best = idx; bestDistance = distance }
      }
      return best
    }

    var mine = []
    for (var g = 0; g < groups.length; g++) {
      var target = groups[g].name ? g : nearest(g)
      if (groups[target].name !== name) continue
      mine = mine.concat(groups[g].workspaces)
    }
    return mine
  }

  // ── model ─────────────────────────────────────────────────────────────────

  function workspaceById(id) {
    var values = root.hyprWorkspaces
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
    var assigned = root.assignedIds()

    // No config at all: fall back to the stock behaviour rather than an empty
    // bar, so a broken or missing file is survivable. An empty list from
    // assignedIds is different — it means the config is fine and this screen
    // just is not ready, or holds nothing — and must not become 1–10.
    if (assigned === null) assigned = root.fallbackIds()

    // Assigned workspaces are persistent, so they exist whether or not
    // anything is in them, and the bar draws all of them. That fixed width is
    // the point: nothing appears or moves under the pointer as you work.
    assigned.sort(function (left, right) { return left - right })
    return assigned
  }

  function fallbackIds() {
    var out = [1, 2, 3, 4, 5]
    var values = root.hyprWorkspaces
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
