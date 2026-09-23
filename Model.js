.pragma library

// Pure logic for the overview: which workspaces go in which row, how big a
// tile can be, where the arrow keys take the selection, which workspace a
// number-row key names, and the dispatch that moves a window to another. Nothing here touches QML, so
// `node test.js` covers it. Overlay.qml turns Hyprland's objects into the
// plain data these functions take.

// A lone monitor's ten workspaces in one row would make every tile a sliver.
var WRAP = 4

// One row per monitor, left to right, holding the workspaces on it, lowest
// first. Special workspaces (negative ids) are scratchpads, not places, and a
// monitor with nothing on it gets no row. With only one row left, it wraps.
//
// monitors: [{ name, x, y, width, height }], width and height logical.
// workspaces: [{ id, monitor }], monitor being the monitor's name.
function overviewRows(monitors, workspaces) {
  var sorted = monitors.slice().sort(function (left, right) {
    return (left.x - right.x) || (left.y - right.y)
  })
  var rows = []
  for (var m = 0; m < sorted.length; m++) {
    var monitor = sorted[m]
    var ids = []
    for (var w = 0; w < workspaces.length; w++) {
      if (workspaces[w].id > 0 && workspaces[w].monitor === monitor.name) ids.push(workspaces[w].id)
    }
    if (ids.length === 0) continue
    ids.sort(function (a, b) { return a - b })
    rows.push({ name: String(monitor.name), x: monitor.x, y: monitor.y,
                width: monitor.width, height: monitor.height, workspaces: ids })
  }
  return rows.length === 1 ? wrapRow(rows[0], WRAP) : rows
}

// The row cut into rows of `perRow`: 4-4-2 for ten. Only the first carries
// the monitor's name; the rest are `continued` and go unlabelled.
function wrapRow(row, perRow) {
  var out = []
  for (var i = 0; i < row.workspaces.length; i += perRow) {
    out.push({ name: row.name, x: row.x, y: row.y, width: row.width, height: row.height,
               workspaces: row.workspaces.slice(i, i + perRow), continued: i > 0 })
  }
  return out
}

// Every tile is the same size, in the widest monitor's shape, so the columns
// line up and no workspace looks lesser for its screen.
function tileAspect(rows) {
  if (rows.length === 0) return 16 / 9
  var widest = 0
  for (var i = 0; i < rows.length; i++) widest = Math.max(widest, rows[i].width / rows[i].height)
  return widest
}

// The largest tile height that lets the rows stack and the longest row fit.
// A labelled row pays for its label and, after the first, the gap between
// monitors; a continued row only a tile gap. Past 30% of the height a bigger
// tile is not a clearer one, and below `minHeight` it is not a tile.
//
// o: { width, height, labelHeight, rowGap, tileGap, aspect, minHeight }
function tileHeight(rows, o) {
  if (rows.length === 0) return 0
  var chrome = 0
  for (var r = 0; r < rows.length; r++)
    chrome += rows[r].continued ? o.tileGap : o.labelHeight + (r > 0 ? o.rowGap : 0)
  var best = (o.height - chrome) / rows.length
  for (var i = 0; i < rows.length; i++) {
    var count = rows[i].workspaces.length
    best = Math.min(best, (o.width - (count - 1) * o.tileGap) / (count * o.aspect))
  }
  return Math.max(o.minHeight, Math.min(best, o.height * 0.3))
}

function position(rows, id) {
  for (var r = 0; r < rows.length; r++) {
    var column = rows[r].workspaces.indexOf(id)
    if (column !== -1) return { row: r, column: column }
  }
  return { row: 0, column: -1 }
}

// Where the arrow keys take the selection. Left and right run on into the
// next row, so every tile is reachable with two keys; up and down keep the
// column as far as the row is long. Down from the bottom row leaves the desk
// for the presets, which the result says as `presets: true`.
function step(rows, selected, rowStep, columnStep) {
  if (rows.length === 0) return { selected: selected, presets: false }
  var at = position(rows, selected)
  if (rowStep > 0 && at.row === rows.length - 1) return { selected: selected, presets: true }
  var row = at.row
  var column = at.column + columnStep
  if (column < 0 && row > 0 && columnStep !== 0) {
    row--
    column = rows[row].workspaces.length - 1
  } else if (column >= rows[row].workspaces.length && row < rows.length - 1) {
    row++
    column = 0
  }
  row = Math.max(0, Math.min(rows.length - 1, row + rowStep))
  column = Math.max(0, Math.min(rows[row].workspaces.length - 1, column))
  return { selected: rows[row].workspaces[column], presets: false }
}

// The Hyprland call that sends a window to another workspace and leaves the
// focus where it is, or "" when there is nothing to do: a drop back where it
// came from, off every tile, or with no window to name.
function moveWindow(address, from, to) {
  var id = Number(to)
  var hex = String(address || "")
  if (!/^(0x)?[0-9a-fA-F]+$/.test(hex) || !(id > 0) || id === Number(from)) return ""
  if (hex.indexOf("0x") !== 0) hex = "0x" + hex
  return "hl.dsp.window.move({ window = \"address:" + hex + "\", workspace = \"" + id + "\", follow = false })"
}

// The workspace a key on the number row stands for, 1–10, or 0 for any other
// key. Read by position (xkb keycode, `1` is 10), as the workspace bindings
// are: with Shift held, what the key types depends on the layout — `"` or
// `#` or `§` — but which key it is does not.
function numberRowSlot(scanCode) {
  var code = Number(scanCode)
  return code >= 10 && code <= 19 ? code - 9 : 0
}
