# Workspaces per Monitor

Pin Hyprland workspaces to specific monitors, and make each monitor's bar show
only the workspaces that monitor owns.

Out of the box, Omarchy lets workspaces land wherever they were first opened,
and the bar renders the same list of numbers on every screen. On a multi-monitor
desk that means workspace 7 might be on the left today and the middle tomorrow,
and all three bars show ten identical buttons. This plugin fixes both halves
from one config file — and because its editor already draws your monitors to
scale, it lets you drag them into a new order too.

```
┌─ DP-7 (left) ─┐ ┌─ DP-5 (middle) ┐ ┌ eDP-1 ┐
│ 1 2 3 4       │ │ 5 6 7 8        │ │ 9 0   │
└───────────────┘ └────────────────┘ └───────┘
```

- **Plugin ID:** `io.github.kimm-stensborg.workspaces`
- **Kinds:** `bar-widget`, `overlay`, `service`
- **License:** MIT
- **Requires:** Omarchy 4 (Quattro) with `omarchy-shell`, and Hyprland's Lua config

## Dependencies

All ship with Omarchy and are present on a stock install:

| Package | Used for |
|---------|----------|
| `hyprland` | `hyprctl` — reading monitors, reloading, moving workspaces |
| `jq` | every config read and write in `bin/omarchy-workspaces` |
| `diffutils` | `doctor`, to tell a stale generated file from a current one |

Nothing is downloaded or installed at runtime.

## Install

```bash
omarchy plugin add https://github.com/kimm-stensborg/omarchy-workspaces.git
omarchy plugin enable io.github.kimm-stensborg.workspaces --section left
```

`omarchy plugin add` clones into
`~/.config/omarchy/plugins/io.github.kimm-stensborg.workspaces/` and leaves the
plugin disabled so the code can be reviewed before it runs. Plugins execute
unsandboxed inside `omarchy-shell`, so that pause is the point — read it first.

Both commands prompt when run bare in a terminal. To skip every prompt, which
is the path for scripts and agents:

```bash
omarchy plugin add https://github.com/kimm-stensborg/omarchy-workspaces.git --enable --yes
```

Updating and removing are the same two commands you already know:

```bash
omarchy plugin update io.github.kimm-stensborg.workspaces   # fetch, show a diff, fast-forward
omarchy plugin remove io.github.kimm-stensborg.workspaces
```

Enabling it is the whole setup. `omarchy plugin add` never runs an install
hook, so the plugin's `service` does the rest itself the moment it loads:

1. Seeds `~/.config/omarchy/workspaces.json` from your connected monitors,
   spreading 1–10 evenly across them left to right, if the file does not exist.
2. Generates `~/.config/hypr/workspaces.lua` from that config.
3. Appends one guarded `require` line to `~/.config/hypr/hyprland.lua`.
4. Reloads Hyprland — but only when step 2 or 3 actually changed something, so
   every later shell start costs a diff and touches nothing.

The service then watches `workspaces.json`, so a hand-edit of that file applies
on save just as the editor's **Apply** does.

### Putting it in the bar in place of the stock widget

`--section left` drops it at the left edge. To take over the exact slot the
stock `omarchy.workspaces` occupies today instead, enable it there and turn
the stock one off:

```bash
omarchy plugin enable io.github.kimm-stensborg.workspaces --before omarchy.workspaces
omarchy plugin disable omarchy.workspaces
```

Disabling a first-party widget only drops it from the bar layout; it stays
available, so `omarchy plugin enable omarchy.workspaces` puts it back.

## The editor

`omarchy-shell shell summon io.github.kimm-stensborg.workspaces '{}'` opens a
visual editor. Monitors are drawn to scale in their real arrangement, so the
picture matches the desk.

```
┌───────────────────────────────────────────────────────────────┐
│  Workspaces                                      [✓ Hide empty]│
│  Drag a workspace to another monitor.                           │
│  Click a workspace to switch it off.                            │
│                                                                │
│  ┌── DP-7 ────────[1]┐┌── DP-5 ────────[2]┐┌ eDP-1 ───[3]┐   │
│  │ 2560 x 1440        ││ 2560 x 1440        ││ 1920 x 1200 │   │
│  │ 1  2  3 (4)        ││ 5  6  7  8         ││ 9  0        │   │
│  └────────────────────┘└────────────────────┘└─────────────┘   │
│                                                                │
│                                     [Identify][Cancel][Apply]  │
└────────────────────────────────────────────────────────────────┘
```

