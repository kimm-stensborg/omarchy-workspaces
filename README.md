# Workspaces per Monitor

Pin Hyprland workspaces to specific monitors, make each monitor's bar show
only the workspaces that monitor owns, and rearrange the monitors themselves by
dragging them.

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
| `awk` | rewriting monitor positions in `monitors.lua` (`arrange`) |
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
│  Drag a workspace to another monitor, or a monitor to           │
│  rearrange the desk. Click a workspace to switch it off.        │
│                                                                │
│  ┌── DP-7 ───────────┐┌── DP-5 ───────────┐┌ eDP-1 ──────┐   │
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
- **Drag a monitor** to move it on the desk — see below.
- Workspaces are spread evenly across your monitors when the config is first
  built, and again if the editor ever opens on a profile that assigns nothing.
  There is no button for it, because it is not a thing you should need twice.
- **Identify** puts a big number and connector name on each physical screen for
  three seconds, so you can tell which `DP-` is which without counting cables.
- **Hide empty** sets what every bar draws, described under *Widget settings*.
- Nothing is written until **Apply**; `Esc` or **Cancel** throws the edit away.

Every workspace always belongs to exactly one monitor. There is no third state
where Hyprland places a workspace itself — a workspace with no home is the
thing this plugin exists to prevent.

### Rearranging the desk

The monitors are draggable too. Grab one anywhere that is not a workspace chip
and carry it along the row: the other monitors step aside to open a slot for
it, and a ghost outline marks the slot it would land in. It is the same gesture
as dragging a tab along a tab bar — what you are looking at mid-drag is the
arrangement you get by letting go.

Which slot you are in is decided by where the dragged monitor's centre sits
among the others, measured against the row packed without it, so the slot
changes the moment you carry it past a neighbour rather than only once you have
covered that neighbour completely. Pushing it against either end of the desk
puts it at that end of the row, which is how a monitor wider than its
neighbour still gets to lead.

Monitors of different widths change places by repacking the row, not by
swapping coordinates, so a rearrangement can never open a gap or leave an
overlap.

A drag stays inside the desk. The picture is a picture of the desk, and a
screen dragged out of it would be drawn over everything else in the card, so
the extent it had when you grabbed it is also the fence around it. What that
means in practice is that a drag rearranges the envelope the desk already has:
a row reorders within the row, and carrying a monitor clear of the row to stack
it above or below another is a move for a desk that already has the height for
it — there, the drag falls back to free placement, snapping flush and level to
whatever edge it lands near.

The desk is always shifted back so its top-left corner is `0x0`. With a single
monitor there is no arrangement to change, so monitors are not draggable at
all — no grab cursor, nothing to drop.

Apply writes the result into **`~/.config/hypr/monitors.lua`** — your file, not
a generated one. Only the `position = "XxY"` string of each monitor is
rewritten; modes, scales, comments and everything else are left exactly as they
were, and a monitor with no block of its own gets one appended. The first time
the plugin touches that file it keeps a pristine copy at `monitors.lua.bak` and
never overwrites it again.

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
- **Survives undocking.** Profiles are tried in order and the first one whose
  monitors are all connected wins, so unplugging everything falls through to a
  laptop-only profile instead of stranding workspaces on a monitor that is gone.

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
omarchy-workspaces list                # every profile and its assignments
omarchy-workspaces assign DP-7 1-4     # assign; accepts 1-4, 1,2,5, or 0 for 10
omarchy-workspaces apply               # regenerate rules, reload, re-home
omarchy-workspaces bootstrap           # what the service runs; safe any time
omarchy-workspaces disable 4,10        # switch workspaces off entirely
omarchy-workspaces enable 4            # and back on
omarchy-workspaces layout 6 dwindle    # pin one workspace against the global layout
omarchy-workspaces toggle-layout       # flip the active one (this is SUPER+L)
omarchy-workspaces arrange DP-5 0x0 DP-7 2560x0   # move monitors on the desk
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
and current, the `require` is in place, `SUPER+L` is bound here and points at
a script that exists, no saved `SUPER+L` override outranks us, every workspace
is on its home monitor and in the layout the config asks for, and every
switched-off workspace really is unbound.

It also checks **every** saved layout, not just the one in force. A fallback is
only exercised the day a monitor goes missing, which is the worst moment to
find out it was wrong all along, so the parts that are wrong on paper are
reported now: a workspace placed on two monitors at once, a `disabled` or
`layouts` entry naming a workspace that layout never places, and — the one
that is genuinely hard to spot by reading — a layout that can never be used
because an earlier one in the list needs a subset of its monitors, so it always
matches first.

Those checks need nothing plugged in, so they still run when *no* saved layout
fits the monitors present. That is the moment they are most worth having. It exits non-zero on
any drift, so a hook or a keybinding can watch it too.

`apply` runs it before claiming success, and reports what does not match rather
than printing "Applied" over the top of it.

