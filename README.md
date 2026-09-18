# Workspaces

Pin Hyprland workspaces to monitors, and have each monitor's bar show only its
own. An overview shows every workspace at once, with live window thumbnails.

![Each monitor's bar showing only its own workspaces, above the setup panel that assigns them](preview.png)

![The overview: every workspace at once, with live window thumbnails and the saved presets underneath](overview.png)

- **Plugin ID:** `io.github.kimm-stensborg.workspaces`
- **Kinds:** `bar-widget`, `overlay`, `service`
- **License:** MIT
- **Requires:** Omarchy 4 (Quattro) with `omarchy-shell`, Hyprland with Lua config

## Install

```bash
omarchy plugin add https://github.com/kimm-stensborg/omarchy-workspaces.git
omarchy plugin enable io.github.kimm-stensborg.workspaces --section left
```

That is the whole setup. On first start it spreads 1–10 across your monitors,
writes `~/.config/hypr/workspaces.lua`, and binds the overview to `SUPER` + the
key left of `1`.

To replace the stock widget:

```bash
omarchy plugin enable io.github.kimm-stensborg.workspaces --before omarchy.workspaces
omarchy plugin disable omarchy.workspaces
```

## Update

```bash
omarchy plugin update io.github.kimm-stensborg.workspaces
omarchy-restart-shell
```

## Remove

```bash
omarchy plugin remove io.github.kimm-stensborg.workspaces
rm ~/.config/hypr/workspaces.lua ~/.config/omarchy/workspaces.json ~/.config/omarchy/workspace-presets.json
```

Then drop the `hypr.workspaces` line from `hyprland.lua` and the overview
shortcut from `bindings.lua`.

## What it does

- **Each workspace has a home monitor.** `SUPER+7` takes you to 7's monitor.
- **Each bar shows its own workspaces**, even empty ones, so nothing moves.
- **Identical monitors keep their workspaces**, matched by serial, even when
  `DP-5` and `DP-7` swap.
- **Undocking moves workspaces** to the nearest monitor, and back on return.

## The overview

Open it with **󰖳** in the bar or **`SUPER` + the key left of `1`**.

| Key | Action |
|-----|--------|
| `1`–`9`, `0` / click | go to that workspace |
| arrows / `h` `j` `k` `l` | move the selection |
| `Enter` | go to the selection, or restore the selected preset |
| `Tab` / `↓` from the bottom row | move to the presets (`Tab` / `↑` back) |
| `Del` | delete the selected preset (press twice) |
| `S` | save the desk as a preset |
| `Esc` | close |

### Presets

A preset is the desk as it is now: which apps are open on which workspace, in
what order, and where the floating ones sit. Press **`S`** in the overview,
name it, and press `Enter`. Saving under an existing name replaces it.

The presets sit under the overview. **Click** one — after a reboot, say — and
its apps open on their workspaces:

- **The layout comes back.** Once everything is open, each workspace is tiled
  again the way it was saved: dwindle's splits and their sizes, or scrolling's
  columns, their widths and what is stacked in each. Floating windows get
  their exact size and position back.
- **Already open is reused.** A window of the same app is moved into place
  and only what is missing is launched. Nothing is closed.
- **Terminals** reopen in the directory they were in. What was running in
  them comes back only if it is a program that stays open and is safe to
  start twice — `nvim`, `btop`, `lazygit`, `yazi`, `less`, `man`, `ssh`,
  `tmux`, `herdr` and the like. Anything else, a build or an upgrade, is not
  run again: the terminal comes back as a shell, and `preset show` says what
  was left out. Quitting a program that came back leaves you in a shell.
  Omarchy's own terminal windows — btop, the package installer — are left out.
- **Web apps** reopen on their URL, other apps from their desktop entry.
- **An app that is gone is dropped.** One that is not installed any more is
  skipped and taken out of the preset. One that is installed but does not
  open in time is kept, for next time.

The apps open all at once, so a restore takes about as long as its slowest
app. A notification shows how far it has got and ends with what it did.
Dialogs, file pickers, password prompts and the scratchpad are left out. The
layout is exact on a workspace that holds only the preset's windows — the
desk after a reboot; other windows already there are left where they are.
Hover a preset for **󰅖** to delete it. What the last restore did is in
`~/.local/state/omarchy-workspaces/preset-restore.log`.

To have more programs come back in their terminals, list them under `rerun`
in `~/.config/omarchy/workspace-presets.json`, next to `presets`:

```json
"rerun": ["claude", "opencode"]
```

AI agents are not on the list by default, since an argument to one can be a
prompt it would act on again. The list is checked at restore time as well,
so nothing is run that it does not name.

## The setup panel

```bash
omarchy-shell shell summon io.github.kimm-stensborg.workspaces '{}'
```

**Drag** a workspace to another monitor. **Click** one, or press its number,
to switch it off: no rule, no keybinding. Nothing is written until **Apply**.

Each card shows its screen live, and pointing at a card, or dragging onto it,
lights up the real screen, so identical monitors can't be mixed up.
**Identify** (or `i`) lights them all.

## CLI

```bash
ln -s ~/.config/omarchy/plugins/io.github.kimm-stensborg.workspaces/bin/omarchy-workspaces ~/.local/bin/
```

| Command | What |
|---------|------|
| `doctor` | check Hyprland against the config |
| `status` | where each workspace is now |
| `assign DP-7 1-4` | assign workspaces to a monitor |
| `disable 4,10` / `enable 4` | switch workspaces off and on |
| `apply` | regenerate the rules and reload |
| `open` / `overview` | the setup panel / the overview |
| `preset save Work` | save the open apps as a preset |
| `preset list` / `show Work` | the presets / what one restores |
| `preset restore Work` | restore it (`--dry-run` to see the plan) |
| `preset delete Work` | delete it |

## Config

`~/.config/omarchy/workspaces.json`, applied on save:

```json
{
  "version": 1,
  "count": 10,
  "monitors": {
    "desc:Lenovo Group Limited T27QD-40 VNACDZ5V": [1, 2, 3, 4],
    "desc:Lenovo Group Limited T27QD-40 VNACDZ1G": [5, 6, 7, 8],
    "eDP-1": [9, 10]
  },
  "disabled": []
}
```

Monitors go left to right. `count` is how many workspaces you use; `disabled`
lists the ones that are off.

## Tests

```bash
./test.sh
omarchy plugin validate .
```