`(4)` is switched off: an outline with a line through it, and no keybinding.

- **Drag** a workspace chip from one monitor to another.
- **Click** a chip to switch that workspace off — or press its number key.
  `0` is workspace 10.
- Workspaces are spread evenly across your monitors when the config is first
  built, and again if the editor ever opens on a layout that assigns nothing.
  There is no button for it, because it is not a thing you should need twice.
- **Identify** puts a big number and connector name on each physical screen for
  three seconds, so you can tell which `DP-` is which without counting cables.
  The same number sits in the corner of each card here, which is what makes the
  two pictures line up. It is hidden when there is only one screen.
- **Hide empty** sets what every bar draws, described under *Widget settings*.
- Nothing is written until **Apply**; `Esc` or **Cancel** throws the edit away.

Every workspace always belongs to exactly one monitor. There is no third state
where Hyprland places a workspace itself — a workspace with no home is the
thing this plugin exists to prevent.

### Monitor positions are read, never written

The desk is drawn from where Hyprland says the monitors are. Moving them is
`~/.config/hypr/monitors.lua`, and this plugin does not touch that file.

It used to: monitors were draggable and Apply rewrote the `position` of each.
It could not be made safe. A `monitors.lua` that names outputs through a local
table — `hl.monitor({ output = monitors.left, ... })`, which is the shape
Omarchy's own comments suggest — has nothing for a text rewriter to match, so
the fallback appended fresh blocks at the end of the file. Where that file
ends in `return monitors`, as it does when the table is shared with another
config, appending produced Lua that would not parse at all. Breaking someone's
monitor configuration is a steep price for saving them a text edit.

Add a menu entry by putting this in
`~/.config/omarchy/extensions/omarchy-menu.jsonc` (it hot-reloads on save),
which puts it under **Setup → Workspaces**:

```jsonc
"setup.workspaces": {
  "icon": "󰕰",
  "label": "Workspaces",
  "description": "Pin workspaces to monitors",
  "aliases": ["workspaces", "monitors"],
  "action": "omarchy-shell shell summon io.github.kimm-stensborg.workspaces '{}'"
},
```

Or bind a key in `~/.config/hypr/bindings.lua`.

## Switching a workspace off

A workspace that is off gets no rule, no persistence, and **no keybinding**:
`SUPER+4` becomes a no-op, and the workspace cannot be created or reached at
all. It is not hidden, it is gone. Use it to cut ten workspaces down to the
number you actually keep.

```bash
omarchy-workspaces disable 4,10    # or a range: 7-10
omarchy-workspaces enable 4
```

It keeps its place on a monitor while off, so the editor still draws the pill
where it was and one click brings it back.

The unbind is the only part that reaches outside this plugin's own files. It is
done by `hl.unbind` in the generated Lua, after the config settles, because
Hyprland loads Omarchy's bindings after `hypr/workspaces.lua`. Nothing is
rebound on the way back: a reload re-runs Omarchy's bindings and restores every
key, and the settle pass then removes only the ones still switched off.

## What it does

- **Pins workspaces to monitors.** Generates Hyprland `workspace_rule` entries
  so each workspace has a home monitor and stays there.
- **Arranges the monitors.** Drag a screen in the editor to move it on the
  desk; the new positions go into `monitors.lua`, one `position` string at a
  time.
- **Keeps them visible.** Assigned workspaces are persistent, so they exist and
  show in the bar even when empty. Nothing appears or disappears as you work.
- **Filters the bar per monitor.** The bar widget knows which screen it is
  drawn on and renders only that screen's workspaces.
- **Survives identical displays.** Monitors are matched by description, which
  includes the serial, so two of the same model keep their identity when
  `DP-5` and `DP-7` swap after a reboot or a dock reconnect.
- **Survives undocking.** A monitor that is not plugged in has its workspaces
  reflow onto the nearest one that is, and get them back when it returns.
  Nothing is written to disk when that happens — the layout is still the
  layout, so undocking and re-docking is not an edit.

## The CLI