```
Profile:  all-monitors
Config:   /home/you/.config/omarchy/workspaces.json

  ✓ workspaces.lua matches the config
  ✓ SUPER+L points at a script that exists
  ✓ hyprland.lua requires hypr.workspaces
  ✓ all 4 saved layouts are consistent and reachable
  ✗ saved SUPER+L layout override(s) outrank this plugin: workspace 2 7
  ✓ SUPER+L is bound to this plugin's layout toggle
  ✓ placement: all 10 workspaces on their home monitor
  ✗ layout: 2 is scrolling, want dwindle
  ✓ keys: 10 bound, 0 unbound

2 problem(s). Run 'omarchy-workspaces apply' to reconcile.
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
| `~/.config/hypr/monitors.lua` | you | Only the `position` of each monitor is rewritten, and only when you rearrange the desk. A pristine copy is kept at `monitors.lua.bak` the first time. |
| `~/.config/omarchy/shell.json` | the shell | Holds the widget's `hideEmpty` setting, inline on its bar entry. |

### Config shape

```json
{
  "version": 1,
  "count": 10,
  "persistent": true,
  "profiles": [
    {
      "name": "all-monitors",
      "monitors": {
        "desc:Lenovo Group Limited T27QD-40 VNACDZ5V": [1, 2, 3, 4],
        "desc:Lenovo Group Limited T27QD-40 VNACDZ1G": [5, 6, 7, 8],
        "desc:AU Optronics B160UAN04.9": [9, 10]
      },
      "layouts": { "6": "scrolling" }
    },
    { "name": "only-eDP-1", "monitors": { "desc:AU Optronics B160UAN04.9": [1,2,3,4,5,6,7,8,9,10] } }
  ]
}
```

Profiles are matched **in order**; the first one whose every monitor is
connected is used, so the most specific goes first — put a single-monitor
fallback ahead of the full desk and the full desk can never win. `doctor`
checks for exactly that, and the editor lists what each fallback would do.

A monitor key is either a bare output name (`eDP-1`) or `desc:` plus the
monitor description from `hyprctl monitors`. Prefer `desc:` — output names move.

`count` is how many workspaces you use, and defaults to 10. Omarchy binds
`SUPER+1` to `SUPER+0` and nothing else, so ten is the most that can be reached
from the keyboard; set it lower and the surplus keys are unbound rather than
left to open a workspace on whichever monitor happens to be focused.

```bash
omarchy-workspaces detect --force --count=6
```

`disabled` is optional and lists the workspaces that are switched off in that
profile. They stay in `monitors` — off is a state, not a removal.

`layouts` is optional and maps a workspace id to a layout name, pinning it
against Hyprland's global `general.layout`. This is what `SUPER+L` writes.

Every generated rule names a layout, including the tiling ones — `general.layout`
normally, or `dwindle` when that is itself `scrolling`. Leaving the layout out of
a rule does not restore the default: a reload with no layout leaves a workspace
in whatever layout it last had, so toggling scrolling back off would not be
undoable without a restart.

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

## Scrolling, and SUPER+L

Layout is per workspace. `SUPER+L` toggles the one you are on between tiling
and scrolling; anything you have not touched follows Hyprland's global
`general.layout`. The editor does not show which workspaces carry one — layout is not what a
picture of which-workspace-lives-where is about. `doctor` prints the live
layout of each, and the config lists them.

```bash
omarchy-workspaces layout 6 scrolling      # pin one workspace
omarchy-workspaces layout 6 default        # back to the global layout
omarchy-workspaces toggle-layout           # flip the active one; this is SUPER+L
```

There used to be a per-monitor `⟷ Scroll` toggle as well. It is gone: two
controls for one property is one too many, and the keybinding is the one that
was always going to be reached for. A config still carrying the old
`scrollable` key is folded down the first time this plugin reads it — every
workspace on a monitor that was set to scroll gets that as its own override,
so the picture does not change — and any override you had set by hand survives
the fold.

**`SUPER+L` writes those overrides.** Omarchy binds it to a layout toggle whose result *persists*: stock, it writes
`~/.local/state/omarchy/workspace-layouts/<id>.lua`, which `default.hypr.toggles`
loads from `hyprland.lua` **after** `hypr/workspaces.lua`. A file written weeks
ago therefore landed on top of every rule generated here, on every reload, and
won — permanently and silently. One monitor would end up half converted, the
editor said one thing and the screen did another, and the scroll toggle looked
broken because the workspace you were looking at was the one that would not
change.

Two answers to the same question, in two files, with load order deciding. So
the generated Lua rebinds `SUPER+L` to this plugin's own
`toggle-layout`, which writes the pin into `workspaces.json` instead. The key
does exactly what it always did — flip the active workspace between tiling and
scrolling, notification and all — but there is now one place that records it,
and `apply` clears any stale files the stock toggle left behind.

`doctor` checks that the rebind is in place, because losing it means the two
systems are quietly writing separate answers again.

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
# if you rearranged monitors and want the original arrangement back:
# mv ~/.config/hypr/monitors.lua.bak ~/.config/hypr/monitors.lua
rm -f ~/.local/bin/omarchy-workspaces        # only if you linked it
# then drop the `require(...).module("hypr.workspaces")` line from
# ~/.config/hypr/hyprland.lua and reload: hyprctl reload
```

The `require` is guarded, so leaving it in place is harmless — a missing
`workspaces.lua` is skipped rather than breaking the config. Your workspaces
go back to Hyprland's default placement on the next reload either way.

## License

MIT
