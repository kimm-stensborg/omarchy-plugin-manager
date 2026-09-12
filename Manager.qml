import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Plugin Manager. Lists the git plugins in ~/.config/omarchy/plugins -- never
// the built-in omarchy.* ones -- with their details, how each one opens,
// whether an update is waiting, and the actions to open, review and update,
// enable, disable, bind a shortcut to, remove or add one. It lists itself too,
// so it can update itself, but it will not switch itself off or remove itself.
// Every action runs bin/plugin-manager; this file only renders what comes back.
Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.kimm-stensborg.plugin-manager"
  readonly property string pluginDir: root.manifest && root.manifest.__sourceDir
    ? String(root.manifest.__sourceDir)
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.pluginId
  readonly property string backend: root.pluginDir + "/bin/plugin-manager"
  readonly property string stateDir: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache")
    + "/omarchy/plugin-manager"
  // How old the update check may be before opening the manager redoes it.
  readonly property int staleSeconds: 6 * 3600

  property bool opened: false
  property var plugins: []
  property string checkedAt: ""
  property int selectedIndex: 0
  // Select this id once the next list arrives -- a plugin that was just added.
  property string selectId: ""
  property bool listing: false
  property bool listedOnce: false
  property bool relistPending: false

  // Update checks, reviews, exports, import previews and shortcut changes run
  // in-process: none of them rescans the shell.
  property string busyLabel: ""
  property string busyId: ""
  property string busyKind: ""
  property bool busyQuiet: false

  // An import waiting on its confirmation: the dry run's reply.
  property bool confirmingImport: false
  property var importPreview: null

  // An update waiting on its review: the reply of `plugin-manager review`.
  property bool reviewing: false
  property var review: null
  readonly property var reviewFiles: root.review && root.review.files ? root.review.files : []
  readonly property var reviewLines: root.review && root.review.diff
    ? String(root.review.diff).replace(/\n$/, "").split("\n") : []

  // The shortcut dialog, and what the backend made of the keys typed into it.
  property bool binding: false
  property var keyCheck: null
  property string keyMode: ""

  // Everything else runs detached (see `plugin-manager run`), because the
  // stock commands end in a shell rescan that unloads this overlay mid-action.
  // The job reports through running.json and last-action.json, and summons the
  // overlay back when it is done.
  property string jobLabel: ""
  property string jobId: ""
  property bool launching: false
  property real launchedAt: 0
  property string lastSeq: ""

  readonly property bool busy: root.busyLabel !== "" || root.jobLabel !== "" || root.launching
  readonly property string activityLabel: root.busyLabel || root.jobLabel

  property string statusMessage: ""
  property bool statusError: false
  property bool confirmingRemove: false

  // Relative times ("checked 4 min ago") re-read this while open.
  property real now: Date.now()

  readonly property var current: root.selectedIndex >= 0 && root.selectedIndex < root.plugins.length
    ? root.plugins[root.selectedIndex] : null
  readonly property bool currentIsSelf: root.current !== null && root.current.self === true
  readonly property int updateCount: {
    var n = 0
    for (var i = 0; i < root.plugins.length; i++) if (root.behind(root.plugins[i]) > 0) n++
    return n
  }

  // Theme: the same [menu] surface tokens the Omarchy menu uses.
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color muted: Util.alpha(Color.menu.text, 0.6)
  readonly property color faint: Util.alpha(Color.menu.text, 0.15)
  readonly property color borderColor: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int contentSpacing: Style.spacing.md
  readonly property int headerHeight: Math.max(Style.space(30), Style.font.heading + Style.spacing.controlPaddingY * 2)
  readonly property int footerHeight: Math.max(Style.space(20), Style.font.caption + Style.space(6))
  readonly property int rowHeight: Math.max(Style.space(44), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  readonly property int labelWidth: Style.space(92)
  readonly property int cardWidth: Math.min(Style.space(1040), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(640), panel.height - Style.gapsOut * 2)

  // ------------------------------------------------------------- lifecycle

  // Payload: {"select": "<id>"} preselects a plugin; {"resume": "<seq>"} is a
  // detached job coming back to show its result.
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (!payload || typeof payload !== "object") payload = ({})

    root.opened = true
    root.closeDialogs()
    root.now = Date.now()
    if (payload.select) root.selectId = String(payload.select)
    root.syncJobs(true, payload.resume ? String(payload.resume) : "")
    root.refresh()
    // A stale check is redone on open; a fresh one comes straight back.
    if (!root.busy) root.runAction(["check", "--if-stale", String(root.staleSeconds)],
                                   "Checking for updates", "", "check", true)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // A job still running when the manager closes is left to finish: an update
  // cut off halfway helps nobody.
  function close() {
    root.opened = false
    root.closeDialogs()
  }

  function closeDialogs() {
    root.confirmingRemove = false
    root.confirmingImport = false
    root.importPreview = null
    root.reviewing = false
    root.review = null
    root.binding = false
    root.keyCheck = null
  }

  // User-initiated closes go through the host so its open-panel state stays in
  // step, and land back in close().
  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    else root.close()
  }

  function ping() { return "ok" }

  // For driving the overlay over IPC (`omarchy-shell shell call <id> …`): a
  // script selects by id and reads the selection back before acting on it.
  function currentId() { return root.current ? root.current.id : "" }

  function selectById(id) {
    for (var i = 0; i < root.plugins.length; i++) {
      if (root.plugins[i].id === String(id)) {
        root.select(i)
        return "ok"
      }
    }
    return "missing"
  }

  // ------------------------------------------------------------------ list

  function refresh() {
    if (listProc.running) {
      root.relistPending = true
      return
    }
    root.listing = true
    listProc.running = true
  }

  function applyList(text) {
    root.listing = false
    root.listedOnce = true
    var payload = root.parseJson(text)
    if (!payload || !payload.ok) {
      root.setStatus(payload && payload.message ? payload.message : "Could not read the plugin list", true)
      return
    }
    var keep = root.selectId || (root.current ? root.current.id : "")
    var list = payload.plugins || []
    var index = Math.min(root.selectedIndex, list.length - 1)
    for (var i = 0; i < list.length; i++) if (list[i].id === keep) index = i
    root.plugins = list
    root.checkedAt = payload.checkedAt || ""
    root.selectedIndex = Math.max(0, index)
    root.selectId = ""
    root.now = Date.now()
  }

  // --------------------------------------------------------------- actions

  readonly property var quickKinds: ["check", "export", "preview", "review", "bind", "unbind"]

  // One action at a time: they all end in the stock commands, which rescan
  // the shell and would trip over each other.
  function runAction(args, label, id, kind, quiet) {
    if (root.busy || quickProc.running) {
      if (!quiet) root.setStatus("Still " + root.activityLabel.toLowerCase() + " …", false)
      return
    }
    if (!quiet) root.setStatus("", false)

    // These end in no rescan, so nothing unloads the overlay under them.
    if (root.quickKinds.indexOf(kind) !== -1) {
      root.busyLabel = label
      root.busyId = id || ""
      root.busyKind = kind
      root.busyQuiet = quiet === true
      quickProc.command = [root.backend].concat(args)
      quickProc.running = true
      return
    }

    root.jobLabel = label
    root.jobId = id || ""
    root.launching = true
    root.launchedAt = Date.now()
    Quickshell.execDetached([root.backend, "run", "--label", label, "--id", id || "", "--kind", kind, "--"]
                            .concat(args))
  }

  function applyQuick(text) {
    var id = root.busyId
    var kind = root.busyKind
    var quiet = root.busyQuiet
    var label = root.busyLabel
    root.busyLabel = ""
    root.busyId = ""
    root.busyKind = ""
    var payload = root.parseJson(text)
    if (!payload || !payload.ok) {
      root.setStatus(payload && payload.message ? payload.message : label + " failed", true)
    } else if (kind === "check") {
      var summary = root.checkSummary(payload, id)
      if (!quiet || summary.error) root.setStatus(summary.text, summary.error)
    } else if (kind === "preview") {
      root.showImportPreview(payload)
      return
    } else if (kind === "review") {
      root.showReview(payload)
    } else {
      root.setStatus(payload.message, false)
    }
    root.refresh()
  }

  // Reads what the detached job left behind. The read at open() only notes
  // the latest result -- it is old news -- unless this summon is that job
  // coming back to show it.
  function syncJobs(atOpen, resumeSeq) {
    runningFile.reload()
    resultFile.reload()

    var running = root.parseJson(runningFile.text())
    var started = running ? Date.parse(running.startedAt) : NaN
    // A marker older than any update could take is a job that died.
    if (running && !isNaN(started) && Date.now() - started < 15 * 60 * 1000) {
      root.jobLabel = String(running.label || "Working")
      root.jobId = String(running.id || "")
      root.launching = false
    } else if (!root.launching) {
      root.jobLabel = ""
      root.jobId = ""
    } else if (Date.now() - root.launchedAt > 10000) {
      root.setStatus(root.jobLabel + " did not start", true)
      root.launching = false
      root.jobLabel = ""
      root.jobId = ""
    }

    var result = root.parseJson(resultFile.text())
    if (!result || !result.seq || String(result.seq) === root.lastSeq) return
    var seq = String(result.seq)
    root.lastSeq = seq
    if (atOpen && seq !== resumeSeq) return

    root.launching = false
    if (!running) {
      root.jobLabel = ""
      root.jobId = ""
    }
    // A resumed overlay is a fresh instance with the first row selected; put
    // the selection back on the plugin the job was about. After a remove the
    // list closes up over the gap, which is where the selection should land.
    if (result.kind !== "remove" && result.id) root.selectId = String(result.id)
    root.report(result.result, String(result.label || "The action"), String(result.kind || ""))
    root.refresh()
  }

  function report(payload, label, kind) {
    if (!payload) {
      root.setStatus(label + " failed", true)
    } else if (!payload.ok) {
      root.setStatus(payload.message || (label + " failed"), true)
    } else {
      root.setStatus(payload.message || (label + " done"), false)
      if (kind === "add" && payload.id) {
        root.selectId = payload.id
        urlField.text = ""
      }
    }
  }

  function checkSummary(payload, id) {
    var entries = payload.plugins || ({})
    if (id) {
      var entry = entries[id]
      var name = root.nameOf(id)
      if (!entry) return { text: "", error: false }
      if (entry.error) return { text: "Could not check " + name + ": " + entry.error, error: true }
      if (entry.behind > 0) return { text: name + ": " + root.commitsText(entry.behind) + " waiting", error: false }
      return { text: name + " is up to date", error: false }
    }
    var updates = 0
    var failed = []
    for (var key in entries) {
      if (entries[key].error) failed.push(root.nameOf(key))
      else if (entries[key].behind > 0) updates++
    }
    var text = updates === 0 ? "Everything is up to date"
      : updates === 1 ? "1 plugin has an update" : updates + " plugins have updates"
    if (failed.length > 0) text += " · could not check " + failed.join(", ")
    return { text: text, error: failed.length > 0 }
  }

  function checkCurrent() {
    var p = root.current
    if (p) root.runAction(["check", p.id], "Checking " + p.name, p.id, "check", false)
  }

  function checkAll() {
    root.runAction(["check"], "Checking for updates", "", "check", false)
  }

  // An update is reviewed first: the backend fetches and shows what it brings
  // in, and nothing changes until the review is confirmed.
  function updateCurrent() {
    var p = root.current
    if (!p) return
    if (p.update && !p.update.error && p.update.behind === 0) {
      root.setStatus(p.name + " is already up to date", false)
      return
    }
    root.runAction(["review", p.id], "Reading the changes to " + p.name, p.id, "review", false)
  }

  function showReview(payload) {
    if (!payload.entry || payload.entry.behind === 0) {
      root.setStatus(payload.message, false)
      return
    }
    root.review = payload
    root.reviewing = true
    Qt.callLater(function() { reviewList.contentY = 0 })
  }

  function cancelReview() {
    root.reviewing = false
    root.review = null
    keyCatcher.forceActiveFocus()
  }

  function confirmUpdate() {
    var r = root.review
    root.reviewing = false
    root.review = null
    keyCatcher.forceActiveFocus()
    if (!r) return
    var isSelf = r.id === root.pluginId
    root.runAction(["update", r.id], "Updating " + r.name, r.id, isSelf ? "self-update" : "update", false)
  }

  function scrollReview(dy) {
    var max = Math.max(0, reviewList.contentHeight - reviewList.height)
    reviewList.contentY = Math.max(0, Math.min(max, reviewList.contentY + dy))
  }

  function reviewKey(event) {
    var key = event.key
    var t = event.text
    var line = Style.font.caption + Style.spacing.xxs
    if (key === Qt.Key_Escape) root.cancelReview()
    else if (key === Qt.Key_Return || key === Qt.Key_Enter) root.confirmUpdate()
    else if (key === Qt.Key_Down || t === "j") root.scrollReview(line * 3)
    else if (key === Qt.Key_Up || t === "k") root.scrollReview(-line * 3)
    else if (key === Qt.Key_PageDown || key === Qt.Key_Space) root.scrollReview(reviewList.height * 0.9)
    else if (key === Qt.Key_PageUp) root.scrollReview(-reviewList.height * 0.9)
    else if (key === Qt.Key_Home) reviewList.contentY = 0
    else if (key === Qt.Key_End) root.scrollReview(reviewList.contentHeight)
  }

  function diffColor(line) {
    if (/^(\+\+\+|---|diff |index |new file|deleted file|similarity|rename )/.test(line)) return root.muted
    if (line.charAt(0) === "+") return root.accent
    if (line.charAt(0) === "-") return root.urgent
    if (line.indexOf("@@") === 0) return root.selectedText
    return root.foreground
  }

  function toggleEnabled() {
    var p = root.current
    if (!p) return
    if (p.self) {
      root.setStatus("The Plugin Manager does not switch itself off", false)
      return
    }
    if (!p.enabled && !p.valid) {
      root.setStatus(p.name + " cannot be enabled: " + p.validationError, true)
      return
    }
    root.runAction([p.enabled ? "disable" : "enable", p.id],
                   (p.enabled ? "Disabling " : "Enabling ") + p.name, p.id, "toggle", false)
  }

  function askRemove() {
    var p = root.current
    if (!p || root.busy) return
    if (p.self) {
      root.setStatus("The Plugin Manager does not remove itself; use omarchy plugin remove", false)
      return
    }
    confirm.selectedIndex = 0
    root.confirmingRemove = true
  }

  function removeCurrent() {
    root.confirmingRemove = false
    var p = root.current
    if (p) root.runAction(["remove", p.id], "Removing " + p.name, p.id, "remove", false)
    keyCatcher.forceActiveFocus()
  }

  // The field takes either: a .json file is an export to preview and import,
  // anything else is a git URL (or a local repo path) to add.
  function addPlugin() {
    var text = urlField.text.trim()
    if (!text) {
      urlField.forceActiveFocus()
      return
    }
    if (/\.json$/i.test(text)) root.previewImport(text)
    else root.runAction(["add", text], "Adding " + text, "", "add", false)
    keyCatcher.forceActiveFocus()
  }

  // Read an export file and show what importing it would do. Also callable
  // over IPC: `omarchy-shell shell call <id> previewImport <path>`.
  function previewImport(path) {
    var file = String(path || "").trim()
    if (!file) return
    root.runAction(["import", file, "--dry-run"], "Reading " + file, "", "preview", false)
  }

  function exportPlugins() {
    root.runAction(["export"], "Exporting plugins", "", "export", false)
  }

  // A dry run came back: show what the import would do and let it be confirmed.
  function showImportPreview(payload) {
    var plan = payload.plan || []
    var installs = 0
    for (var i = 0; i < plan.length; i++) if (plan[i].action === "install") installs++
    if (installs === 0) {
      root.setStatus(payload.message + ": everything in the file is already here or was skipped", false)
      return
    }
    root.importPreview = payload
    confirm.selectedIndex = 0
    root.confirmingImport = true
  }

  function importMessage() {
    var p = root.importPreview
    if (!p) return ""
    var lines = ["Import from " + (p.host || "another machine")
                 + (p.exportedAt ? ", exported " + String(p.exportedAt).slice(0, 10) : "") + "?", ""]
    var plan = p.plan || []
    for (var i = 0; i < plan.length; i++) {
      var item = plan[i]
      if (item.action === "install")
        lines.push("+ " + item.name + (item.enabled ? "  (enabled" + (item.where ? ", " + item.where : "") + ")" : ""))
    }
    var skipped = []
    for (var j = 0; j < plan.length; j++)
      if (plan[j].action !== "install") skipped.push("· " + plan[j].name + ": " + plan[j].reason)
    var atExport = p.skippedAtExport || []
    for (var k = 0; k < atExport.length; k++)
      skipped.push("· " + atExport[k].name + ": not in the file, " + atExport[k].reason)
    if (skipped.length > 0) lines = lines.concat([""], skipped)
    return lines.join("\n")
  }

  function importConfirmed() {
    root.confirmingImport = false
    var p = root.importPreview
    root.importPreview = null
    if (p && p.path) {
      root.runAction(["import", p.path], "Importing plugins", "", "import", false)
      urlField.text = ""
    }
    keyCatcher.forceActiveFocus()
  }

  function openRepo() {
    var url = root.webUrl(root.current)
    if (!url) return
    Qt.openUrlExternally(url)
    root.dismiss()
  }

  // Close the manager and open the selected plugin the way its own shortcut or
  // menu entry would; the backend picks that command, or a plain toggle.
  function openPlugin() {
    var p = root.current
    if (!p || p.self) return
    if (!p.openCommand) {
      root.setStatus(p.name + " has no window to open; it runs in the background", false)
      return
    }
    if (!p.enabled) {
      root.setStatus(p.name + " is disabled; enable it first  (e)", true)
      return
    }
    root.dismiss()
    Quickshell.execDetached(["sh", "-c", p.openCommand])
  }

  // -------------------------------------------------------------- shortcuts

  // The shortcut dialog proposes a free combination made from the plugin's
  // name, checks whatever is typed against Hyprland as it changes, and binds it
  // to what Open runs.
  function askBind() {
    var p = root.current
    if (!p) return
    if (!p.openCommand) {
      root.setStatus(p.name + " has no window to open, so there is nothing to bind", false)
      return
    }
    root.keyCheck = null
    bindField.text = ""
    root.binding = true
    Qt.callLater(function() { bindField.forceActiveFocus() })
    root.runKeys(["suggest-key", p.id], "suggest")
  }

  function closeBind() {
    root.binding = false
    root.keyCheck = null
    keyCatcher.forceActiveFocus()
  }

  function runKeys(args, mode) {
    keyProc.running = false
    root.keyMode = mode
    keyProc.command = [root.backend].concat(args)
    keyProc.running = true
  }

  function applyKeys(text) {
    var payload = root.parseJson(text)
    if (root.keyMode === "suggest") {
      // Setting the text sets off the check of what was suggested.
      if (payload && payload.ok && payload.keys && bindField.text === "") bindField.text = payload.keys
      return
    }
    root.keyCheck = payload
  }

  function saveBind() {
    var p = root.current
    var c = root.keyCheck
    if (!p || !c || !c.ok || keyCheckTimer.running || keyProc.running) return
    var args = ["bind", p.id, c.keys]
    if (c.taken) args.push("--replace")
    root.closeBind()
    root.runAction(args, "Binding " + c.keys + " to " + p.name, p.id, "bind", false)
  }

  function removeBind() {
    var p = root.current
    if (!p) return
    root.closeBind()
    root.runAction(["unbind", p.id], "Removing the shortcut for " + p.name, p.id, "unbind", false)
  }

  function managedShortcut(p) {
    var shortcuts = p && p.opens ? p.opens.shortcuts : []
    for (var i = 0; i < shortcuts.length; i++) if (shortcuts[i].managed) return shortcuts[i]
    return null
  }

  function bindStatus() {
    var c = root.keyCheck
    if (!bindField.text.trim()) return { text: "Type a combination, like SUPER + ALT + D", color: root.muted }
    if (keyCheckTimer.running || keyProc.running || !c) return { text: "Checking …", color: root.muted }
    if (!c.ok) return { text: c.message, color: root.urgent }
    if (c.taken) return { text: c.keys + " is taken by " + (c.takenBy || "another binding") + "; saving takes it over",
                          color: root.urgent }
    return { text: c.keys + " is free", color: root.accent }
  }

  // ------------------------------------------------------------- helpers

  function parseJson(text) {
    try { return JSON.parse(String(text || "")) } catch (e) { return null }
  }

  function setStatus(text, isError) {
    root.statusMessage = text
    root.statusError = isError === true
  }

  function move(delta) { root.select(root.selectedIndex + delta) }

  function select(index) {
    if (root.plugins.length === 0) return
    root.selectedIndex = Math.max(0, Math.min(root.plugins.length - 1, index))
    pluginList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    details.contentY = 0
  }

  function nameOf(id) {
    for (var i = 0; i < root.plugins.length; i++) if (root.plugins[i].id === id) return root.plugins[i].name
    return id
  }

  function behind(p) {
    return p && p.update && !p.update.error ? Number(p.update.behind || 0) : 0
  }

  function commitsText(n) { return n === 1 ? "1 new commit" : n + " new commits" }

  function ago(iso) {
    if (!iso) return ""
    var t = Date.parse(iso)
    if (isNaN(t)) return ""
    var s = Math.max(0, Math.round((root.now - t) / 1000))
    if (s < 60) return "just now"
    if (s < 3600) return Math.floor(s / 60) + " min ago"
    if (s < 86400) return Math.floor(s / 3600) + " h ago"
    return Math.floor(s / 86400) + " d ago"
  }

  function subtitle(p) {
    var parts = []
    if (p.version) parts.push("v" + p.version)
    if (p.git && p.git.branch) parts.push(p.git.branch)
    if (p.self) parts.push("this manager")
    return parts.join("  ·  ")
  }

  // A browsable page for the remote, when there is one: https remotes as they
  // are, and scp-style git@host:owner/repo remotes rewritten to https.
  function webUrl(p) {
    var remote = p && p.git ? String(p.git.remote || "") : ""
    var m = remote.match(/^git@([^:]+):(.+?)(\.git)?$/)
    if (m) return "https://" + m[1] + "/" + m[2]
    if (/^https?:\/\//.test(remote)) return remote.replace(/\.git$/, "")
    return ""
  }

  function updateLine(p) {
    if (!p) return { text: "", color: root.muted }
    var u = p.update
    if (!u) return { text: "Not checked for updates yet  (c)", color: root.muted }
    if (u.error) return { text: "Could not check: " + u.error, color: root.urgent }
    if (u.behind > 0) {
      var text = root.commitsText(u.behind) + " upstream"
      if (u.remoteVersion && u.remoteVersion !== p.version) text += "  ·  " + (p.version || "?") + " → " + u.remoteVersion
      return { text: text, color: root.accent }
    }
    return { text: "Up to date  ·  checked " + root.ago(u.checkedAt), color: root.muted }
  }

  function warnings(p) {
    var list = []
    if (!p) return list
    if (!p.valid) list.push("Invalid plugin: " + p.validationError)
    var u = p.update
    if (p.git && p.git.dirty) list.push("Local changes to tracked files: an update cannot fast-forward")
    if (u && u.ahead > 0 && u.behind > 0) list.push("Diverged from upstream: an update cannot fast-forward")
    else if (u && u.ahead > 0) list.push(u.ahead + " local commit" + (u.ahead === 1 ? "" : "s") + " not upstream")
    return list
  }

  function fields(p) {
    var list = []
    if (!p) return list
    function add(label, value) { if (value) list.push({ label: label, value: String(value) }) }
    add("Id", p.id)
    if (p.manifestId && p.manifestId !== p.id) add("Manifest id", p.manifestId)
    add("Author", p.author)
    add("License", p.license)
    add("Kinds", (p.kinds || []).join(", "))
    add("Status", p.enabled ? "enabled" : "disabled")
    // How it opens: its shortcuts, menu entries and place in the bar. With
    // none of those, the command the Open button runs.
    var opens = p.opens || { shortcuts: [], menu: [], bar: [] }
    for (var i = 0; i < opens.shortcuts.length; i++) {
      var s = opens.shortcuts[i]
      add("Shortcut", s.keys + (s.description ? "  ·  " + s.description : "")
                      + (s.managed ? "  (set here)" : "")
                      + (s.active === false ? "  (not active)" : ""))
    }
    for (var j = 0; j < opens.menu.length; j++) add("Menu", opens.menu[j].path)
    for (var k = 0; k < opens.bar.length; k++) add("Bar", opens.bar[k].section + " section")
    if (opens.shortcuts.length + opens.menu.length + opens.bar.length === 0) add("Opens with", p.openCommand)
    if (p.git) {
      add("Remote", p.git.remote)
      add("Branch", p.git.branch + (p.git.commit ? " @ " + p.git.commit : ""))
      add("Last commit", p.git.subject + (p.git.date ? "  ·  " + p.git.date.slice(0, 10) : ""))
    }
    add("Path", p.path)
    return list
  }

  function handleKey(event) {
    if (root.reviewing) {
      root.reviewKey(event)
      event.accepted = true
      return
    }
    if (root.binding) {
      if (event.key === Qt.Key_Escape) root.closeBind()
      event.accepted = true
      return
    }
    if (root.confirmingRemove || root.confirmingImport) {
      confirm.handleKey(event)
      event.accepted = true
      return
    }
    var key = event.key
    var t = event.text
    if (key === Qt.Key_Escape) root.dismiss()
    else if (key === Qt.Key_Up || t === "k") root.move(-1)
    else if (key === Qt.Key_Down || t === "j") root.move(1)
    else if (key === Qt.Key_Home) root.select(0)
    else if (key === Qt.Key_End) root.select(root.plugins.length - 1)
    else if (key === Qt.Key_Return || key === Qt.Key_Enter) root.openPlugin()
    else if (t === "c") root.checkCurrent()
    else if (t === "C") root.checkAll()
    else if (t === "u") root.updateCurrent()
    else if (t === "e") root.toggleEnabled()
    else if (t === "s") root.askBind()
    else if (t === "d" || key === Qt.Key_Delete) root.askRemove()
    else if (t === "a" || t === "/") urlField.forceActiveFocus()
    else if (t === "x") root.exportPlugins()
    else if (t === "o") root.openRepo()
    else if (t === "r") root.refresh()
    else return
    event.accepted = true
  }

  // ------------------------------------------------------------ processes

  Process {
    id: listProc
    command: [root.backend, "list"]
    stdout: StdioCollector {
      onStreamFinished: root.applyList(text)
    }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim().length > 0) console.warn(root.pluginId + " list:", text.trim())
    }
    onExited: {
      if (root.relistPending) {
        root.relistPending = false
        Qt.callLater(root.refresh)
      }
    }
  }

  Process {
    id: quickProc
    stdout: StdioCollector {
      onStreamFinished: root.applyQuick(text)
    }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim().length > 0) console.warn(root.pluginId + " action:", text.trim())
    }
  }

  // Suggestions and checks for the shortcut dialog, apart from quickProc so
  // typing never waits on an action.
  Process {
    id: keyProc
    stdout: StdioCollector {
      onStreamFinished: root.applyKeys(text)
    }
  }

  Timer {
    id: keyCheckTimer
    interval: 250
    onTriggered: {
      var keys = bindField.text.trim()
      if (keys && root.current) root.runKeys(["keycheck", keys, root.current.id], "check")
    }
  }

  // Read on demand rather than watched: neither file need exist yet.
  FileView {
    id: runningFile
    path: root.stateDir + "/running.json"
    blockLoading: true
    printErrors: false
  }

  FileView {
    id: resultFile
    path: root.stateDir + "/last-action.json"
    blockLoading: true
    printErrors: false
  }

  Timer {
    interval: 400
    repeat: true
    running: root.opened && (root.jobLabel !== "" || root.launching)
    onTriggered: root.syncJobs(false, "")
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.now = Date.now()
  }

  // ------------------------------------------------------------------ view

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-plugin-manager"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea {
        anchors.fill: parent
        onClicked: keyCatcher.forceActiveFocus()
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) { root.handleKey(event) }
      }

      Item {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        // ---------------------------------------------------------- header
        Item {
          id: header
          anchors { left: parent.left; right: parent.right; top: parent.top }
          height: root.headerHeight

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Plugins"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.bold: true
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            color: root.updateCount > 0 ? root.accent : root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            text: {
              var parts = [root.plugins.length + " installed"]
              if (root.updateCount > 0)
                parts.push(root.updateCount === 1 ? "1 update" : root.updateCount + " updates")
              parts.push(root.checkedAt ? "checked " + root.ago(root.checkedAt) : "not checked yet")
              return parts.join("  ·  ")
            }
          }
        }

        // --------------------------------------------------------- add row
        Item {
          id: addRow
          anchors { left: parent.left; right: parent.right; top: header.bottom; topMargin: root.contentSpacing }
          height: urlField.implicitHeight

          TextField {
            id: urlField
            anchors.left: parent.left
            anchors.right: addButton.left
            anchors.rightMargin: Style.spacing.controlGap
            anchors.verticalCenter: parent.verticalCenter
            foreground: root.foreground
            placeholderText: "Git URL of a plugin to add, or an export .json to import  (a)"
            onAccepted: root.addPlugin()
            Keys.onEscapePressed: function(event) {
              if (urlField.text) urlField.text = ""
              else keyCatcher.forceActiveFocus()
              event.accepted = true
            }
          }

          Button {
            id: addButton
            anchors.right: exportButton.left
            anchors.rightMargin: Style.spacing.controlGap
            anchors.verticalCenter: parent.verticalCenter
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            text: "Add"
            tooltipText: "Clone the plugin, which stays disabled until you enable it; or preview importing an export file"
            onClicked: root.addPlugin()
          }

          Button {
            id: exportButton
            anchors.right: checkAllButton.left
            anchors.rightMargin: Style.spacing.controlGap
            anchors.verticalCenter: parent.verticalCenter
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            text: "Export"
            tooltipText: "Write your plugins to a file for another Omarchy install  (x)"
            onClicked: root.exportPlugins()
          }

          Button {
            id: checkAllButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            text: "Check all"
            tooltipText: "Look upstream for updates to every plugin  (C)"
            onClicked: root.checkAll()
          }
        }

        // ------------------------------------------------------------ body
        Item {
          id: body
          anchors { left: parent.left; right: parent.right; top: addRow.bottom; bottom: footer.top }
          anchors.topMargin: root.contentSpacing * 2
          anchors.bottomMargin: root.contentSpacing

          Text {
            anchors.centerIn: parent
            width: parent.width * 0.7
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: root.listedOnce && root.plugins.length === 0
            textFormat: Text.PlainText
            text: "No plugins installed yet.\nPaste the git URL of a plugin above to add one."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          ListView {
            id: pluginList
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: Math.round(parent.width * 0.36)
            clip: true
            spacing: Style.spacing.xxs
            model: root.plugins
            visible: root.plugins.length > 0
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: row
              required property int index
              required property var modelData
              readonly property bool selected: row.index === root.selectedIndex
              readonly property bool working: root.busy && (root.jobId === row.modelData.id || root.busyId === row.modelData.id)

              width: pluginList.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: row.selected ? root.selectedBackground : "transparent"

              Column {
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.right: badges.left
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xxs

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: row.modelData.name
                  color: row.selected ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: root.subtitle(row.modelData)
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                id: badges
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.rowPaddingX
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.md

                Text {
                  visible: root.behind(row.modelData) > 0
                  textFormat: Text.PlainText
                  text: "↑" + root.behind(row.modelData)
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  visible: !row.modelData.valid || (row.modelData.git && row.modelData.git.dirty)
                    || (row.modelData.update && row.modelData.update.error !== "")
                  textFormat: Text.PlainText
                  text: "!"
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: row.working ? "…" : (row.modelData.enabled ? "on" : "off")
                  color: row.modelData.enabled ? root.foreground : root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.select(row.index)
                  keyCatcher.forceActiveFocus()
                }
              }
            }
          }

          Rectangle {
            id: divider
            visible: pluginList.visible
            anchors { left: pluginList.right; leftMargin: root.contentMargin; top: parent.top; bottom: parent.bottom }
            width: 1
            color: root.faint
          }

          // ------------------------------------------------------- details
          Flickable {
            id: details
            visible: root.current !== null
            anchors {
              left: divider.right; leftMargin: root.contentMargin
              right: parent.right; top: parent.top
              bottom: actions.top; bottomMargin: root.contentSpacing
            }
            clip: true
            contentWidth: width
            contentHeight: detailsColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: detailsColumn
              width: details.width
              spacing: root.contentSpacing

              Row {
                spacing: Style.spacing.lg

                Text {
                  id: detailName
                  textFormat: Text.PlainText
                  text: root.current ? root.current.name : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }

                Text {
                  anchors.baseline: detailName.baseline
                  textFormat: Text.PlainText
                  text: root.current && root.current.version ? "v" + root.current.version : ""
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              Text {
                width: parent.width
                visible: text !== ""
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.current ? root.current.description : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                readonly property var line: root.updateLine(root.current)
                text: line.text
                color: line.color
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Repeater {
                model: root.warnings(root.current)

                Text {
                  required property string modelData
                  width: detailsColumn.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: "⚠ " + modelData
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              // What an update would bring in, newest first.
              Column {
                width: parent.width
                spacing: Style.spacing.xs
                visible: root.behind(root.current) > 0

                Repeater {
                  model: root.current && root.current.update ? root.current.update.commits : []

                  Item {
                    id: commitRow
                    required property var modelData
                    width: detailsColumn.width
                    height: commitSubject.implicitHeight

                    Text {
                      id: commitHash
                      textFormat: Text.PlainText
                      text: commitRow.modelData.commit
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                      id: commitSubject
                      anchors.left: commitHash.right
                      anchors.leftMargin: Style.spacing.lg
                      anchors.right: commitDate.left
                      anchors.rightMargin: Style.spacing.lg
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: commitRow.modelData.subject
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                      id: commitDate
                      anchors.right: parent.right
                      textFormat: Text.PlainText
                      text: root.ago(commitRow.modelData.date)
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }

              Rectangle {
                width: parent.width
                height: 1
                color: root.faint
              }

              Repeater {
                model: root.fields(root.current)

                Row {
                  id: fieldRow
                  required property var modelData
                  spacing: Style.spacing.lg

                  Text {
                    width: root.labelWidth
                    textFormat: Text.PlainText
                    text: fieldRow.modelData.label
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    width: detailsColumn.width - root.labelWidth - Style.spacing.lg
                    wrapMode: Text.WrapAnywhere
                    textFormat: Text.PlainText
                    text: fieldRow.modelData.value
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }

          Row {
            id: actions
            visible: root.current !== null
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            spacing: Style.spacing.controlGap

            Button {
              visible: root.current !== null && !root.currentIsSelf
              bordered: true
              foreground: root.current && root.current.openCommand && root.current.enabled ? root.foreground : root.muted
              fontFamily: root.fontFamily
              text: "Open"
              tooltipText: "Close the manager and open this plugin  (⏎)"
              onClicked: root.openPlugin()
            }

            Button {
              visible: root.current !== null
              bordered: true
              foreground: root.current && root.current.openCommand ? root.foreground : root.muted
              fontFamily: root.fontFamily
              text: "Shortcut…"
              tooltipText: "Bind a key combination that opens this plugin  (s)"
              onClicked: root.askBind()
            }

            Button {
              visible: root.current !== null
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: "Check"
              tooltipText: "Look upstream for an update  (c)"
              onClicked: root.checkCurrent()
            }

            Button {
              visible: root.current !== null
              bordered: true
              foreground: root.behind(root.current) > 0 ? root.accent : root.foreground
              fontFamily: root.fontFamily
              text: root.behind(root.current) > 0 ? "Update (" + root.behind(root.current) + ")" : "Update"
              tooltipText: "Review what an update brings in, then update  (u)"
              onClicked: root.updateCurrent()
            }

            Button {
              visible: !root.currentIsSelf
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: root.current && root.current.enabled ? "Disable" : "Enable"
              tooltipText: "Switch the plugin on or off  (e)"
              onClicked: root.toggleEnabled()
            }

            Button {
              visible: root.webUrl(root.current) !== ""
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: "Open repo"
              tooltipText: "Open the repository in the browser  (o)"
              onClicked: root.openRepo()
            }

            // Plain like the rest: the confirmation is where it turns red.
            Button {
              visible: !root.currentIsSelf
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: "Remove"
              tooltipText: "Uninstall the plugin  (d)"
              onClicked: root.askRemove()
            }
          }
        }

        // ---------------------------------------------------------- footer
        Item {
          id: footer
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          height: root.footerHeight

          Text {
            id: statusText
            anchors.left: parent.left
            anchors.right: hints.left
            anchors.rightMargin: Style.spacing.xl
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.busy && root.activityLabel ? root.activityLabel + " …" : root.statusMessage
            color: root.busy ? root.accent : (root.statusError ? root.urgent : root.foreground)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            id: hints
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "↑↓ select   ⏎ open   s shortcut   c check   u update   e enable   d remove   a add/import   x export   o repo   esc close"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // One dialog for both confirmations: removing the selected plugin, and
      // an import whose dry run is waiting in importPreview.
      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        opened: root.confirmingRemove || root.confirmingImport
        background: root.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        cornerRadius: root.cornerRadius
        cancelText: "Cancel"
        confirmText: root.confirmingImport ? "Import" : "Remove"
        message: {
          if (root.confirmingImport) return root.importMessage()
          var p = root.current
          if (!p) return ""
          return "Remove " + p.name + "? Its folder is deleted; the git repo stays upstream."
        }
        onCanceled: {
          root.confirmingRemove = false
          root.confirmingImport = false
          root.importPreview = null
          keyCatcher.forceActiveFocus()
        }
        onConfirmed: {
          if (root.confirmingImport) root.importConfirmed()
          else root.removeCurrent()
        }
      }

      // ------------------------------------------------------------ review
      // What an update brings in: the files it changes and the diff, read
      // before anything is touched.
      Item {
        id: reviewDialog
        anchors.fill: parent
        visible: root.reviewing

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(root.background, 0.7)

          MouseArea {
            anchors.fill: parent
            onClicked: root.cancelReview()
          }
        }

        BorderSurface {
          id: reviewCard
          anchors.fill: parent
          anchors.margins: Style.space(24)
          color: root.background
          borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
          padding: Style.space(18)
          radius: root.cornerRadius

          MouseArea {
            anchors.fill: parent
            onClicked: keyCatcher.forceActiveFocus()
          }

          Item {
            anchors.fill: parent
            anchors.topMargin: reviewCard.contentTopInset
            anchors.rightMargin: reviewCard.contentRightInset
            anchors.bottomMargin: reviewCard.contentBottomInset
            anchors.leftMargin: reviewCard.contentLeftInset

            Text {
              id: reviewTitle
              anchors { left: parent.left; right: parent.right; top: parent.top }
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.review ? "Update " + root.review.name + "?" : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              id: reviewSummary
              anchors { left: parent.left; right: parent.right; top: reviewTitle.bottom; topMargin: Style.spacing.md }
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              text: {
                var r = root.review
                if (!r) return ""
                var parts = [r.message]
                var p = null
                for (var i = 0; i < root.plugins.length; i++) if (root.plugins[i].id === r.id) p = root.plugins[i]
                if (r.entry && r.entry.remoteVersion && p && r.entry.remoteVersion !== p.version)
                  parts.push((p.version || "?") + " → " + r.entry.remoteVersion)
                var text = parts.join("  ·  ")
                if (r.id === root.pluginId) text += "\nThe shell restarts afterwards, to load the new version."
                return text
              }
            }

            Column {
              id: reviewFileList
              anchors { left: parent.left; right: parent.right; top: reviewSummary.bottom; topMargin: Style.spacing.lg }
              spacing: Style.spacing.xxs

              Repeater {
                model: root.reviewFiles.slice(0, 8)

                Row {
                  id: fileRow
                  required property var modelData
                  spacing: Style.spacing.lg

                  Text {
                    width: Style.space(44)
                    horizontalAlignment: Text.AlignRight
                    textFormat: Text.PlainText
                    text: fileRow.modelData.added === null ? "bin" : "+" + fileRow.modelData.added
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    width: Style.space(44)
                    textFormat: Text.PlainText
                    text: fileRow.modelData.deleted === null ? "" : "−" + fileRow.modelData.deleted
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    width: reviewFileList.width - Style.space(88) - Style.spacing.lg * 2
                    elide: Text.ElideMiddle
                    textFormat: Text.PlainText
                    text: fileRow.modelData.path
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Text {
                visible: root.reviewFiles.length > 8
                textFormat: Text.PlainText
                text: "and " + (root.reviewFiles.length - 8) + " more files"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              id: reviewRule
              anchors { left: parent.left; right: parent.right; top: reviewFileList.bottom; topMargin: Style.spacing.lg }
              height: 1
              color: root.faint
            }

            ListView {
              id: reviewList
              anchors {
                left: parent.left; right: parent.right
                top: reviewRule.bottom; topMargin: Style.spacing.md
                bottom: reviewFooter.top; bottomMargin: Style.spacing.md
              }
              clip: true
              model: root.reviewLines
              boundsBehavior: Flickable.StopAtBounds

              delegate: Text {
                required property string modelData
                width: reviewList.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: modelData.length > 400 ? modelData.slice(0, 400) : modelData
                color: root.diffColor(modelData)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Item {
              id: reviewFooter
              anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
              height: reviewButtons.implicitHeight

              Text {
                anchors.left: parent.left
                anchors.right: reviewButtons.left
                anchors.rightMargin: Style.spacing.xl
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.review && root.review.truncated
                  ? "Showing the first " + root.reviewLines.length + " of " + root.review.totalLines + " lines   ·   ↑↓ PgUp PgDn scroll"
                  : "↑↓ PgUp PgDn scroll   ⏎ update   esc cancel"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Row {
                id: reviewButtons
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.controlGap

                Button {
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  text: "Cancel"
                  onClicked: root.cancelReview()
                }

                Button {
                  bordered: true
                  foreground: root.accent
                  fontFamily: root.fontFamily
                  text: "Update"
                  onClicked: root.confirmUpdate()
                }
              }
            }
          }
        }
      }

      // ---------------------------------------------------------- shortcut
      Item {
        id: bindDialog
        anchors.fill: parent
        visible: root.binding

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(root.background, 0.7)

          MouseArea {
            anchors.fill: parent
            onClicked: root.closeBind()
          }
        }

        BorderSurface {
          id: bindCard
          width: Math.min(parent.width - Style.space(32), Style.space(480))
          height: bindCard.contentTopInset + bindCard.contentBottomInset + bindColumn.implicitHeight
          anchors.centerIn: parent
          color: root.background
          borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
          padding: Style.space(18)
          radius: root.cornerRadius

          MouseArea {
            anchors.fill: parent
            onClicked: bindField.forceActiveFocus()
          }

          Column {
            id: bindColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: bindCard.contentTopInset
            anchors.leftMargin: bindCard.contentLeftInset
            anchors.rightMargin: bindCard.contentRightInset
            spacing: Style.spacing.lg

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.current ? "Shortcut for " + root.current.name : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              wrapMode: Text.WrapAnywhere
              textFormat: Text.PlainText
              text: root.current ? "Runs: " + root.current.openCommand : ""
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            TextField {
              id: bindField
              width: parent.width
              foreground: root.foreground
              placeholderText: "SUPER + ALT + D"
              onTextChanged: {
                root.keyCheck = null
                keyCheckTimer.restart()
              }
              Keys.onReturnPressed: function(event) {
                root.saveBind()
                event.accepted = true
              }
              Keys.onEnterPressed: function(event) {
                root.saveBind()
                event.accepted = true
              }
              Keys.onEscapePressed: function(event) {
                root.closeBind()
                event.accepted = true
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              readonly property var state: root.bindStatus()
              text: state.text
              color: state.color
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: root.managedShortcut(root.current) !== null
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.managedShortcut(root.current)
                ? "Now: " + root.managedShortcut(root.current).keys + ", set here earlier. Saving moves it." : ""
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item {
              width: parent.width
              height: bindButtons.implicitHeight

              Row {
                id: bindButtons
                anchors.right: parent.right
                spacing: Style.spacing.controlGap

                Button {
                  visible: root.managedShortcut(root.current) !== null
                  bordered: true
                  foreground: root.urgent
                  fontFamily: root.fontFamily
                  text: "Remove shortcut"
                  onClicked: root.removeBind()
                }

                Button {
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  text: "Cancel"
                  onClicked: root.closeBind()
                }

                Button {
                  bordered: true
                  foreground: root.keyCheck && root.keyCheck.ok ? root.accent : root.muted
                  fontFamily: root.fontFamily
                  text: root.keyCheck && root.keyCheck.ok && root.keyCheck.taken ? "Take over" : "Save"
                  onClicked: root.saveBind()
                }
              }
            }
          }
        }
      }
    }
  }
}
