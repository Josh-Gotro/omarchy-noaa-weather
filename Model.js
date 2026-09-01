// Pure helpers for the widget: command building, shell quoting, payload
// shaping and relative time. Kept out of BarWidget.qml so that file stays
// layout and lifecycle only, and so these rules can be read on their own.

function shq(value) {
  var text = String(value === undefined || value === null ? "" : value)
  return "'" + text.replace(/'/g, "'\\''") + "'"
}

// Everything the fetch reports is remote or user-typed text, and all of it is
// rendered as plain text. This is the other half of that rule: control
// characters and angle brackets become spaces (some strings pass through
// shared components like the bar tooltip, whose Text defaults to AutoText
// and would sniff anything tag-shaped as rich text) and every field has a
// hard length cap, so no string from the network can carry markup, terminal
// escape sequences, or enough bytes to matter.
function clip(value, max) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/[\u0000-\u001f\u007f-\u009f<>]/g, " ")
  if (text.length > max) text = text.slice(0, max)
  return text
}

// Builds the weather command from settings, so the only thing a user has to
// type is the location list.
//
// Locations are separated by SEMICOLONS, not commas: "Austin, TX" already
// contains a comma, and splitting on it would turn one city into two bad
// lookups.
//
// The whole run goes under `timeout`: the script keeps its own internal
// budget, but a wedged run must die on a deadline rather than sit on the
// process slot while polls queue behind it. GNU timeout runs the command in
// its own process group and signals the group, so a hung curl three children
// down dies with everything else.
function weatherCommand(opts) {
  var script = String(opts.script === undefined || opts.script === null ? "" : opts.script).trim()
  if (script === "") return ""

  var budget = Number(opts.budget) > 0 ? Math.floor(Number(opts.budget)) : 45

  var env = ""
  function put(name, value) {
    var text = String(value === undefined || value === null ? "" : value).trim()
    if (text !== "") env += name + "=" + shq(text) + " "
  }
  put("WEATHER_UNITS", opts.units)
  put("WEATHER_DAYS", opts.days)
  put("WEATHER_TIMEOUT", opts.timeout)
  put("WEATHER_USER_AGENT", opts.userAgent)
  put("WEATHER_BUDGET", budget)
  if (opts.autoLocate === true) env += "WEATHER_AUTOLOCATE=1 "

  var args = ""
  var raw = opts.locations
  var list = Array.isArray(raw) ? raw : String(raw === undefined || raw === null ? "" : raw).split(";")
  for (var i = 0; i < list.length; i++) {
    var loc = clip(String(list[i]).trim(), 120)
    if (loc !== "") args += " " + shq(loc)
  }

  return env + "timeout -k 5 " + (budget + 10) + " " + shq(script) + args
}

// Settings can arrive as real booleans (hand-edited shell.json) or as strings
// (`omarchy bar set` without --json). Treat the obvious string spellings as the
// booleans the user plainly meant.
function asBool(value, fallback) {
  if (value === true || value === false) return value
  if (value === undefined || value === null) return fallback
  var text = String(value).trim().toLowerCase()
  if (["true", "yes", "on", "1"].indexOf(text) >= 0) return true
  if (["false", "no", "off", "0"].indexOf(text) >= 0) return false
  return fallback
}

function normalizeState(value) {
  var text = String(value === undefined || value === null ? "" : value).toLowerCase().trim()
  if (text === "") return ""
  if (["ok", "up", "good", "pass", "passed", "success", "online", "healthy", "connected", "true"].indexOf(text) >= 0) return "ok"
  if (["warn", "warning", "degraded", "pending", "running", "busy", "partial"].indexOf(text) >= 0) return "warn"
  if (["error", "err", "fail", "failed", "down", "critical", "unhealthy", "false"].indexOf(text) >= 0) return "error"
  if (["offline", "unreachable", "unknown", "idle"].indexOf(text) >= 0) return "offline"
  return clip(text, 16)
}

// A row carries no command and no action: nothing a provider prints can make
// the widget run anything. The only command the widget ever runs by itself is
// the user's own onClick setting.
function normalizeRow(entry) {
  if (entry === undefined || entry === null) return null
  if (typeof entry !== "object") return { label: clip(entry, 64), value: "", state: "", detail: "" }

  var label = entry.label !== undefined ? entry.label : (entry.name !== undefined ? entry.name : "")
  var value = entry.value !== undefined ? entry.value : (entry.status !== undefined ? entry.status : "")
  return {
    label: clip(label, 64),
    value: clip(value, 32),
    state: normalizeState(entry.state !== undefined ? entry.state : entry.status),
    detail: clip(entry.detail, 200)
  }
}

// Accepts the contract, a bare array of rows, or plain text. Anything that
// is not JSON becomes a one-line label, so a provider that only prints a word
// still lights up the bar.
// A page is one location's worth of the same shape, plus a label. Pages let a
// single widget carry several locations without the QML knowing what a city is.
function normalizePage(entry) {
  if (!entry || typeof entry !== "object") return null
  var rows = []
  var source = Array.isArray(entry.rows) ? entry.rows : []
  for (var i = 0; i < source.length && rows.length < 40; i++) {
    var row = normalizeRow(source[i])
    if (row && (row.label !== "" || row.value !== "")) rows.push(row)
  }
  return {
    label: clip(entry.label, 80),
    condition: clip(entry.condition, 64),
    text: clip(entry.text, 32),
    icon: clip(entry.icon, 8),
    state: normalizeState(entry.state),
    tooltip: clip(entry.tooltip, 300),
    rows: rows
  }
}

function normalize(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw).trim()
  if (text === "") return null
  if (text.length > 262144) text = text.slice(0, 262144)

  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return { text: clip(firstLine(text), 120), icon: "", state: "", tooltip: "", rows: [] }
  }

  if (data === null || typeof data !== "object") return { text: clip(data, 120), icon: "", state: "", tooltip: "", rows: [] }
  if (Array.isArray(data)) data = { rows: data }

  var source = Array.isArray(data.rows) ? data.rows : []
  var rows = []
  for (var i = 0; i < source.length && rows.length < 40; i++) {
    var row = normalizeRow(source[i])
    if (row && (row.label !== "" || row.value !== "")) rows.push(row)
  }

  var pages = []
  if (Array.isArray(data.pages)) {
    for (var j = 0; j < data.pages.length && pages.length < 12; j++) {
      var page = normalizePage(data.pages[j])
      if (page) pages.push(page)
    }
  }

  return {
    text: clip(data.text, 32),
    icon: clip(data.icon, 8),
    state: normalizeState(data.state),
    tooltip: clip(data.tooltip, 300),
    rows: rows,
    pages: pages
  }
}

function firstLine(value) {
  return String(value === undefined || value === null ? "" : value).split("\n")[0].trim()
}

function stateGlyph(state, fallback) {
  if (state === "ok") return ""
  if (state === "warn") return ""
  if (state === "error") return ""
  if (state === "offline") return ""
  return fallback
}

function agoText(thenMs, nowMs) {
  if (!thenMs) return "never"
  var seconds = Math.max(0, Math.round((nowMs - thenMs) / 1000))
  if (seconds < 10) return "just now"
  if (seconds < 60) return seconds + "s ago"
  var minutes = Math.round(seconds / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.round(minutes / 60)
  if (hours < 24) return hours + "h ago"
  return Math.round(hours / 24) + "d ago"
}
