import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Cockpit companion: a read-only window into the Obsidian Cockpit vault —
// a schedule (compact week row, expandable to the full month grid) with the
// selected day's tasks (expandable to their note body) beneath it, overdue
// tasks, configurable checklist meters, and a task-attached pomodoro timer
// whose section only appears while a pomodoro is live.
//
// The vault is NEVER written to. All parsing happens in cockpit-scan.py,
// which reads Tasks/Active/*.md (frontmatter + body) and the cockpit-board
// plugin's own pomodoro settings, and prints one JSON document.
//
// Design rules learned the hard way (cold-start freeze incident):
//  - The panel content is NOT instantiated at shell startup. It loads once,
//    on the first open, via contentLoader. Until then the plugin is just a
//    bar button, a scanner process and a little pomodoro state.
//  - Repeater models are stored properties rebuilt by explicit functions
//    (applyScan / calRebuild), never computed inside property bindings, and
//    nothing model-shaped depends on the 1-second clock.
//  - A rescan whose JSON is byte-identical to the applied one is dropped
//    before parsing, so the 60s timer normally causes zero UI work.
Panel {
  id: root
  moduleName: "andreconde.cockpit"
  ipcTarget: "andreconde.cockpit"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function plainText(s) {
    return String(s === undefined || s === null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
  }

  // Ticks once a second ONLY while the pomodoro is running; nothing else in
  // the plugin does per-second work. An idle open panel is fully quiescent.
  property double nowMs: Date.now()

  // ---------------------------------------------------- inactivity auto-close
  //
  // The shell's idle cycle (screensaver after 150s, lock after 300s of no
  // input) has no notion of open panels, and an Overlay-layer panel holding
  // OnDemand keyboard focus through a screensaver cycle wedged the shell in
  // testing (main thread spin, no QML errors). Panels are ephemeral UI —
  // never let this one sit open unattended into an idle cycle: close it
  // after autoCloseSec without any interaction (keys, clicks, or pointer
  // movement over the panel), safely below the 150s screensaver threshold.

  readonly property int autoCloseMs: {
    var secs = Number(setting("autoCloseSec", 120))
    if (!isFinite(secs)) secs = 120
    return clamp(secs, 30, 145) * 1000
  }

  function touchActivity() {
    if (opened) autoCloseTimer.restart()
  }

  Timer {
    id: autoCloseTimer
    interval: root.autoCloseMs
    running: root.opened
    repeat: false
    onTriggered: root.close()
  }

  // ------------------------------------------------------------ vault scan

  readonly property string scriptPath: {
    var url = Qt.resolvedUrl("cockpit-scan.py").toString()
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }
  readonly property string vaultDir: String(setting("vaultDir", "~/Obsidian"))
  readonly property string checklistPatterns: String(setting("checklistPatterns", ""))

  property var scanData: ({})
  property string appliedScanText: ""
  readonly property var overdueTasks: scanData && scanData.overdue ? scanData.overdue : []
  readonly property var todayTasks: scanData && scanData.todayTasks ? scanData.todayTasks : []
  readonly property int overdueCount: scanData ? Number(scanData.overdueCount || 0) : 0
  readonly property var followups: scanData && scanData.followups ? scanData.followups : []

  function applyScan(text) {
    if (text === appliedScanText) return    // unchanged vault: no UI work
    var parsed
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      console.warn("cockpit", "bad scan output", e)
      return
    }
    if (parsed && parsed.error) {
      console.warn("cockpit", parsed.error)
      return
    }
    appliedScanText = text
    scanData = parsed
    pomoResolveTask()
    calRebuild()
  }

  Process {
    id: scanProcess
    running: false
    command: ["python3", root.scriptPath, root.vaultDir, root.checklistPatterns]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyScan(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("cockpit", text.trim())
    }
  }

  function rescan() {
    if (!scanProcess.running) scanProcess.running = true
  }

  Timer {
    interval: {
      var secs = Number(root.setting("refreshIntervalSec", 60))
      if (!isFinite(secs)) secs = 60
      return Math.max(15, secs) * 1000
    }
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.rescan()
  }

  // -------------------------------------------------------------- pomodoro
  //
  // Durations mirror the vault's own cockpit-board pomodoro settings (read
  // by the scanner); the widget settings only serve as a fallback. The timer
  // attaches to a task: completed work sessions are counted here at runtime
  // (never written into the vault) and shown against the board's long-break
  // interval, cockpit-board style ("Session 2/4").

  readonly property var pomoCfg: scanData && scanData.pomodoro ? scanData.pomodoro : null
  readonly property double workMs: Math.max(1, pomoCfg ? Number(pomoCfg.work) : Number(setting("workMinutes", 25))) * 60000
  readonly property double shortBreakMs: Math.max(1, pomoCfg ? Number(pomoCfg.shortBreak) : Number(setting("breakMinutes", 5))) * 60000
  readonly property double longBreakMs: Math.max(1, pomoCfg ? Number(pomoCfg.longBreak) : 15) * 60000
  readonly property int longBreakInterval: Math.max(1, pomoCfg ? Number(pomoCfg.longBreakInterval) : 4)

  property string pomoPhase: "work"          // "work" | "short-break" | "long-break"
  property bool pomoRunning: false
  property double pomoEndMs: 0               // wall-clock deadline while running
  property double pomoPausedLeftMs: workMs   // remaining time while paused
  property int pomoSessions: 0               // work sessions finished since attach
  property string pomoTaskFile: ""           // attached task (vault file name)
  property string pomoTaskTitle: ""
  property var pomoTask: null                // attached task's live vault record

  readonly property double pomoPhaseMs: pomoPhase === "work" ? workMs
    : (pomoPhase === "long-break" ? longBreakMs : shortBreakMs)
  readonly property double pomoLeftMs: pomoRunning ? Math.max(0, pomoEndMs - nowMs) : pomoPausedLeftMs
  readonly property bool pomoIdle: !pomoRunning && pomoPausedLeftMs >= pomoPhaseMs

  // Live pomodoro state — running, paused mid-phase, in (or armed for) a
  // break, or still attached to a task. Fresh / reset state is not live, and
  // the whole pomodoro section stays hidden until the timer button is
  // pressed on a task.
  readonly property bool pomoLive: pomoRunning || !pomoIdle
    || pomoPhase !== "work" || pomoTaskFile !== ""

  // Re-resolve the attached task against the freshly applied scan (for its
  // vault-logged pomodoro count). Called from applyScan and on attach/detach —
  // deliberately a function, not a binding over the whole agenda.
  function pomoResolveTask() {
    pomoTask = null
    if (pomoTaskFile === "" || !scanData || !scanData.agenda) return
    var agenda = scanData.agenda
    for (var day in agenda) {
      var list = agenda[day]
      for (var i = 0; i < list.length; i++) {
        if (list[i].file === pomoTaskFile) {
          pomoTask = list[i]
          return
        }
      }
    }
  }

  Timer {
    interval: 1000
    running: root.pomoRunning
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
      if (root.pomoEndMs - root.nowMs <= 0) root.pomoFinish(true)
    }
  }

  function pomoStart() {
    nowMs = Date.now()
    pomoEndMs = nowMs + pomoPausedLeftMs
    pomoRunning = true
    pomoSave()
  }

  function pomoPause() {
    nowMs = Date.now()
    pomoPausedLeftMs = Math.max(0, pomoEndMs - nowMs)
    pomoRunning = false
    pomoSave()
  }

  function pomoReset() {
    pomoRunning = false
    pomoPhase = "work"
    pomoSessions = 0
    pomoTaskFile = ""
    pomoTaskTitle = ""
    pomoTask = null
    pomoPausedLeftMs = workMs
    pomoSave()
  }

  function pomoSkip() { pomoFinish(false) }

  // Start (or toggle) the pomodoro for a specific task. Switching to a
  // different task starts a fresh session run for it.
  function pomoStartFor(task) {
    if (!task || !task.file) return
    if (task.file === pomoTaskFile) {
      pomoRunning ? pomoPause() : pomoStart()
      return
    }
    pomoTaskFile = String(task.file)
    pomoTaskTitle = String(task.title || task.file)
    pomoTask = task
    pomoPhase = "work"
    pomoSessions = 0
    pomoPausedLeftMs = workMs
    pomoStart()
  }

  // A finished work session rolls straight into a running break (long one
  // every longBreakInterval-th session); a finished break arms the next work
  // session but waits for a deliberate start.
  function pomoFinish(notifyUser) {
    var finishedWork = pomoPhase === "work"
    if (finishedWork) {
      pomoSessions += 1
      var longBreak = pomoSessions % longBreakInterval === 0
      if (notifyUser === true)
        notify((longBreak ? "Session done — long break" : "Time for a break")
               + (pomoTaskTitle !== "" ? " · " + pomoTaskTitle : ""))
      pomoPhase = longBreak ? "long-break" : "short-break"
      pomoPausedLeftMs = pomoPhaseMs
      if (notifyUser === true) {
        nowMs = Date.now()
        pomoEndMs = nowMs + pomoPhaseMs
        pomoRunning = true
      } else {
        pomoRunning = false
      }
    } else {
      if (notifyUser === true)
        notify("Break over — back to work"
               + (pomoTaskTitle !== "" ? " on " + pomoTaskTitle : ""))
      pomoPhase = "work"
      pomoPausedLeftMs = workMs
      pomoRunning = false
    }
    pomoSave()
  }

  Process { id: notifyProcess; running: false }

  function notify(message) {
    if (notifyProcess.running) return
    notifyProcess.command = ["omarchy-notification-send", "-u", "normal", "Pomodoro", message]
    notifyProcess.running = true
  }

  function pomoFormat(ms) {
    var total = Math.ceil(ms / 1000)
    var m = Math.floor(total / 60)
    var s = total % 60
    return m + ":" + String(s).padStart(2, "0")
  }

  function pomoBarText() {
    var total = Math.ceil(pomoLeftMs / 1000)
    if (total >= 60) return Math.ceil(total / 60) + "m"
    return total + "s"
  }

  readonly property string pomoSessionLabel: {
    if (pomoPhase === "work")
      return "Session " + Math.min(pomoSessions + 1, longBreakInterval) + "/" + longBreakInterval
    return pomoSessions + " done"
  }

  // State survives a shell reload: the deadline, phase, session count and
  // attached task live in a small JSON file under XDG_RUNTIME_DIR (gone on
  // reboot, which is fine). The vault itself is never written.
  FileView {
    id: pomoFile
    path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-cockpit-pomodoro.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.pomoRestore(text())
  }

  function pomoSave() {
    pomoFile.setText(JSON.stringify({
      phase: pomoPhase, running: pomoRunning,
      endMs: pomoEndMs, pausedLeftMs: pomoPausedLeftMs,
      sessions: pomoSessions, taskFile: pomoTaskFile, taskTitle: pomoTaskTitle
    }))
  }

  function pomoRestore(raw) {
    var state
    try { state = JSON.parse(String(raw || "")) } catch (e) { return }
    if (!state) return
    if (state.phase !== "work" && state.phase !== "short-break" && state.phase !== "long-break") return
    pomoPhase = state.phase
    pomoSessions = Math.max(0, Number(state.sessions) || 0)
    pomoTaskFile = String(state.taskFile || "")
    pomoTaskTitle = String(state.taskTitle || "")
    pomoResolveTask()
    var now = Date.now()
    if (state.running === true && Number(state.endMs) > now) {
      pomoEndMs = Number(state.endMs)
      pomoRunning = true
    } else if (state.running === true) {
      // Deadline elapsed while the shell was down: land on the next phase,
      // armed but paused, without a stale notification.
      if (state.phase === "work") {
        pomoSessions += 1
        pomoPhase = pomoSessions % longBreakInterval === 0 ? "long-break" : "short-break"
      } else {
        pomoPhase = "work"
      }
      pomoPausedLeftMs = pomoPhaseMs
      pomoRunning = false
    } else {
      pomoPausedLeftMs = clamp(Number(state.pausedLeftMs) || pomoPhaseMs, 0, pomoPhaseMs)
      pomoRunning = false
    }
  }

  // -------------------------------------------------------------- calendar
  //
  // The schedule's week row, the month grid and the selected day's task list
  // are STORED models, rebuilt only by calRebuild() — on applied scans,
  // week / month navigation, day selection, expand/collapse and panel open.
  // Bindings never rebuild them. The compact week row is the default view;
  // the full month grid sits behind the chevron toggle and collapses again
  // on every panel open.

  property int calYear: 0
  property int calMonth: 0                   // 0-based
  property bool calExpanded: false           // false = compact week row
  property string selectedDate: ""
  property string todayStr: ""
  property string calTitle: ""
  property string heroDate: ""
  property var calCells: []
  property var weekCells: []
  property var dayTasks: []

  function todayString() {
    var now = new Date()
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  // One day cell for the week row / month grid, scanning the day's agenda
  // for any timed item (never assumes the list is timed-first).
  function calCellFor(agenda, ds, d) {
    var list = agenda[ds] || []
    var timed = false
    for (var i = 0; i < list.length; i++)
      if (list[i].time) { timed = true; break }
    return {
      day: d, date: ds,
      today: ds === todayStr,
      selected: ds === selectedDate,
      count: list.length, timed: timed
    }
  }

  function calRebuild() {
    todayStr = todayString()
    heroDate = Qt.formatDate(new Date(), "ddd d MMMM")
    if (calYear === 0) {                     // first build: land on today
      var init = new Date()
      calYear = init.getFullYear()
      calMonth = init.getMonth()
    }
    if (selectedDate === "") selectedDate = todayStr

    // While collapsed, the month (and title) track the selected day, so the
    // week row's header stays honest and expanding lands on its month.
    var sel = String(selectedDate).split("-")
    if (!calExpanded && sel.length === 3) {
      calYear = Number(sel[0])
      calMonth = Number(sel[1]) - 1
    }

    var agenda = scanData && scanData.agenda ? scanData.agenda : {}
    var cells = []
    var lead = (new Date(calYear, calMonth, 1).getDay() + 6) % 7  // Monday-first
    for (var l = 0; l < lead; l++)
      cells.push({ day: 0, date: "", today: false, selected: false, count: 0, timed: false })
    var daysInMonth = new Date(calYear, calMonth + 1, 0).getDate()
    for (var d = 1; d <= daysInMonth; d++) {
      var ds = calYear + "-" + String(calMonth + 1).padStart(2, "0") + "-" + String(d).padStart(2, "0")
      cells.push(calCellFor(agenda, ds, d))
    }
    while (cells.length % 7 !== 0)
      cells.push({ day: 0, date: "", today: false, selected: false, count: 0, timed: false })
    calCells = cells

    // The selected day's week (Monday-first), for the compact row.
    var wk = []
    if (sel.length === 3) {
      var selDay = new Date(Number(sel[0]), Number(sel[1]) - 1, Number(sel[2]))
      var back = (selDay.getDay() + 6) % 7   // Monday-first
      for (var w = 0; w < 7; w++) {
        var wd = new Date(selDay.getFullYear(), selDay.getMonth(), selDay.getDate() - back + w)
        var wds = wd.getFullYear()
          + "-" + String(wd.getMonth() + 1).padStart(2, "0")
          + "-" + String(wd.getDate()).padStart(2, "0")
        wk.push(calCellFor(agenda, wds, wd.getDate()))
      }
    }
    weekCells = wk

    calTitle = Qt.formatDate(new Date(calYear, calMonth, 1), "MMMM yyyy")
    dayTasks = agenda[selectedDate] || []
  }

  function shiftDateStr(ds, days) {
    var p = String(ds).split("-")
    if (p.length !== 3) return ds
    var d = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]) + days)
    return d.getFullYear()
      + "-" + String(d.getMonth() + 1).padStart(2, "0")
      + "-" + String(d.getDate()).padStart(2, "0")
  }

  // ‹ › navigation: weeks (selected day ±7) while collapsed, months while
  // the full grid is expanded.
  function calShift(delta) {
    if (!calExpanded) {
      selectedDate = shiftDateStr(selectedDate, delta * 7)
      calRebuild()
      return
    }
    var m = calMonth + delta
    calYear = calYear + Math.floor(m / 12)
    calMonth = ((m % 12) + 12) % 12
    calRebuild()
  }

  function calToggleExpanded() {
    calExpanded = !calExpanded
    calRebuild()
  }

  function calSelect(ds) {
    if (!ds) return
    selectedDate = String(ds)
    calRebuild()
  }

  function calGoToday() {
    var now = new Date()
    calYear = now.getFullYear()
    calMonth = now.getMonth()
    selectedDate = todayString()
    calRebuild()
  }

  function fmtDay(ds) {
    var p = String(ds).split("-")
    if (p.length !== 3) return ds
    return Qt.formatDate(new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2])), "ddd d MMMM")
  }

  function fmtShort(ds, fmt) {
    var p = String(ds).split("-")
    if (p.length !== 3) return ds
    return Qt.formatDate(new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2])), fmt)
  }

  // ------------------------------------------------------------------ misc

  function openObsidian() {
    var cmd = "omarchy-launch-or-focus '(obsidian|md\\.obsidian\\.Obsidian)' 'uwsm-app -- obsidian'"
    if (bar) bar.run(cmd)
    else Quickshell.execDetached(["sh", "-c", cmd])
    close()
  }

  function taskMeta(task, withDate) {
    var bits = []
    if (withDate && task.due) bits.push(task.due)
    if (task.project) bits.push(task.project)
    if (Number(task.pomodoros) > 0) bits.push("🍅 " + task.pomodoros)
    if (Number(task.timeSpent) > 0) bits.push(task.timeSpent + "m logged")
    return bits.join(" · ")
  }

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    touchActivity()
    contentLoader.active = true      // first open builds the content, once
    calExpanded = false              // every open starts on the week row
    calGoToday()
    rescan()
    if (contentLoader.item) contentLoader.item.resetScroll()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.rescan(); return "ok" }
    function pomodoro(): string {
      if (root.pomoRunning) root.pomoPause(); else root.pomoStart()
      return root.pomoRunning ? "running" : "paused"
    }
  }

  // ------------------------------------------------------------------- bar

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.pomoRunning ? root.pomoBarText() : "\uf0ae"
    fontSize: root.pomoRunning ? Style.font.caption : Style.bar.iconFont
    slotSize: Style.bar.statusSlot
    active: root.overdueCount > 0
    tooltipText: root.pomoRunning && root.pomoTaskTitle !== ""
      ? "🍅 " + root.plainText(root.pomoTaskTitle) + " — " + root.pomoFormat(root.pomoLeftMs)
      : (root.overdueCount > 0
        ? root.overdueCount + " overdue · " + root.todayTasks.length + " due today"
        : (root.todayTasks.length > 0 ? root.todayTasks.length + " due today" : "Cockpit"))
    onPressed: root.toggle()
  }

  // Overdue count badge riding the icon's corner.
  Rectangle {
    visible: root.overdueCount > 0
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: Style.space(2)
    width: Math.max(height, badgeText.implicitWidth + Style.space(4))
    height: badgeText.implicitHeight + Style.space(2)
    radius: height / 2
    color: root.urgent

    Text {
      id: badgeText
      anchors.centerIn: parent
      text: root.overdueCount > 9 ? "9+" : String(root.overdueCount)
      color: Color.background
      font.family: root.fontFamily
      font.pixelSize: Math.round(Style.font.caption * 0.8)
      font.bold: true
    }
  }

  // ----------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: contentLoader.item ? contentLoader.item.keyCatcherItem : null
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(
      contentLoader.item ? contentLoader.item.contentImplicitHeight : Style.space(120),
      Style.space(660))

    // The whole panel body lives behind this Loader: nothing below is
    // instantiated at shell startup, only on the first open.
    Loader {
      id: contentLoader
      anchors.fill: parent
      active: false
      sourceComponent: contentComponent
    }
  }

  Component {
    id: contentComponent

    PanelKeyCatcher {
      id: keyCatcher

      readonly property Item keyCatcherItem: keyCatcher
      readonly property real contentImplicitHeight: column.implicitHeight
      function resetScroll() { panelFlick.contentY = 0 }

      // Any pointer movement over the panel counts as activity for the
      // inactivity auto-close.
      HoverHandler {
        onPointChanged: root.touchActivity()
      }

      onMoveRequested: function(dx, dy) {
        root.touchActivity()
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
        if (dx !== 0) root.calShift(dx > 0 ? 1 : -1)
      }
      onActivateRequested: { root.touchActivity(); root.rescan() }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        root.touchActivity()
        if (t === "r" || t === "R") root.rescan()
        else if (t === " " || t === "p" || t === "P") root.pomoRunning ? root.pomoPause() : root.pomoStart()
        else if (t === "o" || t === "O") root.openObsidian()
        else if (t === "[") root.calShift(-1)
        else if (t === "]") root.calShift(1)
        else if (t === "t" || t === "T") root.calGoToday()
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

          // ---------- Hero ----------
          PanelHero {
            width: parent.width
            title: "Cockpit"
            meta: root.heroDate
              + " · " + root.todayTasks.length + " today"
              + (root.overdueCount > 0 ? " · " + root.overdueCount + " overdue" : "")
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                text: "\uf0ae"
                color: root.overdueCount > 0 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              Button {
                text: "Obsidian"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.openObsidian()
              }
            }
          }

          // ---------- Pomodoro (only while live) ----------
          PanelSeparator {
            visible: pomoSection.visible
            foreground: root.foreground
          }

          Column {
            id: pomoSection
            visible: root.pomoLive
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: "POMODORO — " + (root.pomoPhase === "work" ? "FOCUS"
                : (root.pomoPhase === "long-break" ? "LONG BREAK" : "BREAK"))
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // The task this pomodoro belongs to.
            Text {
              width: parent.width
              visible: root.pomoTaskTitle !== ""
              text: "🍅 " + root.plainText(root.pomoTaskTitle)
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              visible: root.pomoTaskTitle === ""
              text: "No task attached — press 🍅 on a task below"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              width: parent.width
              text: root.pomoFormat(root.pomoLeftMs)
              color: root.pomoRunning ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              width: parent.width
              text: root.pomoSessionLabel
                + (root.pomoTask && Number(root.pomoTask.pomodoros) > 0
                  ? " · 🍅 " + root.pomoTask.pomodoros + " in vault" : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }

            // Drains toward zero, like the timer itself.
            Item {
              width: parent.width
              implicitHeight: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

              Rectangle {
                id: pomoTrack
                anchors.fill: parent
                radius: height / 2
                color: root.track
              }

              Rectangle {
                anchors.left: pomoTrack.left
                anchors.verticalCenter: pomoTrack.verticalCenter
                height: pomoTrack.height
                radius: pomoTrack.radius
                width: pomoTrack.width * root.clamp(root.pomoLeftMs / root.pomoPhaseMs, 0, 1)
                color: root.pomoPhase === "work" ? root.foreground : root.alpha(root.foreground, 0.6)
              }
            }

            Row {
              id: pomoButtons
              width: parent.width
              spacing: Style.spacing.md
              readonly property real cellWidth: (width - spacing * 2) / 3

              Button {
                width: pomoButtons.cellWidth
                text: root.pomoRunning ? "Pause" : (root.pomoIdle ? "Start" : "Resume")
                bordered: true
                selected: root.pomoRunning
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.pomoRunning ? root.pomoPause() : root.pomoStart()
              }

              Button {
                width: pomoButtons.cellWidth
                text: "Reset"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.pomoReset()
              }

              Button {
                width: pomoButtons.cellWidth
                text: root.pomoPhase === "work" ? "Skip to break" : "Skip break"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.pomoSkip()
              }
            }
          }

          // ---------- Schedule (week row, expandable to month grid) ----------
          PanelSeparator { foreground: root.foreground }

          Column {
            id: calendarSection
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellSize: Math.floor(width / 7)

            // Header with ‹ › navigation (weeks while collapsed, months while
            // expanded), a title that jumps back to today, and a chevron
            // toggling the compact week row into the full month grid.
            Item {
              width: parent.width
              implicitHeight: Math.round(Style.font.body * 1.9)

              Button {
                id: calPrev
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Math.round(Style.spacing.controlHeight * 0.9)
                text: "‹"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.calShift(-1)
              }

              Text {
                anchors.centerIn: parent
                text: root.calTitle.toUpperCase()
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.calGoToday()
                }
              }

              Button {
                id: calToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: calPrev.width
                text: root.calExpanded ? "\uf077" : "\uf078"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.calToggleExpanded()
              }

              Button {
                id: calNext
                anchors.right: calToggle.left
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                width: calPrev.width
                text: "›"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.calShift(1)
              }
            }

            Grid {
              columns: 7

              Repeater {
                model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
                Item {
                  id: dowCell
                  required property var modelData
                  width: calendarSection.cellSize
                  height: Math.round(Style.font.caption * 1.6)

                  Text {
                    anchors.centerIn: parent
                    text: dowCell.modelData
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            // Compact default: the selected day's week as a single row.
            Grid {
              visible: !root.calExpanded
              columns: 7

              Repeater {
                model: root.weekCells
                CalDayCell {
                  required property var modelData
                  cell: modelData
                  cellSize: calendarSection.cellSize
                }
              }
            }

            // Expanded: the full month grid.
            Grid {
              visible: root.calExpanded
              columns: 7

              Repeater {
                model: root.calCells
                CalDayCell {
                  required property var modelData
                  cell: modelData
                  cellSize: calendarSection.cellSize
                }
              }
            }
          }

          // ---------- Selected-day tasks ----------
          PanelSeparator { foreground: root.foreground }

          Column {
            id: daySection
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              width: parent.width
              text: (root.selectedDate === root.todayStr
                  ? "TODAY — " + root.fmtShort(root.selectedDate, "d MMM")
                  : root.fmtShort(root.selectedDate, "ddd d MMM")).toUpperCase()
                + (root.dayTasks.length > 0 ? " · " + root.dayTasks.length : "")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.dayTasks.length === 0
              width: parent.width
              text: "Nothing scheduled."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.dayTasks
              TaskRow {
                required property var modelData
                width: daySection.width
                task: modelData
                showTime: true
              }
            }
          }

          // ---------- Overdue ----------
          PanelSeparator {
            visible: overdueSection.visible
            foreground: root.foreground
          }

          Column {
            id: overdueSection
            visible: root.overdueTasks.length > 0
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              width: parent.width
              text: "OVERDUE (" + root.overdueCount + ")"
              foreground: root.urgent
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.overdueTasks
              TaskRow {
                required property var modelData
                width: overdueSection.width
                task: modelData
                urgentRow: true
                showDate: true
              }
            }
          }

          // ---------- Checklist meters (one per configured pattern) ----------
          PanelSeparator {
            visible: checklistSection.visible
            foreground: root.foreground
          }

          Column {
            id: checklistSection
            visible: root.followups.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              width: parent.width
              text: "CHECKLISTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.followups

              // Clicking anywhere on a meter expands it to the note body,
              // exactly like the task rows above.
              Item {
                id: meterItem
                required property var modelData
                width: checklistSection.width
                height: meterCol.height
                property bool expanded: false

                readonly property int cOpen: modelData ? Number(modelData.open || 0) : 0
                readonly property int cDone: modelData ? Number(modelData.done || 0) : 0

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    meterItem.expanded = !meterItem.expanded
                    root.touchActivity()
                  }
                }

                Column {
                  id: meterCol
                  width: parent.width
                  spacing: Style.space(4)

                  Text {
                    width: parent.width
                    text: meterItem.modelData ? root.plainText(meterItem.modelData.label || "") : ""
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Item {
                    width: parent.width
                    implicitHeight: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

                    Rectangle {
                      id: meterTrack
                      anchors.fill: parent
                      radius: height / 2
                      color: root.track
                    }

                    Rectangle {
                      anchors.left: meterTrack.left
                      anchors.verticalCenter: meterTrack.verticalCenter
                      height: meterTrack.height
                      radius: meterTrack.radius
                      width: meterTrack.width * (meterItem.cDone
                        / Math.max(1, meterItem.cOpen + meterItem.cDone))
                      color: root.foreground
                    }
                  }

                  Text {
                    width: parent.width
                    text: meterItem.cDone + " done · " + meterItem.cOpen + " open"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }

                  // The checklist's note body, revealed on click.
                  Text {
                    visible: meterItem.expanded
                    x: Style.space(6)
                    width: parent.width - Style.space(12)
                    text: meterItem.modelData && meterItem.modelData.body
                      ? root.plainText(meterItem.modelData.body) : "No notes."
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            topPadding: Style.space(2)
            text: "Read-only · " + root.plainText(root.vaultDir.replace(/^\/home\/[^\/]+/, "~"))
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // One task: optional time badge, title, meta caption, and a timer button that
  // starts (or pauses) the pomodoro attached to this task. Clicking the row
  // expands it to reveal the note body (already stripped to plain text by the
  // scanner). The vault stays untouched.
  component TaskRow: Item {
    id: taskRow
    property var task: null
    property bool urgentRow: false
    property bool showDate: false
    property bool showTime: false
    property bool expanded: false

    readonly property string body: task && task.body ? String(task.body) : ""
    readonly property string timeText: task && task.time ? String(task.time) : ""
    readonly property bool pomoAttached: task ? (root.pomoTaskFile !== "" && task.file === root.pomoTaskFile) : false

    implicitHeight: headerArea.implicitHeight
      + (expanded ? bodyText.implicitHeight + Style.space(6) : 0)
      + Style.space(6)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: taskRow.expanded
        ? Style.selectedFillFor(root.foreground, Color.accent)
        : (taskHover.containsMouse
          ? Style.hoverFillFor(root.foreground, Color.accent)
          : "transparent")
    }

    // Declared before headerArea so the timer button's MouseArea (inside
    // headerArea) naturally stacks above this row-wide click/hover area.
    MouseArea {
      id: taskHover
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: headerArea.implicitHeight + Style.space(6)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: taskRow.expanded = !taskRow.expanded
    }

    Item {
      id: headerArea
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      anchors.topMargin: Style.space(3)
      implicitHeight: taskTitle.implicitHeight + taskMetaText.implicitHeight

      Text {
        id: timeBadge
        anchors.left: parent.left
        anchors.top: parent.top
        width: taskRow.showTime ? Style.space(44) : 0
        visible: taskRow.showTime
        text: taskRow.timeText !== "" ? root.plainText(taskRow.timeText) : "—"
        textFormat: Text.PlainText
        color: taskRow.timeText !== "" ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: taskRow.timeText !== ""
      }

      Text {
        id: taskTitle
        anchors.left: timeBadge.right
        anchors.right: pomoButton.left
        anchors.top: parent.top
        anchors.rightMargin: Style.space(4)
        text: taskRow.task ? root.plainText(taskRow.task.title || "") : ""
        textFormat: Text.PlainText
        color: taskRow.urgentRow ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        id: taskMetaText
        anchors.left: timeBadge.right
        anchors.right: pomoButton.left
        anchors.top: taskTitle.bottom
        anchors.rightMargin: Style.space(4)
        text: {
          var meta = taskRow.task ? root.plainText(root.taskMeta(taskRow.task, taskRow.showDate)) : ""
          if (!taskRow.showTime && taskRow.timeText !== "")
            meta = meta === "" ? root.plainText(taskRow.timeText) : root.plainText(taskRow.timeText) + " · " + meta
          return meta
        }
        textFormat: Text.PlainText
        visible: text !== ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      // Start / pause the pomodoro for this task.
      Item {
        id: pomoButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: Math.round(Style.font.bodySmall * 1.15)
        height: Math.round(width * 0.93)
        opacity: taskRow.pomoAttached ? 1 : (taskHover.containsMouse ? 0.9 : 0.35)

        Text {
          anchors.centerIn: parent
          visible: taskRow.pomoAttached && root.pomoRunning
          text: "\uf04c"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        TomatoIcon {
          anchors.fill: parent
          visible: !(taskRow.pomoAttached && root.pomoRunning)
          color: root.foreground
        }

        MouseArea {
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          cursorShape: Qt.PointingHandCursor
          onClicked: root.pomoStartFor(taskRow.task)
        }
      }
    }

    // The note body, revealed on click.
    Text {
      id: bodyText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: headerArea.bottom
      anchors.leftMargin: taskRow.showTime ? Style.space(50) : Style.space(6)
      anchors.rightMargin: Style.space(6)
      anchors.topMargin: Style.space(4)
      visible: taskRow.expanded
      text: taskRow.body !== "" ? root.plainText(taskRow.body) : "No notes."
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
    }
  }

  // One calendar day cell, shared by the compact week row and the month
  // grid: selected day filled disc, today ring, hover fill, and a task
  // marker dot (accent when the day has any timed item).
  // Monochrome tomato, tintable to any theme color: the U+1F345 outline
  // extracted from Google's Noto Emoji (OFL) — Qt insists on routing the
  // emoji codepoint to the color font, so the vector ships with the plugin
  // instead. ViewBox 107.7 x 100.
  component TomatoIcon: Item {
    id: tomato
    property color color: root.foreground
    implicitWidth: Math.round(Style.font.bodySmall * 1.15)
    implicitHeight: Math.round(implicitWidth * 0.93)

    Shape {
      id: tomatoShape
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer
      transform: Scale { xScale: tomatoShape.width / 107.7; yScale: tomatoShape.height / 100 }

      ShapePath {
        strokeWidth: -1
        fillColor: tomato.color
        fillRule: ShapePath.WindingFill
        PathSvg { path: "M50.0 92.9Q39.6 92.9 30.6 89.7Q21.5 86.5 14.6 80.9Q7.8 75.3 3.9 68.0Q0.0 60.7 0.0 52.5Q0.0 45.5 2.7 39.2Q5.5 32.9 10.2 28.0Q15.0 23.1 21.0 20.2Q27.0 17.4 33.5 17.4Q36.1 17.4 38.8 17.8Q41.4 18.3 43.9 19.6L43.0 23.0Q41.0 21.9 38.8 21.4Q36.6 20.9 33.5 20.9Q27.7 20.9 22.3 23.5Q16.9 26.1 12.7 30.5Q8.5 35.0 6.0 40.7Q3.6 46.3 3.6 52.5Q3.6 60.0 7.2 66.7Q10.8 73.3 17.3 78.5Q23.7 83.6 32.1 86.5Q40.4 89.4 50.0 89.4Q59.6 89.4 67.9 86.5Q76.3 83.6 82.7 78.5Q89.2 73.3 92.8 66.7Q96.4 60.0 96.4 52.5Q96.4 46.3 94.0 40.7Q91.5 35.0 87.3 30.5Q83.1 26.1 77.7 23.5Q72.4 20.9 66.5 20.9Q63.4 20.9 61.2 21.4Q59.0 21.9 57.0 23.0L56.1 19.6Q58.6 18.3 61.3 17.8Q63.9 17.4 66.5 17.4Q73.0 17.4 79.0 20.2Q85.0 23.1 89.8 28.0Q94.5 32.9 97.3 39.2Q100.0 45.5 100.0 52.5Q100.0 60.7 96.1 68.0Q92.2 75.3 85.4 80.9Q78.5 86.5 69.4 89.7Q60.4 92.9 50.0 92.9ZM21.8 66.8Q21.0 66.8 20.3 66.1Q19.6 65.4 18.8 64.1Q17.3 61.7 16.1 58.1Q15.0 54.5 15.0 51.0Q15.0 48.6 15.4 46.6Q15.8 44.6 16.3 43.3Q17.3 40.9 18.4 40.9Q19.1 40.9 19.5 41.4Q20.0 41.8 20.0 42.5Q20.0 43.4 19.3 45.6Q18.6 47.9 18.6 51.0Q18.6 54.3 19.7 57.6Q20.8 60.8 23.0 63.9Q23.3 64.5 23.3 65.2Q23.3 65.9 22.9 66.4Q22.5 66.8 21.8 66.8ZM61.1 43.1Q60.7 43.1 60.2 43.0Q59.7 43.0 59.2 42.9Q55.6 42.2 53.4 41.0Q51.2 39.7 49.8 38.2Q48.4 36.7 47.3 35.4Q46.3 34.0 45.1 33.1Q43.9 32.3 42.0 32.3Q40.8 32.3 39.2 32.5Q37.6 32.7 35.6 32.7Q33.6 32.7 31.0 32.2Q28.3 31.7 26.3 30.6Q24.4 29.5 24.4 27.8Q24.4 27.1 25.7 27.1Q28.3 27.1 30.0 26.9Q31.6 26.6 32.7 26.1Q33.8 25.6 34.9 24.9Q36.0 24.2 37.8 23.4Q35.6 22.7 33.6 20.7Q31.7 18.6 30.4 15.8Q29.2 12.9 29.2 9.8Q29.2 9.2 29.8 9.2Q30.2 9.2 30.9 9.7Q31.6 10.1 32.4 10.8L34.2 12.5Q35.3 13.4 37.0 13.5Q38.8 13.6 40.8 15.1Q42.9 16.7 44.4 18.3Q45.9 20.0 48.3 20.0Q50.0 20.0 51.3 18.6Q52.7 17.2 54.2 15.4Q55.7 13.6 57.8 12.2Q59.9 10.8 63.1 10.8Q64.2 10.8 65.4 11.0Q66.7 11.2 66.7 11.7Q66.7 11.9 66.1 12.3Q65.5 12.6 63.9 14.4L60.8 17.9Q58.8 20.0 57.9 22.2Q60.4 22.2 62.4 23.4Q64.3 24.6 66.1 25.7Q67.9 26.9 70.2 26.9Q70.6 26.9 71.1 26.8Q71.6 26.7 72.0 26.7Q73.1 26.7 73.1 27.3Q73.1 28.3 71.9 29.2Q70.8 30.1 69.2 30.6Q67.5 31.1 66.2 31.1Q64.2 31.1 62.2 30.6Q60.3 30.0 58.9 30.0Q57.7 30.0 57.3 30.8Q57.9 32.0 58.4 33.9Q59.0 35.7 59.1 37.1Q59.2 38.0 59.9 39.2Q60.6 40.3 61.5 40.9Q62.5 41.7 62.5 42.4Q62.5 43.1 61.1 43.1ZM45.2 21.2Q45.2 16.2 45.8 11.7Q46.5 7.2 48.3 2.6L48.7 1.6Q49.2 0.0 51.0 0.0Q52.5 0.0 53.1 1.1Q53.7 2.2 53.3 3.4L52.8 4.6Q51.2 8.8 50.6 12.8Q50.0 16.7 50.0 21.2Z" }
      }
    }
  }

  component CalDayCell: Item {
    id: dayCell
    property var cell: null
    property real cellSize: 0

    readonly property bool blank: !cell || !(cell.day > 0)

    width: cellSize
    height: cellSize

    // Selected day: filled disc. Today (when not selected): ring.
    Rectangle {
      anchors.centerIn: parent
      width: Math.round(dayCell.cellSize * 0.86)
      height: width
      radius: width / 2
      visible: !dayCell.blank && dayCell.cell.selected
      color: root.foreground
    }

    Rectangle {
      anchors.centerIn: parent
      width: Math.round(dayCell.cellSize * 0.86)
      height: width
      radius: width / 2
      visible: !dayCell.blank && dayCell.cell.today && !dayCell.cell.selected
      color: "transparent"
      border.width: 1
      border.color: root.foreground
    }

    Rectangle {
      anchors.centerIn: parent
      width: Math.round(dayCell.cellSize * 0.86)
      height: width
      radius: width / 2
      visible: dayHover.containsMouse && !dayCell.blank && !dayCell.cell.selected
      color: Style.hoverFillFor(root.foreground, Color.accent)
    }

    Text {
      anchors.centerIn: parent
      visible: !dayCell.blank
      text: dayCell.blank ? "" : String(dayCell.cell.day)
      color: !dayCell.blank && dayCell.cell.selected ? Color.popups.background : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: !dayCell.blank && (dayCell.cell.today || dayCell.cell.selected)
    }

    // Task marker: accent dot for days with timed items,
    // dimmed dot for date-only tasks.
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Math.max(1, Math.round(dayCell.cellSize * 0.06))
      width: Math.max(3, Math.round(dayCell.cellSize * 0.14))
      height: width
      radius: width / 2
      visible: !dayCell.blank && dayCell.cell.count > 0 && !dayCell.cell.selected
      color: !dayCell.blank && dayCell.cell.timed ? Color.accent : root.dim
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      enabled: !dayCell.blank
      hoverEnabled: true
      cursorShape: dayCell.blank ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: root.calSelect(dayCell.cell.date)
    }
  }
}
