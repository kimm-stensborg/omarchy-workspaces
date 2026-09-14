# Workspaces

Pin Hyprland workspaces to monitors, and have each monitor's bar show only the
workspaces that monitor owns. An overview shows every workspace at once, with
live window thumbnails.

![Each monitor's bar showing only its own workspaces, above the setup panel that assigns them](preview.png)

- **Plugin ID:** `io.github.kimm-stensborg.workspaces`
- **Kinds:** `bar-widget`, `overlay`, `service`
- **License:** MIT
- **Requires:** Omarchy 4 (Quattro) with `omarchy-shell`, Hyprland with Lua config

## Why it exists

On more than one monitor, the stock setup has two problems:

1. **Every bar shows the same ten buttons.** Nothing says which workspaces
   belong to the screen you are looking at.
2. **A workspace has no home.** Hyprland creates it on whichever monitor is
   focused, so the same number ends up on a different screen from one day to
   the next.

Workspaces gives each workspace one monitor, writes that down as Hyprland
rules, and draws each bar from the same list.

## Install

```bash
omarchy plugin add https://github.com/kimm-stensborg/omarchy-workspaces.git
omarchy plugin enable io.github.kimm-stensborg.workspaces --section left
```

Plugins land disabled so the code can be read before it runs. Add
`--enable --yes` to `add` to skip every prompt.

Enabling it is the whole setup. On its first start the service:

- Seeds `~/.config/omarchy/workspaces.json` from your connected monitors,
  spreading 1–10 evenly across them left to right.
- Generates `~/.config/hypr/workspaces.lua` and appends one guarded `require`
  line to `~/.config/hypr/hyprland.lua`.
- Binds the overview to `SUPER` + the key left of `1`, if that key is free.
- Reloads Hyprland, only when something changed.

Every step is a no-op once done. After that it watches `workspaces.json`, so
a hand edit applies on save.

To take the stock widget's place in the bar:

```bash
omarchy plugin enable io.github.kimm-stensborg.workspaces --before omarchy.workspaces
omarchy plugin disable omarchy.workspaces
```

`omarchy plugin enable omarchy.workspaces` puts the stock one back.

## Update

```bash
omarchy plugin update io.github.kimm-stensborg.workspaces
omarchy-restart-shell
```

The shell reloads the bar widget and the service on its own. The setup panel
and the overview only run new code after a restart.

## Remove

```bash
omarchy plugin remove io.github.kimm-stensborg.workspaces
```

The files it put outside its own folder are yours to clean up:

```bash
rm ~/.config/hypr/workspaces.lua ~/.config/omarchy/workspaces.json
rm -f ~/.local/bin/omarchy-workspaces   # only if you linked it
```

Then drop the `require(...).module("hypr.workspaces")` line from
`~/.config/hypr/hyprland.lua`, and the overview shortcut from
`~/.config/hypr/bindings.lua`, and run `hyprctl reload`.

## What it does

- **Pins workspaces to monitors.** Each workspace gets a home monitor and
  stays there. `SUPER+7` moves focus to 7's monitor rather than pulling 7 over
  to you.
- **Keeps them visible.** Assigned workspaces are persistent, so they show in
  the bar even when empty. Nothing appears or moves under the pointer.
- **Filters the bar per monitor.** Each bar shows only its own screen's
  workspaces.
- **Survives identical displays.** Monitors are matched by description,
  including the serial, so two of the same model keep their workspaces when
  `DP-5` and `DP-7` swap after a reboot or a dock reconnect.
- **Survives undocking.** A missing monitor's workspaces move to the nearest
  one that is plugged in, preferring the one to its left, and go back when it
  returns. Nothing is written to disk either way.

## The overview

![Every workspace at once, with live window thumbnails](overview.png)

Every workspace on one screen: a row per monitor, a tile per workspace, all
the same size, and in each tile its windows where they really sit, as live
thumbnails. It shows what Hyprland has right now, so it doubles as a check
that a workspace is where you pinned it.

Open it with **󰖳** after the workspaces in the bar, or with **`SUPER` + the
key left of `1`** (`` ` `` on a US keyboard, `½` on a Nordic one).

| Key | Action |
|-----|--------|
| `1`–`9`, `0` | go to that workspace (`0` is 10) |
| arrows / `h` `j` `k` `l` | move the selection |
| `Enter` / `Space` | go to the selected workspace |
| `Esc` / the shortcut again | close |

Click a tile to go there. Hovering a tile selects it; a click outside the
tiles closes.

The shortcut is written to `bindings.lua` once, if the key is free:

```lua
-- Workspaces (io.github.kimm-stensborg.workspaces)
o.bind("SUPER + code:49", "Workspace overview", "omarchy-shell shell summon io.github.kimm-stensborg.workspaces '{\"view\":\"overview\"}'")
```

- It is bound by key position (`code:49`), so it is the same key whatever
  your layout.
- Move or remove it in the file or with
  [Plugin Manager](https://github.com/kimm-stensborg/omarchy-plugin-manager).
  A removal sticks.
- `omarchy-workspaces bind-overview --force` writes it again.

## The setup panel

```bash
omarchy-shell shell summon io.github.kimm-stensborg.workspaces '{}'
```

Each monitor is a card of the same size, left to right in desk order, named
the way [Displays](https://github.com/kimm-stensborg/omarchy-displays) names
it: `T27QD-40 · DP-5`. Every workspace belongs to exactly one monitor.

- **Drag** a workspace to another monitor.
- **Click** a workspace, or press its number, to switch it off.
- **Identify** puts a big number and the connector name on each physical
  screen for three seconds. The same number is in the corner of each card.
- Nothing is written until **Apply**.

| Key | Action |
|-----|--------|
| `1`–`9`, `0` | switch that workspace off or on |
| `Enter` | apply |
| `Esc` | close without applying |

For **Setup → Workspaces** in the Omarchy menu, paste this before the closing
`}` of `~/.config/omarchy/extensions/omarchy-menu.jsonc`. Keep it on one line:
that is how Plugin Manager finds it.

```jsonc
"setup.workspaces":{"icon":"󰕰","label":"Workspaces","description":"Pin workspaces to monitors","aliases":["workspaces","monitors"],"action":"omarchy-shell shell summon io.github.kimm-stensborg.workspaces '{}'"},
```

## Switching a workspace off

An off workspace gets no rule, no persistence and **no keybinding**. `SUPER+4`
does nothing, and the workspace can't be created at all. Use it to cut ten
workspaces down to the number you actually use.

It keeps its place on its monitor while off, so one click brings it back.

```bash
omarchy-workspaces disable 4,10    # or a range: 7-10
omarchy-workspaces enable 4
```

## The CLI

`bin/omarchy-workspaces` lives in the plugin folder, not on `PATH`. To use it
from a terminal, link it:

```bash
ln -s ~/.config/omarchy/plugins/io.github.kimm-stensborg.workspaces/bin/omarchy-workspaces \
      ~/.local/bin/omarchy-workspaces
```

| Command | What |
|---------|------|
| `doctor` | check the live state against the config |
| `status` | where each workspace lives right now |
| `list` | the layout |
| `assign DP-7 1-4` | assign workspaces (`1-4`, `1,2,5`, `0` for 10) |
| `disable 4,10` / `enable 4` | switch workspaces off and on |
| `apply` | regenerate the rules, reload, re-home |
| `open` | the setup panel |
| `overview` | the overview (toggles) |
| `bind-overview` | write the overview shortcut, if it is not there |

`assign` takes a live output name and stores the stable `desc:` selector for
it.

`doctor` asks Hyprland rather than assuming. It checks that the generated Lua
is current, the `require` is in place, every workspace is on its home monitor,
and every off workspace is gone and unbound. It exits non-zero on any drift,
and `apply` fixes almost everything it finds.

```
  ✓ workspaces.lua matches the config
  ✓ hyprland.lua requires hypr.workspaces
  ✓ the layout is self-consistent
  ✗ placement: 7 on DP-7, home is DP-5
  ✓ keys: 10 bound, 0 unbound

1 problem(s). Run 'omarchy-workspaces apply' to reconcile.
```

## Config

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

- **`monitors`** is in left-to-right order, which decides where workspaces go
  when a monitor is missing. A key is an output name (`eDP-1`) or `desc:` plus
  the description from `hyprctl monitors`. Prefer `desc:`: output names move.
- **`count`** is how many workspaces you use, 10 by default. Omarchy binds
  `SUPER+1` to `SUPER+0`, so ten is the most the keyboard reaches. Set it lower
  and the surplus keys are unbound: `omarchy-workspaces detect --force --count=6`.
- **`disabled`** lists the workspaces that are off. They stay in `monitors`.

## What it remembers

| Path | What |
|------|------|
| `~/.config/omarchy/workspaces.json` | the layout, and the only source of truth |
| `~/.config/hypr/workspaces.lua` | generated workspace rules; every apply overwrites it |
| `~/.config/hypr/hyprland.lua` | gets one guarded `require` line, once |
| `~/.config/hypr/bindings.lua` | gets the overview shortcut, once, if its key is free |
| `~/.local/state/omarchy-workspaces/overview-key` | that the shortcut was offered, so removing it sticks |

## Files

| File | Role |
|------|------|
| `Workspaces.qml` | bar widget: this screen's workspaces and the overview button |
| `Overlay.qml` | overlay: the setup panel and the overview |
| `Service.qml` | service: first-start setup, and applying `workspaces.json` on save |
| `bin/omarchy-workspaces` | CLI: every write to the config and the generated Lua |
| `test.sh` | tests |

## Tests

```bash
./test.sh                  # argument parsing, config transforms, generated Lua
omarchy plugin validate .  # what the shell will accept
```

Saving a file under `~/.config/omarchy/plugins/` reloads the bar widget and the
service. Restart the shell after changing `Overlay.qml` or the manifest's
`kinds`.
