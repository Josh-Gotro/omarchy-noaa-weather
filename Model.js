// Pure helpers for the widget: command building, shell quoting, payload
// shaping and relative time. Kept out of BarWidget.qml so that file stays
// layout and lifecycle only, and so these rules can be read on their own.

function shq(value) {
  var text = String(value === undefined || value === null ? "" : value)
  return "'" + text.replace(/'/g, "'\\''") + "'"
}

// Builds the weather command from settings, so the only thing a user has to
// type is the location list. `exec` remains available as a full override.
//
// Locations are separated by SEMICOLONS, not commas: "Austin, TX" already
// contains a comma, and splitting on it would turn one city into two bad
// lookups.
function weatherCommand(opts) {
  var script = String(opts.script === undefined || opts.script === null ? "" : opts.script).trim()
  if (script === "") return ""

  var env = ""
  function put(name, value) {
    var text = String(value === undefined || value === null ? "" : value).trim()
    if (text !== "") env += name + "=" + shq(text) + " "
  }
  put("WEATHER_UNITS", opts.units)
  put("WEATHER_DAYS", opts.days)
  put("WEATHER_TIMEOUT", opts.timeout)
  put("WEATHER_USER_AGENT", opts.userAgent)
  put("WEATHER_PROVIDER", opts.provider)

  var args = ""
  var raw = opts.locations
  var list = Array.isArray(raw) ? raw : String(raw === undefined || raw === null ? "" : raw).split(";")
  for (var i = 0; i < list.length; i++) {
    var loc = String(list[i]).trim()
    if (loc !== "") args += " " + shq(loc)
  }

  return env + shq(script) + args
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
  return text
}

function normalizeRow(entry) {
  if (entry === undefined || entry === null) return null
  if (typeof entry !== "object") return { label: String(entry), value: "", state: "", detail: "", action: "" }

  var label = entry.label !== undefined ? entry.label : (entry.name !== undefined ? entry.name : "")
  var value = entry.value !== undefined ? entry.value : (entry.status !== undefined ? entry.status : "")
  return {
    label: String(label === null ? "" : label),
    value: String(value === null ? "" : value),
    state: normalizeState(entry.state !== undefined ? entry.state : entry.status),
    detail: String(entry.detail === undefined || entry.detail === null ? "" : entry.detail),
    action: String(entry.action === undefined || entry.action === null ? "" : entry.action)
  }
}

// Accepts the contract, a bare array of rows, or plain text. Anything that
// is not JSON becomes a one-line label, so a gateway that only prints a word
// still lights up the bar.
// A page is one location's worth of the same shape, plus a label. Pages let a
// single widget carry several locations without the QML knowing what a city is.
function normalizePage(entry) {
  if (!entry || typeof entry !== "object") return null
  var rows = []
  var source = Array.isArray(entry.rows) ? entry.rows : []
  for (var i = 0; i < source.length && rows.length < 100; i++) {
    var row = normalizeRow(source[i])
    if (row && (row.label !== "" || row.value !== "")) rows.push(row)
  }
  return {
    label: String(entry.label === undefined || entry.label === null ? "" : entry.label),
    condition: String(entry.condition === undefined || entry.condition === null ? "" : entry.condition),
    text: String(entry.text === undefined || entry.text === null ? "" : entry.text),
    icon: String(entry.icon === undefined || entry.icon === null ? "" : entry.icon),
    state: normalizeState(entry.state),
    tooltip: String(entry.tooltip === undefined || entry.tooltip === null ? "" : entry.tooltip),
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
    return { text: firstLine(text).slice(0, 120), icon: "", state: "", tooltip: "", rows: [] }
  }

  if (data === null || typeof data !== "object") return { text: String(data), icon: "", state: "", tooltip: "", rows: [] }
  if (Array.isArray(data)) data = { rows: data }

  var source = Array.isArray(data.rows) ? data.rows : []
  var rows = []
  for (var i = 0; i < source.length && rows.length < 100; i++) {
    var row = normalizeRow(source[i])
    if (row && (row.label !== "" || row.value !== "")) rows.push(row)
  }

  var pages = []
  if (Array.isArray(data.pages)) {
    for (var j = 0; j < data.pages.length && pages.length < 24; j++) {
      var page = normalizePage(data.pages[j])
      if (page) pages.push(page)
    }
  }

  return {
    text: String(data.text === undefined || data.text === null ? "" : data.text),
    icon: String(data.icon === undefined || data.icon === null ? "" : data.icon),
    state: normalizeState(data.state),
    tooltip: String(data.tooltip === undefined || data.tooltip === null ? "" : data.tooltip),
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