`bin/omarchy-workspaces` lives inside the plugin folder rather than on `PATH`,
so that adding the plugin is the whole install. The overlay and the service
call it by absolute path. For terminal use, link it yourself:

```bash
ln -s ~/.config/omarchy/plugins/io.github.kimm-stensborg.workspaces/bin/omarchy-workspaces \
      ~/.local/bin/omarchy-workspaces
```

Do not put that symlink *inside* the plugin folder — `omarchy plugin validate`
refuses a plugin containing symlinks, and `omarchy plugin update` would fail.

```bash
omarchy-workspaces doctor              # does the live state match the config?
omarchy-workspaces status              # where each workspace lives right now
omarchy-workspaces list                # the layout
omarchy-workspaces assign DP-7 1-4     # assign; accepts 1-4, 1,2,5, or 0 for 10
omarchy-workspaces apply               # regenerate rules, reload, re-home
omarchy-workspaces bootstrap           # what the service runs; safe any time
omarchy-workspaces disable 4,10        # switch workspaces off entirely
omarchy-workspaces enable 4            # and back on
omarchy-workspaces generate            # write the rules without reloading
omarchy-workspaces edit                # open the config in $EDITOR
omarchy-workspaces open                # the visual editor
```

`assign` takes a live output name and stores the stable `desc:` selector for it,
so you never have to type a monitor description by hand.

## Checking it actually worked

Everything this plugin writes lands in a file it does not own, beside other
things that write to the same place. When one of those wins, nothing says so:
`apply` reloads, prints a success line, and the disagreement sits there until
someone notices the screen is not doing what the config says. Every bug this
plugin has had was that shape.

```bash
omarchy-workspaces doctor
```

It asks Hyprland rather than assuming, and checks: the generated Lua is ours
and current, the `require` is in place, every workspace is on its home monitor,
and every switched-off workspace really is gone and unbound.

It checks the layout on paper first, before comparing anything to a screen: a
workspace placed on two monitors at once, or a `disabled` entry naming a
workspace the layout never places. Those need nothing plugged in, so
they run whatever is connected. It exits non-zero on
any drift, so a hook or a keybinding can watch it too.

`apply` runs it before claiming success, and reports what does not match rather
than printing "Applied" over the top of it.

```
Config:   /home/you/.config/omarchy/workspaces.json

  ✓ workspaces.lua matches the config
  ✓ hyprland.lua requires hypr.workspaces
  ✓ the layout is self-consistent
  ✗ placement: 7 on DP-7, home is DP-5
  ✓ keys: 10 bound, 0 unbound

1 problem(s). Run 'omarchy-workspaces apply' to reconcile.
```

Almost everything it finds is fixed by running `apply`.

## Tests

```bash
./test.sh
```

Covers the parts that are pure — argument parsing, the config transforms, and
the shape of the generated Lua — against a fixed two-monitor fixture, so the
results do not depend on what is plugged into the machine running them.
Anything that needs a live Hyprland is `doctor`'s job instead.

## Files

| Path | Owner | Purpose |
|---|---|---|
| `~/.config/omarchy/workspaces.json` | you | The source of truth. Read by the Lua generator, the bar widget, and the editor. |
| `~/.config/hypr/workspaces.lua` | generated | Workspace rules. **Do not edit** — every apply overwrites it. |
| `~/.config/hypr/hyprland.lua` | you | Gets one guarded `require` line appended once. |
| `~/.config/omarchy/shell.json` | the shell | Holds the widget's `hideEmpty` setting, inline on its bar entry. |

### Config shape

```json
{
  "version": 1,
  "count": 10,
  "persistent": true,
  "monitors": {
    "desc:Lenovo Group Limited T27QD-40 VNACDZ5V": [1, 2, 3, 4],
    "desc:Lenovo Group Limited T27QD-40 VNACDZ1G": [5, 6, 7, 8],
    "desc:AU Optronics B160UAN04.9": [9, 10]
  },
  "disabled": []
}
```

There is one layout, and monitor order in it is left to right — which is what
decides where workspaces go when a monitor is missing.

A monitor key is either a bare output name (`eDP-1`) or `desc:` plus the
monitor description from `hyprctl monitors`. Prefer `desc:` — output names move.

