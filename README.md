# omarchy-workspaces

Pin Hyprland workspaces to specific monitors, and make each monitor's bar show
only the workspaces that monitor owns.

Out of the box, Omarchy lets workspaces land wherever they were first opened,
and the bar renders the same list of numbers on every screen. On a multi-monitor
desk that means workspace 7 might be on the left today and the middle tomorrow,
and all three bars show ten identical buttons. This plugin fixes both halves
from one config file.

```
┌─ DP-7 (left) ─┐ ┌─ DP-5 (middle) ┐ ┌ eDP-1 ┐
│ 1 2 3 4       │ │ 5 6 7 8        │ │ 9 0   │
└───────────────┘ └────────────────┘ └───────┘
```

## The editor

**Setup → Workspaces** in the Omarchy menu (or `omarchy-workspaces open`) opens
a visual editor. Monitors are drawn to scale in their real arrangement, so the
picture matches the desk.

```
┌──────────────────────────────────────────────────────────────┐
│  Workspaces                        [This monitor][All monitors]
│  Drag a workspace onto a monitor, or click one to send it on. │
│                                                               │
│  ┌── DP-7 ────────┐┌── DP-5 ────────┐┌ eDP-1 ──┐             │
│  │ 2560 x 1440    ││ 2560 x 1440    ││1920x1200│             │
│  │ 1  2  3  4     ││ 5  6  7  8     ││ 9  0    │             │
│  └────────────────┘└────────────────┘└─────────┘             │
│                                                               │
│  Unpinned — drop a workspace here to let it roam              │
│                                                               │
│  Profile: all-monitors      [Spread evenly][Cancel][Apply]    │
└──────────────────────────────────────────────────────────────┘
```

- **Drag** a workspace chip from one monitor to another.
- **Click** a chip to send it to the next monitor — or press its number key.
  `0` is workspace 10.
- **Drop it in the tray** to unpin it, letting Hyprland place it wherever you are.
- **This monitor / All monitors** sets what every bar draws, described below.
- Nothing is written until **Apply**; `Esc` or **Cancel** throws the edit away.

## What it does

- **Pins workspaces to monitors.** Generates Hyprland `workspace_rule` entries
  so each workspace has a home monitor and stays there.
- **Keeps them visible.** Assigned workspaces are persistent, so they exist and
  show in the bar even when empty. Nothing appears or disappears as you work.
- **Filters the bar per monitor.** The bar widget knows which screen it is
  drawn on and renders only that screen's workspaces.
- **Survives identical displays.** Monitors are matched by description, which
  includes the serial, so two of the same model keep their identity when
  `DP-5` and `DP-7` swap after a reboot or a dock reconnect.
- **Survives undocking.** Profiles are tried in order and the first one whose
  monitors are all connected wins, so unplugging everything falls through to a
  laptop-only profile instead of stranding workspaces on a monitor that is gone.

## Install

```bash
git clone https://github.com/kimm-stensborg/omarchy-workspaces.git ~/Projects/omarchy-workspaces
~/Projects/omarchy-workspaces/install.sh
```

The installer links the CLI into `~/.local/bin`, links the plugin into
`~/.config/omarchy/plugins/`, seeds a config from your connected monitors, adds
**Setup → Workspaces** to the Omarchy menu, and swaps `omarchy.workspaces` for
this widget in the bar. It is safe to re-run.

The plugin is two things in one: a `bar-widget` that draws the numbers, and an
`overlay` that edits them. Both read the same config file, so they cannot
disagree.

While hacking on it, note that `omarchy-shell shell rescanPlugins` reloads the
bar widget but not an overlay instance that is already mounted — restart the
shell (`omarchy restart shell`) after changing `Overlay.qml`.

## Usage

```bash
omarchy-workspaces open                # the visual editor
omarchy-workspaces status              # where each workspace lives right now
omarchy-workspaces list                # every profile and its assignments
omarchy-workspaces assign DP-7 1-4     # assign; accepts 1-4, 1,2,5, or 0 for 10
omarchy-workspaces apply               # regenerate rules, reload, re-home
omarchy-workspaces show all            # bar draws every workspace, grouped
omarchy-workspaces menu                # interactive TUI, for a terminal
```

`assign` takes a live output name and stores the stable `desc:` selector for it,
so you never have to type a monitor description by hand.

## Files

| Path | Owner | Purpose |
|---|---|---|
| `~/.config/omarchy/workspaces.json` | you | The source of truth. Read by both the Lua generator and the bar widget. |
| `~/.config/hypr/workspaces.lua` | generated | Workspace rules. **Do not edit** — `apply` overwrites it. |
| `~/.config/hypr/hyprland.lua` | you | Gets one `require` line appended on first apply. |

### Config shape

```json
{
  "version": 1,
  "persistent": true,
  "profiles": [
    {
      "name": "all-monitors",
      "monitors": {
        "desc:Lenovo Group Limited T27QD-40 VNACDZ5V": [1, 2, 3, 4],
        "desc:Lenovo Group Limited T27QD-40 VNACDZ1G": [5, 6, 7, 8],
        "desc:AU Optronics B160UAN04.9": [9, 10]
      }
    },
    { "name": "only-eDP-1", "monitors": { "desc:AU Optronics B160UAN04.9": [1,2,3,4,5,6,7,8,9,10] } }
  ]
}
```

Profiles are matched **in order**; the first one whose every monitor is
connected is used. Put your most specific profile first.

A monitor key is either a bare output name (`eDP-1`) or `desc:` plus the
monitor description from `hyprctl monitors`. Prefer `desc:` — output names move.

## Widget settings

Set these inline on the widget's entry in `~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
|---|---|---|
| `show` | `"own"` | `"own"` renders only this monitor's workspaces; `"all"` renders every assigned workspace, grouped, with this monitor's group at full strength and the others dimmed. The editor's toggle sets this. |
| `separators` | `true` | Draw a divider between monitor groups. Only used when `show` is `"all"`. |

## How keys behave

Workspace rules do not change your keybindings. `SUPER+7` still focuses
workspace 7 — but because 7 now has a home monitor, focus moves to that monitor
rather than dragging the workspace to where you are. A workspace is always in
the same physical place.

## Hotplug

The generated Lua subscribes to `monitor.added` and `monitor.removed`. When a
monitor change makes a different profile win, it reloads the config; otherwise
it just walks any drifted workspace back to its home monitor. The reload only
fires on an actual profile change, so hotplug cannot loop.

## Uninstall

```bash
rm ~/.local/bin/omarchy-workspaces
rm ~/.config/omarchy/plugins/kimm-stensborg.workspaces
rm ~/.config/hypr/workspaces.lua
# then drop the require line from ~/.config/hypr/hyprland.lua,
# the "setup.workspaces*" rows from ~/.config/omarchy/extensions/omarchy-menu.jsonc,
# and set the bar widget back to "omarchy.workspaces" in ~/.config/omarchy/shell.json
```

## License

MIT
