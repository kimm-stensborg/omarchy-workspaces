// node test.js -- checks Model.js without a shell.
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

const src = fs.readFileSync(path.join(__dirname, "Model.js"), "utf8").replace(/^\.pragma library.*$/m, "")
const M = {}
vm.createContext(M)
vm.runInContext(src, M)

let failed = 0
function test(name, fn) {
  try { fn(); console.log("ok   " + name) } catch (e) { failed++; console.log("FAIL " + name + "\n     " + e.message) }
}
const plain = v => JSON.parse(JSON.stringify(v))
const ids = rows => rows.map(r => r.workspaces)

// The desk: two 1440p screens side by side and the laptop to their right.
const DP7 = { name: "DP-7", x: 0, y: 0, width: 2560, height: 1440 }
const DP5 = { name: "DP-5", x: 2560, y: 0, width: 2560, height: 1440 }
const EDP = { name: "eDP-1", x: 5120, y: 240, width: 1536, height: 960 }
const on = (monitor, ...list) => list.map(id => ({ id, monitor: monitor.name }))
const DESK = [...on(DP7, 1, 2, 3, 4), ...on(DP5, 5, 6, 7, 8), ...on(EDP, 9, 10)]

test("overviewRows: one row per monitor, left to right", () => {
  const rows = M.overviewRows([EDP, DP5, DP7], DESK)
  assert.deepStrictEqual(plain(rows.map(r => r.name)), ["DP-7", "DP-5", "eDP-1"])
  assert.deepStrictEqual(plain(ids(rows)), [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10]])
  assert.ok(rows.every(r => !r.continued))
})

test("overviewRows: workspaces sorted, scratchpads and empty monitors left out", () => {
  const rows = M.overviewRows([DP7, DP5], [...on(DP7, 3, 1, -98, 2)])
  assert.deepStrictEqual(plain(ids(rows)), [[1, 2, 3]])
  assert.deepStrictEqual(plain(rows.map(r => r.name)), ["DP-7"])
})

test("overviewRows: a lone monitor wraps 4-4-2, labelled once", () => {
  const rows = M.overviewRows([EDP], on(EDP, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1))
  assert.deepStrictEqual(plain(ids(rows)), [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10]])
  assert.deepStrictEqual(plain(rows.map(r => r.continued)), [false, true, true])
  assert.ok(rows.every(r => r.name === "eDP-1" && r.width === 1536))
})

test("overviewRows: two monitors do not wrap, however many workspaces", () => {
  const rows = M.overviewRows([DP7, DP5], [...on(DP7, 1, 2, 3, 4, 5, 6, 7), ...on(DP5, 8)])
  assert.deepStrictEqual(plain(ids(rows)), [[1, 2, 3, 4, 5, 6, 7], [8]])
})

test("overviewRows: four or fewer on a lone monitor stay one row", () => {
  assert.deepStrictEqual(plain(ids(M.overviewRows([EDP], on(EDP, 1, 2, 3)))), [[1, 2, 3]])
})

test("tileAspect: the widest monitor's shape", () => {
  assert.strictEqual(M.tileAspect(M.overviewRows([DP7, EDP], [...on(DP7, 1), ...on(EDP, 2)])), 16 / 9)
  assert.strictEqual(M.tileAspect([]), 16 / 9)
})

const SPACE = { width: 1800, height: 1000, labelHeight: 30, rowGap: 28, tileGap: 16, aspect: 16 / 10, minHeight: 48 }

test("tileHeight: the longest row sets the width limit", () => {
  const rows = [{ workspaces: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] }]
  const h = M.tileHeight(rows, SPACE)
  assert.ok(Math.abs(h * 1.6 * 10 + 9 * 16 - 1800) < 1e-9, h)
})

test("tileHeight: wrapped rows pay a tile gap, not a label", () => {
  const rows = M.wrapRow({ name: "eDP-1", workspaces: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] }, 4)
  // Wide enough that four across is not the limit: one label and two tile
  // gaps come off the height, and the three rows share the rest.
  const wide = Object.assign({}, SPACE, { width: 2400, height: 600 })
  assert.strictEqual(M.tileHeight(rows, wide), (600 - 30 - 16 - 16) / 3)
  // Given more height, 30% of it is the ceiling.
  assert.strictEqual(M.tileHeight(rows, Object.assign({}, wide, { height: 1000 })), 300)
})

test("tileHeight: never below the minimum, nothing for no rows", () => {
  assert.strictEqual(M.tileHeight([{ workspaces: [1] }], Object.assign({}, SPACE, { height: 50 })), 48)
  assert.strictEqual(M.tileHeight([], SPACE), 0)
})

const WRAPPED = M.overviewRows([EDP], on(EDP, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10))

test("step: left and right run on into the next row", () => {
  assert.strictEqual(M.step(WRAPPED, 4, 0, 1).selected, 5)
  assert.strictEqual(M.step(WRAPPED, 5, 0, -1).selected, 4)
  assert.strictEqual(M.step(WRAPPED, 1, 0, -1).selected, 1)
  assert.strictEqual(M.step(WRAPPED, 10, 0, 1).selected, 10)
})

test("step: up and down keep the column as far as the row is long", () => {
  assert.strictEqual(M.step(WRAPPED, 2, 1, 0).selected, 6)
  assert.strictEqual(M.step(WRAPPED, 8, 1, 0).selected, 10)
  assert.strictEqual(M.step(WRAPPED, 10, -1, 0).selected, 6)
  assert.strictEqual(M.step(WRAPPED, 3, -1, 0).selected, 3)
})

test("step: down from the bottom row goes to the presets", () => {
  const next = M.step(WRAPPED, 9, 1, 0)
  assert.strictEqual(next.presets, true)
  assert.strictEqual(next.selected, 9)
})

test("moveWindow: moves without following", () => {
  assert.strictEqual(M.moveWindow("0x55d1a2b3c4d0", 1, 3),
    'hl.dsp.window.move({ window = "address:0x55d1a2b3c4d0", workspace = "3", follow = false })')
  assert.strictEqual(M.moveWindow("55d1a2b3c4d0", 1, 10),
    'hl.dsp.window.move({ window = "address:0x55d1a2b3c4d0", workspace = "10", follow = false })')
})

test("moveWindow: nothing for a drop where it came from, off a tile, or no window", () => {
  assert.strictEqual(M.moveWindow("0xabc", 3, 3), "")
  assert.strictEqual(M.moveWindow("0xabc", 3, 0), "")
  assert.strictEqual(M.moveWindow("", 3, 4), "")
  assert.strictEqual(M.moveWindow(undefined, 3, 4), "")
  assert.strictEqual(M.moveWindow('0xabc", workspace = "1', 3, 4), "")
})

if (failed) { console.log(failed + " failed"); process.exit(1) }
