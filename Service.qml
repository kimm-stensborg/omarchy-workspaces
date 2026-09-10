import QtQuick
import Quickshell
import Quickshell.Io

// Headless half of the plugin: the thing that makes enabling it enough.
//
// `omarchy plugin add` clones files and flips a bit in shell.json — it never
// runs an install hook, and deliberately so. Everything this plugin needs on
// disk outside its own folder therefore has to be put there by the running
// plugin itself:
//
//   ~/.config/omarchy/workspaces.json   seeded from the connected monitors
//   ~/.config/hypr/workspaces.lua       generated from that config
//   ~/.config/hypr/hyprland.lua         one guarded `require` line, appended once
//
// `bootstrap` does all three and is a no-op once they agree, so running it at
// every shell start costs a diff and nothing else. It runs again whenever the
// config changes, which is what applies a hand-edit of workspaces.json.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.kimm-stensborg.workspaces"
  readonly property string pluginDir: root.manifest && root.manifest.__sourceDir
    ? String(root.manifest.__sourceDir)
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.pluginId
  readonly property string cli: root.pluginDir + "/bin/omarchy-workspaces"
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/workspaces.json"

  function bootstrap() {
    if (bootstrapProc.running) {
      // A change that lands mid-run would otherwise be the one that gets lost,
      // since the run in flight is already reading the old file.
      root.rerunWhenDone = true
      return
    }
    root.rerunWhenDone = false
    bootstrapProc.running = true
  }

  property bool rerunWhenDone: false

  Process {
    id: bootstrapProc
    command: ["bash", root.cli, "bootstrap", "--quiet"]
    stderr: StdioCollector {
      onStreamFinished: {
        if (text.length > 0) console.warn(root.pluginId, "bootstrap:", text.trim())
      }
    }
    onExited: function (code) {
      if (code !== 0) console.warn(root.pluginId, "bootstrap exited", code)
      if (root.rerunWhenDone) root.bootstrap()
    }
  }

  // Hyprland is not necessarily done reading its own config when the shell
  // comes up, and a first run wants to seed from monitors that are actually
  // enumerated. A short delay costs nothing and avoids racing both.
  Timer {
    running: true
    interval: 1500
    repeat: false
    onTriggered: root.bootstrap()
  }

  // Coalesce the burst of writes a save produces into one run.
  Timer {
    id: settle
    interval: 1200
    repeat: false
    onTriggered: root.bootstrap()
  }

  // Watching the config rather than being told about it means a hand-edit,
  // the overlay's Apply, and the CLI all reconcile the same way.
  FileView {
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: {
      reload()
      settle.restart()
    }
  }
}
