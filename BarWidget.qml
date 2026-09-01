import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// NOAA Weather: current conditions and a multi-day forecast in the bar.
//
// Runs a fetch command on a timer and renders whatever it reports as a bar
// pill plus a detail popup. Everything weather-specific lives in the fetch
// script and its jq filter, so this file never learns what a forecast is --
// adding a provider is a script, not a QML change.
//
// Contract the fetch is expected to produce (pages is optional; without it the
// top-level fields are the single page):
//   { "text": "...", "icon": "", "state": "ok|warn|error|offline",
//     "tooltip": "...",
//     "rows": [ { "label": "...", "value": "...", "state": "...",
//                 "detail": "..." } ],
//     "pages": [ { "label": "Austin, TX", "condition": "Clear", ...same... } ] }
//
// Rows are data, never behaviour: the contract has no field that names a
// command, and Model.normalize drops one if a response invents it. Every
// string in the payload is length-capped and control-stripped by Model.clip
// and rendered with Text.PlainText.
//
// A laptop is not always on a network, so "away" is a first-class state rather
// than an error: a DNS or connect failure dims the pill instead of turning it
// urgent. Weather is not worth an alarm colour just because the coffee shop
// wifi is captive.
Panel {
  id: root
  moduleName: "gotro.noaa-weather"
  ipcTarget: "gotro.noaa-weather"
  manageIpc: false

  // ---- Settings, read from this widget's shell.json layout entry
  readonly property string title: String(setting("title", "Weather"))
  // The fetch script lives beside this file, so a user never types a path.
  readonly property string scriptPath:
    Qt.resolvedUrl("weather-fetch").toString().replace(/^file:\/\//, "")
  readonly property string locationsSetting: String(setting("locations", "")).trim()
  readonly property string unitsSetting: String(setting("units", "f")).trim()
  readonly property string daysSetting: String(setting("days", 5))
  readonly property string userAgentSetting: String(setting("userAgent", "")).trim()
  // IP geolocation is consent-gated: it sends this machine's address to a
  // third party, so it stays off until the user flips it on in the editor.
  readonly property bool autoLocateSetting: Model.asBool(setting("autoLocate", false), false)
  readonly property int intervalSec: Math.max(5, Number(setting("refreshIntervalSec", 30)) || 30)
  readonly property int timeoutSec: Math.max(1, Number(setting("timeoutSec", 6)) || 6)
  // `omarchy bar set <id> showText true` writes the STRING "true" unless the
  // caller remembers --json, so a strict === true check silently ignores it
  // (and, worse, "false" is also not === true, so turning it off appeared to
  // work while turning it on did not). Accept both shapes.
  readonly property bool showText: Model.asBool(setting("showText", true), true)
  readonly property string onClickCommand: String(setting("onClick", "")).trim()

  // ---- Fetched state
  property var payload: null
  property string lastError: ""
  property bool busy: false
  property bool pendingPoll: false
  property double lastUpdatedMs: 0
  property double nowMs: Date.now()

  // ---- Cursor state for keyboard navigation in the popup
  property bool cursorActive: false
  property int rowIndex: 0

  // ---- Location editor. Edits the *configured* strings, not the resolved
  // page labels: removing "78701|Home" has to remove that entry, and the page
  // only knows it as "Home".
  property bool editing: false
  property var editList: []
  readonly property bool autoLocated: payload && payload.auto === true

  function configuredLocations() {
    var out = []
    var parts = root.locationsSetting.split(";")
    for (var i = 0; i < parts.length; i++) {
      var t = parts[i].trim()
      if (t !== "") out.push(t)
    }
    return out
  }

  function beginEdit() {
    editList = configuredLocations()
    editing = true
  }

  // Every mutation persists straight away. Staging edits behind a save button
  // meant "add" appeared to do nothing, which is exactly what it looked like.
  function addLocationText(text) {
    var t = String(text === undefined || text === null ? "" : text).trim()
    if (t === "") return
    var next = editList.slice()
    next.push(t)
    editList = next
    persist()
  }

  function removeLocation(index) {
    if (index < 0 || index >= editList.length) return
    var next = editList.slice()
    next.splice(index, 1)
    editList = next
    persist()
  }

  // One click promotes a location to the front, which is what "show this one
  // in the bar" means. Arbitrary reordering stays available over IPC.
  function makePrimary(index) {
    if (index <= 0 || index >= editList.length) return
    moveLocation(index, -index)
  }

  // The first entry is what the bar shows, so reordering is how you pick it.
  function moveLocation(index, delta) {
    var target = index + delta
    if (index < 0 || index >= editList.length) return
    if (target < 0 || target >= editList.length) return
    var next = editList.slice()
    var moved = next.splice(index, 1)[0]
    next.splice(target, 0, moved)
    editList = next
    if (index === 0 || target === 0) pageIndex = 0
    persist()
  }

  // Persisted through Omarchy's own CLI rather than by writing shell.json from
  // QML: `omarchy bar set` owns that file's shape, including which section this
  // widget lives in. The refetch is driven by settings changing, not from here.
  function persist() {
    // Util.execArgv, not bar.run: bar.run is execDetached, which hands a single
    // string to `bash -lc`. Location names are user input, and Util.qml says
    // outright to "prefer this over execDetached for anything built from
    // input" -- argv entries land in positional parameters and are never
    // re-tokenised, so no quoting of ours has to be correct.
    Util.execArgv(["omarchy", "bar", "set", root.moduleName,
                   "locations", editList.join("; ")])
  }

  // The consent switch for IP geolocation. Written with --json so the stored
  // value is a real boolean, though asBool would forgive the string form too.
  function setAutoLocate(value) {
    Util.execArgv(["omarchy", "bar", "set", root.moduleName,
                   "autoLocate", value ? "true" : "false", "--json"])
  }

  // ---- Pages: one per configured location. A single-location payload has no
  // pages at all and everything below falls back to the top-level fields, so
  // the multi-location case costs the simple case nothing.
  property int pageIndex: 0
  readonly property var pages: payload && payload.pages ? payload.pages : []
  readonly property bool paged: pages.length > 1
  readonly property var activePage: pages.length > 0
    ? pages[Math.max(0, Math.min(pageIndex, pages.length - 1))]
    : payload

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property bool configured: scriptPath !== ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var rows: root.activePage && root.activePage.rows ? root.activePage.rows : []


  readonly property string statusKind: {
    if (!configured) return "idle"
    if (lastError !== "") return "error"
    if (!payload) return "idle"
    return payload.state !== "" ? payload.state : "ok"
  }

  readonly property string glyph: payload && payload.icon !== "" && statusKind !== "offline" && statusKind !== "error"
    ? payload.icon
    : Model.stateGlyph(statusKind, "")

  readonly property string barLabel: {
    if (!configured) return "unset"
    if (payload && payload.text !== "" && lastError === "") return payload.text
    if (lastError !== "") return "error"
    return busy ? "…" : "--"
  }

  readonly property string tooltip: {
    if (payload && payload.tooltip !== "" && lastError === "") return payload.tooltip
    if (lastError !== "") return title + ": " + lastError
    return title + ": " + barLabel
  }

  // ---- Fetching

  function fetchCommandText() {
    return Model.weatherCommand({
      script: root.scriptPath,
      locations: root.locationsSetting,
      units: root.unitsSetting,
      days: root.daysSetting,
      timeout: root.timeoutSec,
      userAgent: root.userAgentSetting,
      autoLocate: root.autoLocateSetting,
      budget: 45
    })
  }

  function refresh() {
    if (!configured) {
      lastError = "weather-fetch not found beside the plugin"
      return
    }
    // A fetch of several locations takes seconds. Dropping a request that
    // arrives during one loses it for good -- the widget then keeps showing an
    // older location list until the next scheduled poll. Coalesce instead:
    // remember that something asked, and re-run when this one finishes.
    if (fetchProc.running) { pendingPoll = true; return }

    var command = fetchCommandText()
    if (command === "") {
      lastError = "No url or exec configured"
      return
    }

    busy = true
    fetchProc.command = ["bash", "-lc", command]
    fetchProc.running = true
  }

  // Timer entry point: a scheduled poll is a fresh budget of retries, whereas
  // refresh() on its own is what the fallback retry calls back into.
  function poll() {
    pendingPoll = false
    refresh()
  }

  function applyResponse(raw) {
    var next = Model.normalize(raw)
    if (!next) return
    payload = next
    if (pageIndex >= (next.pages ? next.pages.length : 0)) pageIndex = 0
    lastError = ""
    lastUpdatedMs = Date.now()
    nowMs = lastUpdatedMs
    clampCursor()
  }

  // weather-fetch reports every weather-side problem in-band, as a payload with
  // an explanation. A non-zero exit therefore means the script itself did not
  // run -- missing, not executable, or jq/curl absent -- which is a setup
  // fault, not an outage, and is reported as such.
  function handleFailure(exitCode) {
    var detail = Model.firstLine(errorCollector.text)
    lastError = detail !== "" ? detail
      : (exitCode === 127 ? "weather-fetch could not run (is jq installed?)"
                          : "weather-fetch exited " + exitCode)
  }

  // ---- Popup cursor

  function clampCursor() {
    if (rows.length === 0) {
      rowIndex = 0
      return
    }
    if (rowIndex >= rows.length) rowIndex = rows.length - 1
    if (rowIndex < 0) rowIndex = 0
  }

  function moveCursor(dx, dy) {
    // Left/right pages between locations; up/down moves within one.
    if (dx !== 0) { switchPage(dx); return }
    cursorActive = true
    clampCursor()
    if (dy === 0 || rows.length === 0) return
    rowIndex = Math.max(0, Math.min(rows.length - 1, rowIndex + dy))
  }

  // Wraps, so three locations are two keypresses apart in either direction.
  function switchPage(delta) {
    if (pages.length < 2) return
    pageIndex = (pageIndex + delta + pages.length) % pages.length
    rowIndex = 0
    clampCursor()
  }

  function currentLocation() {
    if (!activePage) return ""
    return (activePage.label !== "" ? activePage.label + " " : "") + activePage.text
  }

  // Scrolls the chip row the minimum distance needed to bring the active chip
  // fully into view, and only when it is actually clipped.
  function ensurePageVisible() {
    if (!switcherFlick.visible) return
    var item = switcherRepeater.itemAt(root.pageIndex)
    if (!item) return

    var viewLeft = switcherFlick.contentX
    var viewWidth = switcherFlick.width
    if (viewWidth <= 0) return
    var pad = Style.space(6)

    var target = viewLeft
    if (item.x - pad < viewLeft) target = item.x - pad
    else if (item.x + item.width + pad > viewLeft + viewWidth)
      target = item.x + item.width + pad - viewWidth

    var maxX = Math.max(0, switcherFlick.contentWidth - viewWidth)
    target = Math.max(0, Math.min(target, maxX))

    if (Math.abs(target - viewLeft) < 1) return
    chipScroll.stop()
    chipScroll.from = viewLeft
    chipScroll.to = target
    chipScroll.start()
  }

  onPageIndexChanged: ensurePageVisible()

  function selectPage(index) {
    if (index < 0 || index >= pages.length) return
    pageIndex = index
    rowIndex = 0
    clampCursor()
  }

  // The ONLY command this widget ever runs from the popup is the user's own
  // onClick setting. Rows carry no actions: nothing a provider or a network
  // response prints can name a command to execute (Model.normalizeRow drops
  // any such field before it gets here).
  function runAction(command) {
    var text = String(command || "").trim()
    if (text !== "" && bar) bar.run(text)
  }

  function stateColor(state) {
    if (state === "error") return urgent
    if (state === "warn") return Qt.lighter(urgent, 1.25)
    if (state === "offline" || state === "") return dim
    return foreground
  }

  implicitWidth: barRow.implicitWidth + Style.space(14)
  implicitHeight: barSize

  Process {
    id: fetchProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyResponse(text)
    }

    stderr: StdioCollector {
      id: errorCollector
      waitForEnd: true
    }

    onExited: function(exitCode, exitStatus) {
      root.busy = false
      if (exitCode !== 0) root.handleFailure(exitCode)
      // Settings changed while this was in flight: the result just applied is
      // already stale, so go again rather than wait out the poll interval.
      if (root.pendingPoll) {
        root.pendingPoll = false
        coalesceTimer.restart()
      }
    }
  }

  Timer {
    id: pollTimer
    interval: root.intervalSec * 1000
    running: root.configured
    repeat: true
    triggeredOnStart: true
    onTriggered: root.poll()
  }

  // Re-fetch whenever the configured locations change, whoever changed them --
  // the editor here, `omarchy bar set` in a terminal, or a hand edit of
  // shell.json. Debounced so a burst of edits costs one fetch.
  // Hook the injected `settings` object rather than the derived properties.
  // A readonly binding that nothing else depends on is evaluated lazily, so
  // locationsSetting does not re-evaluate -- and therefore emits no change
  // signal -- until something reads it. `settings` is assigned outright by the
  // bar, so its change signal always fires.
  // Deliberately does NOT resync editList while the editor is open. `bar.run`
  // is detached, so settings arrive some time after a write -- possibly still
  // describing the previous state. Resyncing from that stale value reset the
  // list mid-edit, which is why entries went missing and a row's name flipped
  // between two locations while being moved. The editor owns the list while it
  // is open; it is re-read on beginEdit().
  onSettingsChanged: settleTimer.restart()

  Timer {
    id: settleTimer
    // Long enough that adding three locations in a row is one refetch, not
    // three -- each of which would re-fetch every location and risk NOAA's
    // rate limiter.
    interval: 1200
    repeat: false
    onTriggered: root.poll()
  }

  // A tick off the Process signal, so the re-run happens after this fetch has
  // fully settled rather than from inside its own exit handler.
  Timer {
    id: coalesceTimer
    interval: 60
    repeat: false
    onTriggered: root.poll()
  }

  // Last-resort deadline, above the script's own: the command runs under
  // `timeout -k` (55s hard ceiling), so this should never fire. If it does --
  // timeout missing, a wedged pipe -- kill the process rather than let every
  // later poll queue behind it forever.
  Timer {
    interval: 70000
    running: fetchProc.running
    repeat: false
    onTriggered: {
      fetchProc.running = false
      root.busy = false
      root.lastError = "fetch exceeded its deadline and was stopped"
    }
  }

  // Keeps "updated 2m ago" honest while someone is looking at it, and idle
  // when nobody is.
  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.poll(); return "ok" }
    function status(): string { return root.statusKind + " " + root.barLabel }

    // Location switching over IPC, so it can be bound to a key or scripted.
    function next(): string { root.switchPage(1); return root.currentLocation() }
    function prev(): string { root.switchPage(-1); return root.currentLocation() }
    function page(index: string): string {
      root.selectPage(parseInt(index, 10))
      return root.currentLocation()
    }
    // Opening the editor over IPC makes it bindable to a key, and testable.
    function settings(): string {
      if (root.editing) { root.editing = false; return "closed" }
      root.open(); root.beginEdit(); return "editing " + root.editList.length + " location(s)"
    }
    function add(location: string): string {
      root.beginEdit(); root.addLocationText(location)
      return "added " + location
    }
    function remove(index: string): string {
      root.beginEdit(); root.removeLocation(parseInt(index, 10))
      return "removed index " + index
    }
    function move(index: string, delta: string): string {
      root.beginEdit(); root.moveLocation(parseInt(index, 10), parseInt(delta, 10))
      return root.editList.join("; ")
    }

    function locations(): string {
      var out = []
      for (var i = 0; i < root.pages.length; i++) out.push(root.pages[i].label + " " + root.pages[i].text)
      return out.join(" | ")
    }
    // Prints the exact one-liner the widget runs, the fastest way to tell a
    // config mistake apart from an endpoint that is simply down.
    function command(): string { return root.fetchCommandText() }
  }

  // The bar item is a Row plus its own MouseArea rather than a WidgetButton:
  // WidgetButton paints a single centred Text and cannot carry anything else.
  // This mirrors how omarchy.media builds its bar item.
  Item {
    id: button
    anchors.fill: parent
    opacity: root.statusKind === "offline" || root.statusKind === "idle" ? 0.45 : 1

    Behavior on opacity {
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    Row {
      id: barRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      // The icon is the weather itself -- a glyph chosen from the current
      // conditions by weather.jq -- so it changes with the forecast and tints
      // with the theme. A static image would do neither.
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.glyph
        textFormat: Text.PlainText
        color: root.stateColor(root.statusKind)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.vertical && root.showText && root.barLabel !== ""
        text: root.barLabel
        textFormat: Text.PlainText
        color: root.stateColor(root.statusKind)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        renderType: Text.NativeRendering

        Behavior on color {
          enabled: !root.bar || root.bar.foregroundAnimationEnabled
          ColorAnimation { duration: 160 }
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.poll()
        else if (mouse.button === Qt.MiddleButton) root.runAction(root.onClickCommand)
        else root.toggle()
      }
      onEntered: if (root.bar) root.bar.showTooltip(button, root.tooltip)
      onExited: if (root.bar) root.bar.hideTooltip(button)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          return
        }
        root.moveCursor(dx, dy)
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.poll()
        else if (text === "o" || text === "O") root.runAction(root.onClickCommand)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            // The city is the heading; the plugin's own name is not news to
            // someone who just clicked it.
            title: root.activePage && root.activePage.label !== "" ? root.activePage.label : root.title
            meta: root.busy ? "Checking…" : (root.activePage ? root.activePage.text : root.barLabel)
            // Must stay short: PanelHero renders this as a right-hand chip, and
            // a long string pushes the title out of the header entirely.
            detail: root.activePage && root.activePage.condition !== "" ? root.activePage.condition : root.title
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.statusKind === "offline" || root.statusKind === "idle" ? 0.5 : 1.0

            iconComponent: Component {
              Text {
                text: root.activePage && root.activePage.icon !== "" ? root.activePage.icon : root.glyph
                textFormat: Text.PlainText
                color: root.stateColor(root.activePage ? root.activePage.state : root.statusKind)
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // Toolbar: location chips on the left, settings cog on the right.
          Item {
            width: parent.width
            implicitHeight: Math.max(switcherFlick.height, cogButton.height)

          Flickable {
            id: switcherFlick
            visible: root.paged && !root.editing
            anchors.left: parent.left
            anchors.right: cogButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            height: switcherRow.implicitHeight
            contentWidth: switcherRow.implicitWidth
            contentHeight: switcherRow.implicitHeight
            clip: true
            flickableDirection: Flickable.HorizontalFlick
            interactive: contentWidth > width

            // Arrowing to a location off the end of the row used to show its
            // forecast while its chip stayed out of sight. Follow the
            // selection instead of making the user drag the row.
            NumberAnimation {
              id: chipScroll
              target: switcherFlick
              property: "contentX"
              duration: 180
              easing.type: Easing.OutCubic
            }

            onWidthChanged: root.ensurePageVisible()
            onContentWidthChanged: root.ensurePageVisible()

            Row {
              id: switcherRow
              spacing: Style.space(10)

              Repeater {
                id: switcherRepeater
                model: root.pages

                Item {
                  required property var modelData
                  required property int index
                  implicitWidth: chip.implicitWidth + Style.space(12)
                  implicitHeight: chip.implicitHeight + Style.space(8)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.space(4)
                    color: index === root.pageIndex ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                                                    : "transparent"
                  }

                  Text {
                    id: chip
                    anchors.centerIn: parent
                    text: (modelData.label !== "" ? modelData.label : "?")
                          + (modelData.text !== "" ? "  " + modelData.text : "")
                    textFormat: Text.PlainText
                    color: modelData.state === "error" ? root.urgent
                         : index === root.pageIndex ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: index === root.pageIndex
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectPage(index)
                  }
                }
              }
            }
          }

            Text {
              visible: !root.paged && !root.editing
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.autoLocated ? "Location detected automatically" : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              visible: root.editing
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Locations"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            PanelActionButton {
              id: cogButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.editing ? "" : ""   // times / cog
              tooltipText: root.editing ? "Close settings" : "Edit locations"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.editing ? root.editing = false : root.beginEdit()
            }
          }

          // ---- Location editor -------------------------------------------
          // Every action here persists immediately. An earlier version staged
          // changes behind a save button, which read as "add" doing nothing.
          Column {
            visible: root.editing
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.editList

              Item {
                required property var modelData
                required property int index
                width: parent.width
                implicitHeight: Math.max(locText.implicitHeight, rowButtons.height) + Style.space(8)

                // Choosing what the bar shows is the whole point of order, so it
                // is one click on the row rather than nudging with arrows.
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: index === 0 ? Qt.ArrowCursor : Qt.PointingHandCursor
                  onClicked: root.makePrimary(index)
                }

                Text {
                  id: primaryMark
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: index === 0 ? "\uf111" : "\uf10c"
                  color: index === 0 ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  id: locText
                  anchors.left: primaryMark.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: rowButtons.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData + (index === 0 ? "   · in the bar" : "")
                  textFormat: Text.PlainText
                  color: index === 0 ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                // One arrow, not a pair: down is just up on the row below, and
                // two chevrons side by side in a narrow row are hard to hit.
                // These are buttons declared after the row's MouseArea, so they
                // take the click rather than promoting the row.
                Row {
                  id: rowButtons
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  PanelActionButton {
                    iconText: "\uf077"
                    tooltipText: index === 0 ? "Already in the bar" : "Move up"
                    enabled: index > 0
                    opacity: enabled ? 1 : 0.25
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.moveLocation(index, -1)
                  }

                  PanelActionButton {
                    iconText: "\uf1f8"
                    tooltipText: "Remove"
                    foreground: root.foreground
                    hoverColor: root.urgent
                    fontFamily: root.fontFamily
                    onClicked: root.removeLocation(index)
                  }
                }
              }
            }

            Text {
              visible: root.editList.length === 0
              width: parent.width
              text: root.autoLocated
                ? "Using your detected location. Add one below to pin your own."
                : "No locations yet. Add one below."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Consent switch for IP geolocation. It only matters while no
            // location is configured (a configured location always wins and
            // nothing is ever sent), so it only shows then -- and it is off
            // until the user clicks it, because turning it on sends this
            // machine's IP address to a third party.
            Item {
              visible: root.editList.length === 0
              width: parent.width
              implicitHeight: autoRow.implicitHeight + Style.space(8)

              Row {
                id: autoRow
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Text {
                  text: root.autoLocateSetting ? "" : ""
                  color: root.autoLocateSetting ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  text: "Detect my location automatically"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setAutoLocate(!root.autoLocateSetting)
              }
            }

            Text {
              visible: root.editList.length === 0
              width: parent.width
              text: "This sends your IP address to ipapi.co to guess a city. It stays off until you turn it on, and stops the moment you add a location."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(addField.height, addButton.height)

              // No two-way binding to a property here: the field owns its text
              // and the button reads it. Binding `text:` while also writing it
              // back on every keystroke is a loop waiting to misbehave.
              TextField {
                id: addField
                anchors.left: parent.left
                anchors.right: addButton.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                placeholderText: "ZIP, city, or lat,lon, then Enter"
                foreground: root.foreground
                onAccepted: { root.addLocationText(addField.text); addField.text = "" }
              }

              PanelActionButton {
                id: addButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "\uf067"
                tooltipText: "Add location"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: { root.addLocationText(addField.text); addField.text = "" }
              }
            }

            Text {
              width: parent.width
              text: "Saved as you go. Click a location to put it in the bar, or ⌃ to move it up one."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
          PanelSeparator {
            visible: root.rows.length > 0
            foreground: root.foreground
          }

          Column {
            visible: root.rows.length > 0 && !root.editing
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.rows

              StatusRow {
                required property var modelData
                required property int index
                width: parent.width
                row: modelData
                position: index
              }
            }
          }

          Text {
            visible: root.rows.length === 0 && root.lastError === "" && root.payload !== null
            width: parent.width
            text: "Connected, but the response carried no rows. Add a jq filter that emits rows[] to break the detail out here."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          // Attribution. NOAA asks that its data be credited, and it is also
          // the honest answer to "where did this number come from?".
          Text {
            width: parent.width
            text: "Forecast data from NOAA · weather.gov"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: "Updated " + Model.agoText(root.lastUpdatedMs, root.nowMs) + " · r refresh"
              + (root.paged ? " · ←/→ location" : "")
              + (root.onClickCommand !== "" ? " · o open" : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  component StatusRow: CursorSurface {
    id: statusRow

    property var row: null
    property int position: 0

    hasCursor: root.cursorActive && root.rowIndex === position
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    // Rows are display only. They deliberately carry no click action: a row's
    // content comes from the network, and remote content must never choose
    // what runs on this machine.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onEntered: {
        root.cursorActive = true
        root.rowIndex = statusRow.position
      }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: statusRow.row ? statusRow.row.label : ""
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          visible: statusRow.row && statusRow.row.detail !== ""
          Layout.fillWidth: true
          text: statusRow.row ? statusRow.row.detail : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        text: statusRow.row ? statusRow.row.value : ""
        textFormat: Text.PlainText
        color: statusRow.row ? root.stateColor(statusRow.row.state) : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
}