`count` is how many workspaces you use, and defaults to 10. Omarchy binds
`SUPER+1` to `SUPER+0` and nothing else, so ten is the most that can be reached
from the keyboard; set it lower and the surplus keys are unbound rather than
left to open a workspace on whichever monitor happens to be focused.

```bash
omarchy-workspaces detect --force --count=6
```

`disabled` is optional and lists the workspaces that are switched off. They
stay in `monitors` — off is a state, not a removal.

## Widget settings

Set these inline on the widget's entry in `~/.config/omarchy/shell.json`:

| Key | Default | Meaning |
|---|---|---|
| `hideEmpty` | `false` | Draw only the workspaces that hold windows, instead of every workspace assigned to this monitor. The focused workspace is always drawn, however empty. |

That entry belongs to the shell, not to this plugin, so it is set the supported
way — `omarchy bar set io.github.kimm-stensborg.workspaces hideEmpty true`, which
is also what the editor's **Hide empty** toggle calls.

Switched-off workspaces are never drawn, whatever `hideEmpty` says — a button
for a workspace with no keybinding would offer something that does not work.

## Tiling layout is not this plugin's job

`SUPER+L` toggles the current workspace between tiling and scrolling. That is
Omarchy's, it saves its choice under `~/.local/state/omarchy/workspace-layouts`,
and this plugin does not touch it — the generated workspace rules deliberately
name no layout, which is what lets the two coexist without arguing about whose
answer survives a reload.

Earlier versions did own this, first per monitor and then per workspace, and
it was a mistake both times: two things writing one property, with load order
picking the winner. A config carrying either form is handed back rather than
dropped — the values are written where `SUPER+L` would have written them, so
the screen keeps doing what it did — and the keys are removed.

This plugin places workspaces on monitors. That is all it does.

## How keys behave

Workspace rules do not change your keybindings. `SUPER+7` still focuses
workspace 7 — but because 7 now has a home monitor, focus moves to that monitor
rather than dragging the workspace to where you are. A workspace is always in
the same physical place.

## Hotplug

The generated Lua subscribes to `monitor.added` and `monitor.removed`, and
re-derives where everything goes in place — no reload, because the layout on
disk has not changed, only which monitors are answering.

A monitor that is not connected has its workspaces reflow onto the nearest one
that is: nearest by position in the layout, preferring the neighbour to the
left. Unplug the laptop from the three-monitor desk above and 9 and 0 join
DP-5; plug it back in and they return. Nothing is written to disk either way.

This replaced a list of saved layouts matched first-fits against whatever was
connected. It read as flexibility and behaved as a trap: unplugging one screen
would match a single-monitor entry and collapse all ten workspaces onto it,
leaving the other monitor connected and empty. A config still carrying
`profiles` is folded into one layout — the fullest entry, since that is the one
describing the whole desk — the first time the plugin reads it.

## Hacking on it

Saving a file anywhere under `~/.config/omarchy/plugins/` reloads plugin code
automatically, and `omarchy-shell shell rescanPlugins` forces it. That covers
the bar widget and the service; an overlay instance that is already mounted is
not re-created, so restart the shell (`omarchy restart shell`) after changing
`Overlay.qml`.

Restart it after editing `kinds` in the manifest too. The shell builds one
loader per panel/overlay/menu plugin when its plugin list changes, but skips
that rebuild while a hot-reload is in flight — so a kind declared during a
reload gets no loader, and summoning it returns `ok` and does nothing at all,
with no error anywhere to explain why. A fresh `omarchy plugin add` is fine;
this only bites while editing a plugin in place.

Before pushing, check the manifest against what the shell will accept:

```bash
omarchy plugin validate .
```

## Remove

```bash
omarchy plugin remove io.github.kimm-stensborg.workspaces
```

That unloads the widget and the service and deletes the checkout. The files it
put outside its own folder are yours to clean up:

```bash
rm ~/.config/hypr/workspaces.lua
rm ~/.config/omarchy/workspaces.json
rm -f ~/.local/bin/omarchy-workspaces        # only if you linked it
# then drop the `require(...).module("hypr.workspaces")` line from
# ~/.config/hypr/hyprland.lua and reload: hyprctl reload
```

The `require` is guarded, so leaving it in place is harmless — a missing
`workspaces.lua` is skipped rather than breaking the config. Your workspaces
go back to Hyprland's default placement on the next reload either way.

## License

MIT
