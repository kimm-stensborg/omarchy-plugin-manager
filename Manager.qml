import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import qs.Commons
import qs.Ui

// Plugin Manager. Lists the git plugins in ~/.config/omarchy/plugins -- never
// the built-in omarchy.* ones -- with their details, how each one opens,
// whether an update is waiting, and the actions to open, read, review and
// update, roll back, enable, disable, give a shortcut or a menu entry to,
// remove or add one. It lists itself too, so it can update itself, but it will
// not switch itself off or remove itself. Every action runs bin/plugin-manager;
// this file only renders what comes back.
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
  readonly property string pluginGlyph: "󰐱"
  // How old the update check may be before opening the manager redoes it.
  readonly property int staleSeconds: 6 * 3600

  property bool opened: false
  property var plugins: []
  property bool avatarsAsked: false
  property string checkedAt: ""
  property int selectedIndex: 0
  // Select this id once the next list arrives -- a plugin that was just added.
  property string selectId: ""
  property bool listing: false
  property bool listedOnce: false
  property bool relistPending: false

  // Update checks, reviews, reads, exports, import previews, shortcut and menu
  // changes run in-process: none of them rescans the shell.
  property string busyLabel: ""
  property string busyId: ""
  property string busyKind: ""
  property bool busyQuiet: false

  // An import being chosen: the dry run's reply for the file picked, and
  // which of the plugins it would install are ticked (id → true).
  property var importPreview: null
  property var importChosen: ({})
  property int importCursor: 0
  readonly property var importPlan: root.importPreview && root.importPreview.plan ? root.importPreview.plan : []
  readonly property var importPicked: root.importPlan.filter(function(item) {
    return item.action === "install" && root.importChosen[item.id] === true
  })
  readonly property int importInstallable: root.importPlan.filter(function(item) {
    return item.action === "install"
  }).length
  readonly property bool importAllHere: root.importPlan.length > 0 && root.importPlan.every(function(item) {
    return item.reason === "already installed"
  })

  // The SOURCE section of the details: folded to the repository, or all of it.
  property bool sourceOpen: false

  // An update waiting on its review: the reply of `plugin-manager review`.
  property bool reviewing: false
  property var review: null
  readonly property var reviewFiles: root.review && root.review.files ? root.review.files : []
  readonly property var reviewLines: root.review && root.review.diff
    ? String(root.review.diff).replace(/\n$/, "").split("\n") : []

  // A plugin being read before it is switched on: `plugin-manager inspect`.
  // A plugin just added is read as soon as the list has it.
  property bool inspecting: false
  property var inspection: null
  property string pendingInspect: ""

  property bool confirmingRollback: false

  // The shortcut dialog, and what the backend made of the keys typed into it.
  property bool binding: false
  property var keyCheck: null
  property string keyMode: ""
  property var keySuggestions: []
  property bool showSuggestions: false

  // The menu dialog: where in the Omarchy menu the entry goes. Setup › Plugins
  // first, as the place for them; the rest are the menu's top-level sections.
  property bool menuing: false
  property string menuParent: "setup.plugin"
  readonly property var menuPlaces: [
    { key: "setup.plugin", label: "Setup › Plugins" },
    { key: "", label: "Top level" },
    { key: "apps", label: "Apps" },
    { key: "setup", label: "Setup" },
    { key: "system", label: "System" },
    { key: "trigger", label: "Trigger" }
  ]

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
  readonly property var primary: root.primaryAction(root.current)
  readonly property string primaryKind: root.primary ? root.primary.kind : ""
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
  // Keycaps, tags and the text beside them in the shortcut and menu section.
  readonly property int tagHeight: Math.ceil(Style.font.bodySmall * 1.4) + Style.spacing.xxs * 2
  readonly property int avatarSize: Math.round(root.rowHeight * 0.6)
  readonly property int cardWidth: Math.min(Style.space(1040), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(640), panel.height - Style.gapsOut * 2)
  readonly property int detailAvatarSize: Math.round(root.avatarSize * 1.8)
  // Between the sections of the details; the kit's spacing tokens top out
  // at a dozen pixels, which is room within a section, not between them.
  readonly property int sectionGap: Style.space(14)

  // A plugin's author: the GitHub avatar, or initials without one. In each
  // list row, and larger at the head of the details. Inline components do
  // not see `root`, so this and Pill take the theme tokens straight.
  component Avatar: ClippingRectangle {
    id: avatarRoot
    property var plugin: null
    property string initials: ""
    property real fontSize: Style.font.caption

    radius: width / 2
    color: Util.alpha(Color.menu.text, 0.15)

    Text {
      anchors.centerIn: parent
      visible: avatarImage.status !== Image.Ready
      textFormat: Text.PlainText
      text: avatarRoot.initials
      color: Util.alpha(Color.menu.text, 0.6)
      font.family: Style.font.menuFamily
      font.pixelSize: avatarRoot.fontSize
      font.bold: true
    }

    Image {
      id: avatarImage
      anchors.fill: parent
      source: avatarRoot.plugin && avatarRoot.plugin.avatar ? Util.fileUrl(avatarRoot.plugin.avatar) : ""
      sourceSize.width: 128
      sourceSize.height: 128
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      smooth: true
      mipmap: true
    }
  }

  // A small rounded tag: whether a plugin is on, its kinds, an update count,
  // a problem, an override.
  component Pill: Rectangle {
    id: pill
    property string text: ""
    property color tint: Color.menu.text
    property color textColor: tint
    property bool bold: false

    width: Math.max(height, pillText.implicitWidth + Style.spacing.md * 2)
    height: Math.ceil(Style.font.bodySmall * 1.4) + Style.spacing.xxs * 2
    radius: height / 2
    color: Util.alpha(pill.tint, 0.12)
    border.width: 1
    border.color: Util.alpha(pill.tint, 0.35)

    Text {
      id: pillText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: pill.text
      color: pill.textColor
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
      font.bold: pill.bold
    }
  }

  // ------------------------------------------------------------- lifecycle

  // Payload: {"select": "<id>"} preselects a plugin; {"resume": "<seq>"} is a
  // detached job coming back to show its result; {"import": "<path>"} is the
  // file chooser coming back with an export to import, and {"status": "…",
  // "error": bool} with something to say instead (see pickImport).
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (!payload || typeof payload !== "object") payload = ({})

    root.opened = true
    root.closeDialogs()
    root.now = Date.now()
    if (payload.select) root.selectId = String(payload.select)
    if (payload.status) root.setStatus(String(payload.status), payload.error === true)
    root.syncJobs(true, payload.resume ? String(payload.resume) : "")
    root.refresh()
    // A file picked to import is read first. Otherwise a stale check is
    // redone on open, and a fresh one comes straight back.
    if (payload.import) root.previewImport(String(payload.import))
    else if (!root.busy) root.runAction(["check", "--if-stale", String(root.staleSeconds)],
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
    root.confirmingRollback = false
    root.importPreview = null
    root.importChosen = ({})
    root.reviewing = false
    root.review = null
    root.inspecting = false
    root.inspection = null
    root.binding = false
    root.keyCheck = null
    root.menuing = false
  }

  // User-initiated closes go through the host so its open-panel state stays in
  // step, and land back in close().
  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    else root.close()
  }

  function ping() { return "ok" }

  // For driving the overlay over IPC (`omarchy-shell shell call <id> …`): a
  // script selects by id and reads the selection back before acting on it,
  // and finds the card on screen to take a picture of it.
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

  function cardGeometry() {
    var p = card.mapToItem(null, 0, 0)
    return JSON.stringify({ x: Math.round(p.x), y: Math.round(p.y),
                            width: Math.round(card.width), height: Math.round(card.height) })
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
    root.inspectPending()
    root.fetchAvatars()
  }

  // Fetch the GitHub avatars the list is missing, once per load and in the
  // background; the list is read again when any came in.
  function fetchAvatars() {
    if (root.avatarsAsked || avatarProc.running) return
    if (!root.plugins.some(function(p) { return p.owner && !p.avatar })) return
    root.avatarsAsked = true
    avatarProc.running = true
  }

  // Up to two initials for a plugin without an avatar: its author's, else
  // its own name's.
  function initials(p) {
    var words = String(p && (p.author || p.name) || "").split(/[\s._-]+/)
                  .filter(function(w) { return w.length > 0 })
    return words.slice(0, 2).map(function(w) { return w.charAt(0).toUpperCase() }).join("")
  }

  // --------------------------------------------------------------- actions

  readonly property var quickKinds: ["check", "export", "preview", "review", "inspect", "bind", "unbind",
                                     "menu", "menuremove"]

  // One action at a time: they all end in the stock commands, which rescan
  // the shell and would trip over each other.
  function runAction(args, label, id, kind, quiet) {
    if (root.busy || quickProc.running) {
      if (!quiet) root.setStatus("Still " + root.activityLabel.toLowerCase() + " …", false)
      return false
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
      return true
    }

    root.jobLabel = label
    root.jobId = id || ""
    root.launching = true
    root.launchedAt = Date.now()
    Quickshell.execDetached([root.backend, "run", "--label", label, "--id", id || "", "--kind", kind, "--"]
                            .concat(args))
    return true
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
    } else if (kind === "inspect") {
      root.showInspect(payload)
      return
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
        // A plugin lands disabled so it can be read first; open it for reading.
        root.pendingInspect = payload.id
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

  function scrollView(view, dy) {
    var max = Math.max(0, view.contentHeight - view.height)
    view.contentY = Math.max(0, Math.min(max, view.contentY + dy))
  }

  // j/k, arrows, PgUp/PgDn, space, Home and End for a scrolling dialog.
  function scrollKey(view, event) {
    var key = event.key
    var t = event.text
    var line = Style.font.caption + Style.spacing.xxs
    if (key === Qt.Key_Down || t === "j") root.scrollView(view, line * 3)
    else if (key === Qt.Key_Up || t === "k") root.scrollView(view, -line * 3)
    else if (key === Qt.Key_PageDown || key === Qt.Key_Space) root.scrollView(view, view.height * 0.9)
    else if (key === Qt.Key_PageUp) root.scrollView(view, -view.height * 0.9)
    else if (key === Qt.Key_Home) view.contentY = 0
    else if (key === Qt.Key_End) root.scrollView(view, view.contentHeight)
  }

  function reviewKey(event) {
    if (event.key === Qt.Key_Escape) root.cancelReview()
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.confirmUpdate()
    else root.scrollKey(reviewList, event)
  }

  function diffColor(line) {
    if (/^(\+\+\+|---|diff |index |new file|deleted file|similarity|rename )/.test(line)) return root.muted
    if (line.charAt(0) === "+") return root.accent
    if (line.charAt(0) === "-") return root.urgent
    if (line.indexOf("@@") === 0) return root.selectedText
    return root.foreground
  }

  // ---------------------------------------------------------------- reading

  // What a plugin is, before it runs: the kinds the shell will load it as,
  // the files it ships -- the executable ones marked -- and its README.
  function inspectCurrent() {
    var p = root.current
    if (p) root.runAction(["inspect", p.id], "Reading " + p.name, p.id, "inspect", false)
  }

  // A plugin just added is read as soon as nothing else is running; until
  // then it waits here, and the list or the check that finishes tries again.
  function inspectPending() {
    var id = root.pendingInspect
    if (!id || root.busy || quickProc.running) return
    if (root.runAction(["inspect", id], "Reading " + root.nameOf(id), id, "inspect", true)) root.pendingInspect = ""
  }

  function showInspect(payload) {
    root.inspection = payload
    root.inspecting = true
    Qt.callLater(function() { inspectView.contentY = 0 })
  }

  function closeInspect() {
    root.inspecting = false
    root.inspection = null
    keyCatcher.forceActiveFocus()
    root.inspectPending()
  }

  function inspectedPlugin() {
    var i = root.inspection
    if (!i) return null
    for (var k = 0; k < root.plugins.length; k++) if (root.plugins[k].id === i.id) return root.plugins[k]
    return null
  }

  function enableInspected() {
    var p = root.inspectedPlugin()
    root.closeInspect()
    if (!p || p.enabled || p.self) return
    root.selectById(p.id)
    root.toggleEnabled()
  }

  // The file manager cannot be used under the overlay, so the manager closes.
  function openFolder(path) {
    if (!path) return
    root.dismiss()
    Quickshell.execDetached(["uwsm-app", "--", "xdg-open", path])
  }

  function inspectKey(event) {
    var t = event.text
    if (event.key === Qt.Key_Escape) root.closeInspect()
    else if (t === "e") root.enableInspected()
    else if (t === "f") root.openFolder(root.inspection ? root.inspection.path : "")
    else root.scrollKey(inspectView, event)
  }

  // Markdown for the dialog: images out, since the dialog is no place for a
  // screenshot at full size.
  function readmeText(text) {
    return String(text || "").replace(/!\[[^\]]*\]\([^)]*\)/g, "")
  }

  function sizeText(bytes) {
    if (bytes < 1024) return bytes + " B"
    if (bytes < 1024 * 1024) return Math.round(bytes / 1024) + " KB"
    return (bytes / 1024 / 1024).toFixed(1) + " MB"
  }

  // -------------------------------------------------------------- rollback

  function askRollback() {
    var p = root.current
    if (!p || root.busy) return
    if (!p.rollback) {
      root.setStatus("There is no update of " + p.name + " to roll back", false)
      return
    }
    confirm.selectedIndex = 0
    root.confirmingRollback = true
  }

  function rollbackMessage() {
    var p = root.current
    if (!p || !p.rollback) return ""
    var text = "Roll " + p.name + " back to " + p.rollback.from
      + (p.rollback.fromVersion ? " (v" + p.rollback.fromVersion + ")" : "")
      + ", where it was before its update " + root.ago(p.rollback.at) + "?"
    text += "\n\nThe update shows as waiting again, to install later."
    if (p.self) text += " The shell restarts afterwards."
    return text
  }

  function rollbackCurrent() {
    root.confirmingRollback = false
    keyCatcher.forceActiveFocus()
    var p = root.current
    if (!p) return
    root.runAction(["rollback", p.id], "Rolling back " + p.name, p.id, p.self ? "self-update" : "rollback", false)
  }

  // --------------------------------------------------------- other actions

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

  // Import…: the desktop's file chooser picks an export, and the manager
  // comes back with it (see `plugin-manager pick-import`). The chooser cannot
  // be used under the overlay, so the manager steps aside meanwhile.
  function pickImport() {
    if (root.busy) {
      root.setStatus("Still " + root.activityLabel.toLowerCase() + " …", false)
      return
    }
    root.dismiss()
    Quickshell.execDetached([root.backend, "pick-import"])
  }

  // A dry run came back: list everything the file holds, the plugins it
  // would install ticked to choose from. With none, the list still shows why
  // -- already installed, most often -- and the dialog only closes.
  function showImportPreview(payload) {
    var plan = payload.plan || []
    var chosen = ({})
    var first = -1
    for (var i = 0; i < plan.length; i++) {
      if (plan[i].action !== "install") continue
      chosen[plan[i].id] = true
      if (first < 0) first = i
    }
    root.importChosen = chosen
    root.importCursor = first
    root.importPreview = payload
  }

  function toggleImport(index) {
    var item = root.importPlan[index]
    if (!item || item.action !== "install") return
    var chosen = Object.assign({}, root.importChosen)
    chosen[item.id] = !chosen[item.id]
    root.importChosen = chosen
  }

  // The cursor moves between the plugins that can be imported only.
  function moveImportCursor(delta) {
    for (var i = root.importCursor + delta; i >= 0 && i < root.importPlan.length; i += delta) {
      if (root.importPlan[i].action === "install") {
        root.importCursor = i
        importList.positionViewAtIndex(i, ListView.Contain)
        return
      }
    }
  }

  function cancelImport() {
    root.importPreview = null
    root.importChosen = ({})
    keyCatcher.forceActiveFocus()
  }

  function importChosenPlugins() {
    var p = root.importPreview
    var ids = root.importPicked.map(function(item) { return item.id })
    if (!p || !p.path || ids.length === 0) return
    root.cancelImport()
    root.runAction(["import", p.path, "--only", ids.join(",")],
                   "Importing " + (ids.length === 1 ? "1 plugin" : ids.length + " plugins"), "", "import", false)
    urlField.text = ""
  }

  function importKey(event) {
    var key = event.key
    var t = event.text
    if (key === Qt.Key_Escape) root.cancelImport()
    else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
      if (root.importInstallable > 0) root.importChosenPlugins()
      else root.cancelImport()
    }
    else if (key === Qt.Key_Space) root.toggleImport(root.importCursor)
    else if (key === Qt.Key_Up || t === "k") root.moveImportCursor(-1)
    else if (key === Qt.Key_Down || t === "j") root.moveImportCursor(1)
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
    root.keySuggestions = []
    root.showSuggestions = false
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

  // Free combinations to pick from, beside typing one. They come with the
  // proposal when the dialog opens, and are asked for again here should
  // typing have cut that short.
  function toggleSuggestions() {
    root.showSuggestions = !root.showSuggestions
    if (root.showSuggestions && root.keySuggestions.length === 0 && root.current)
      root.runKeys(["suggest-key", root.current.id], "suggestions")
    bindField.forceActiveFocus()
  }

  // Filling the field sets off the same check as typing.
  function pickSuggestion(keys) {
    bindField.text = keys
    bindField.forceActiveFocus()
  }

  function runKeys(args, mode) {
    keyProc.running = false
    root.keyMode = mode
    keyProc.command = [root.backend].concat(args)
    keyProc.running = true
  }

  function applyKeys(text) {
    var payload = root.parseJson(text)
    if (root.keyMode === "suggest" || root.keyMode === "suggestions") {
      root.keySuggestions = payload && payload.suggestions ? payload.suggestions : []
      // Setting the text sets off the check of what was suggested.
      if (root.keyMode === "suggest" && payload && payload.ok && payload.keys && bindField.text === "")
        bindField.text = payload.keys
      // Asking for suggestions may have cut a check short: check again.
      else if (bindField.text.trim() && !root.keyCheck) keyCheckTimer.restart()
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

  // ------------------------------------------------------------------- menu

  // The menu dialog puts an entry for the plugin into the Omarchy menu, one
  // that runs what Open runs. The manager only moves and removes the entries
  // it wrote itself; the backend picks an id nothing else has.
  function askMenu() {
    var p = root.current
    if (!p) return
    if (!p.openCommand) {
      root.setStatus(p.name + " has no window to open, so there is nothing to put in the menu", false)
      return
    }
    var own = root.managedMenu(p)
    root.menuParent = own ? root.parentOf(own.entry) : "setup.plugin"
    menuLabel.text = own && own.label ? own.label : p.name
    menuDescription.text = own ? (own.description || "") : (p.description || "")
    menuIcon.text = own && own.icon ? own.icon : root.pluginGlyph
    root.menuing = true
    Qt.callLater(function() { menuLabel.forceActiveFocus() })
  }

  function closeMenu() {
    root.menuing = false
    keyCatcher.forceActiveFocus()
  }

  function saveMenu() {
    var p = root.current
    if (!p) return
    var label = menuLabel.text.trim()
    if (!label) {
      menuLabel.forceActiveFocus()
      return
    }
    var args = ["menu-add", p.id, "--parent", root.menuParent, "--label", label,
                "--description", menuDescription.text.trim(), "--icon", menuIcon.text.trim() || root.pluginGlyph]
    root.closeMenu()
    root.runAction(args, "Adding " + label + " to the menu", p.id, "menu", false)
  }

  function removeMenu() {
    var p = root.current
    if (!p) return
    root.closeMenu()
    root.runAction(["menu-remove", p.id], "Taking " + p.name + " out of the menu", p.id, "menuremove", false)
  }

  function managedMenu(p) {
    var entries = p && p.opens ? p.opens.menu : []
    for (var i = 0; i < entries.length; i++) if (entries[i].managed) return entries[i]
    return null
  }

  // The shortcut and the menu entry, side by side under the details. With
  // something to open, each is a click away from its dialog, which also moves
  // or removes what the manager looks after and adds another beside anything
  // set elsewhere; one not set yet offers to add it. A plugin with nothing to
  // open shows only what it already has.
  function openers(p) {
    if (!p) return []
    var opens = p.opens || { shortcuts: [], menu: [] }
    var canOpen = !!p.openCommand
    // A shortcut's own description only where it tells something: beside
    // another shortcut, or when it is more than the plugin's name again.
    var many = opens.shortcuts.length > 1
    var cells = [
      { title: "Shortcut", kind: canOpen ? "shortcut" : "", add: "Add a shortcut",
        lines: opens.shortcuts.map(function(s) {
          var note = (s.description || "").trim()
          return { keys: s.keys.split(" + "),
                   note: many || note.toLowerCase() !== (p.name || "").toLowerCase() ? note : "",
                   override: s.addedBy === "manager",
                   inactive: s.active === false }
        }) },
      { title: "Menu", kind: canOpen ? "menu" : "", add: "Add to the menu",
        lines: opens.menu.map(function(m) {
          return { path: m.path.split(" › "), override: m.addedBy === "manager" }
        }) }
    ]
    return cells.filter(function(c) { return canOpen || c.lines.length > 0 })
                .map(function(c) { if (!c.lines.length) c.lines = [{ none: true }]; return c })
  }

  function openerAction(kind) {
    if (kind === "shortcut") root.askBind()
    else if (kind === "menu") root.askMenu()
  }

  // "setup.plugin.kappa" sits under "setup.plugin"; a top-level id under "".
  function parentOf(entry) {
    var parts = String(entry || "").split(".")
    parts.pop()
    return parts.join(".")
  }

  function menuPreview() {
    var label = menuLabel.text.trim() || "…"
    for (var i = 0; i < root.menuPlaces.length; i++) {
      var place = root.menuPlaces[i]
      if (place.key === root.menuParent) return place.key === "" ? label : place.label + " › " + label
    }
    return label
  }

  function menuKey(event) {
    if (event.key === Qt.Key_Escape) {
      root.closeMenu()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.saveMenu()
      event.accepted = true
    }
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
    if (!p.enabled) parts.push("disabled")
    return parts.join("  ·  ")
  }

  // Under the name in the details: who wrote it, its license, and the kinds
  // the shell loads it as.
  function byline(p) {
    var parts = []
    if (p && p.author) parts.push("by " + p.author)
    if (p && p.license) parts.push(p.license)
    if (p && p.kinds && p.kinds.length) parts.push(p.kinds.join(", "))
    return parts.join("  ·  ")
  }

  // The one pill beside the name: whether it is on.
  function statusTag(p) {
    return p && p.enabled ? { text: "● enabled", tint: root.accent, textColor: root.accent }
                          : { text: "○ disabled", tint: root.foreground, textColor: root.foreground }
  }

  // The one action that stands out under the details: the update waiting,
  // else switching a disabled plugin on, else opening it.
  function primaryAction(p) {
    if (!p) return null
    var n = root.behind(p)
    if (n > 0)
      return { kind: "update", text: "Update (" + n + ")", tip: "Review what an update brings in, then update  (u)" }
    if (!p.self && !p.enabled && p.valid)
      return { kind: "enable", text: "Enable", tip: "Switch the plugin on  (e)" }
    if (!p.self && p.enabled && p.openCommand)
      return { kind: "open", text: "Open", tip: "Close the manager and open this plugin  (⏎)" }
    return null
  }

  function runPrimary(kind) {
    if (kind === "update") root.updateCurrent()
    else if (kind === "enable") root.toggleEnabled()
    else if (kind === "open") root.openPlugin()
  }

  // /home/me/… as ~/…
  function homePath(path) {
    var home = Quickshell.env("HOME")
    var s = String(path || "")
    return home && s.indexOf(home + "/") === 0 ? "~" + s.slice(home.length) : s
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
    if (!u) return { text: "Not checked for updates yet", color: root.muted }
    if (u.error) return { text: "Could not check: " + u.error, color: root.urgent }
    if (u.behind > 0) {
      var text = root.commitsText(u.behind) + " upstream"
      if (u.remoteVersion && u.remoteVersion !== p.version) text += "  ·  " + (p.version || "?") + " → " + u.remoteVersion
      return { text: text, color: root.accent }
    }
    // Up to date is no news: the header says when everything was checked.
    return { text: "", color: root.muted }
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

  // The facts under the shortcut and menu section. Its place in the bar;
  // with no shortcut, menu entry or bar place, the command the Open button
  // runs; and its last update, which can be rolled back.
  function facts(p) {
    var list = []
    if (!p) return list
    function add(label, value) { if (value) list.push({ label: label, value: String(value) }) }
    var opens = p.opens || { shortcuts: [], menu: [], bar: [] }
    for (var k = 0; k < opens.bar.length; k++) add("Bar", opens.bar[k].section + " section")
    if (opens.shortcuts.length + opens.menu.length + opens.bar.length === 0) add("Opens with", p.openCommand)
    if (p.rollback)
      add("Last update", root.ago(p.rollback.at) + ", from " + p.rollback.from
                         + (p.rollback.fromVersion ? " (v" + p.rollback.fromVersion + ")" : "") + "  ·  b rolls it back")
    return list
  }

  // Where it comes from, under a header of its own at the bottom: folded to
  // the repository until the header is clicked. The repository opens in the
  // browser and the path in the file manager.
  function sourceFields(p, open) {
    var list = []
    if (!p) return list
    function add(label, value, action) {
      if (value) list.push({ label: label, value: String(value), action: action || "" })
    }
    var web = root.webUrl(p)
    if (p.git) add("Repository", web.replace(/^https?:\/\//, "") || p.git.remote, web ? "repo" : "")
    if (!open) return list
    if (p.git) {
      add("Branch", p.git.branch + (p.git.commit ? " @ " + p.git.commit : ""))
      add("Last commit", p.git.subject + (p.git.date ? "  ·  " + p.git.date.slice(0, 10) : ""))
    }
    add("Id", p.id)
    if (p.manifestId && p.manifestId !== p.id) add("Manifest id", p.manifestId)
    add("Path", root.homePath(p.path), "folder")
    return list
  }

  function fieldAction(action) {
    if (action === "repo") root.openRepo()
    else if (action === "folder") root.openFolder(root.current ? root.current.path : "")
  }

  function handleKey(event) {
    if (root.reviewing) {
      root.reviewKey(event)
      event.accepted = true
      return
    }
    if (root.inspecting) {
      root.inspectKey(event)
      event.accepted = true
      return
    }
    if (root.binding) {
      if (event.key === Qt.Key_Escape) root.closeBind()
      event.accepted = true
      return
    }
    if (root.menuing) {
      if (event.key === Qt.Key_Escape) root.closeMenu()
      event.accepted = true
      return
    }
    if (root.importPreview) {
      root.importKey(event)
      event.accepted = true
      return
    }
    if (root.confirmingRemove || root.confirmingRollback) {
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
    else if (t === "i") root.inspectCurrent()
    else if (t === "c") root.checkCurrent()
    else if (t === "C") root.checkAll()
    else if (t === "u") root.updateCurrent()
    else if (t === "b") root.askRollback()
    else if (t === "e") root.toggleEnabled()
    else if (t === "s") root.askBind()
    else if (t === "m") root.askMenu()
    else if (t === "d" || key === Qt.Key_Delete) root.askRemove()
    else if (t === "a" || t === "/") urlField.forceActiveFocus()
    else if (t === "x") root.exportPlugins()
    else if (t === "I") root.pickImport()
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
    onExited: Qt.callLater(root.inspectPending)
  }

  // Avatars, apart from the rest: it waits on the network.
  Process {
    id: avatarProc
    command: [root.backend, "avatars"]
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = root.parseJson(text)
        if (payload && payload.fetched && payload.fetched.length > 0) root.refresh()
      }
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

          // What there is and when it was checked, and a quiet button to check
          // it all again; pulled out by its padding so its text meets the edge.
          Row {
            anchors.right: parent.right
            anchors.rightMargin: -Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Text {
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

            Button {
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.muted
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.md
              verticalPadding: Style.spacing.xxs
              text: "Check all"
              tooltipText: "Look upstream for updates to every plugin  (C)"
              onClicked: root.checkAll()
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
            placeholderText: "Git URL of a plugin to add  (a)"
            onAccepted: root.addPlugin()
            Keys.onEscapePressed: function(event) {
              if (urlField.text) urlField.text = ""
              else keyCatcher.forceActiveFocus()
              event.accepted = true
            }
          }

          Button {
            id: addButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            text: "Add"
            tooltipText: "Clone the plugin, which stays disabled until you enable it"
            onClicked: root.addPlugin()
          }        }

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
            text: "No plugins installed yet.\nPaste the git URL of a plugin above to add one,\nor Import… the plugins you exported on another machine."
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

              // A disabled plugin is greyed out: its avatar faded, its name muted.
              Avatar {
                id: avatar
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.verticalCenter: parent.verticalCenter
                width: root.avatarSize
                height: root.avatarSize
                opacity: row.modelData.enabled ? 1 : 0.45
                plugin: row.modelData
                initials: root.initials(row.modelData)
              }

              Column {
                anchors.left: avatar.right
                anchors.leftMargin: Style.spacing.lg
                anchors.right: badges.left
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xxs

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: row.modelData.name
                  color: row.selected ? root.selectedText : (row.modelData.enabled ? root.foreground : root.muted)
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
                spacing: Style.spacing.sm

                Text {
                  visible: row.working
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "…"
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Pill {
                  visible: root.behind(row.modelData) > 0
                  text: "↑ " + root.behind(row.modelData)
                  tint: root.accent
                  bold: true
                }

                Pill {
                  visible: !row.modelData.valid || (row.modelData.git && row.modelData.git.dirty)
                    || (row.modelData.update && row.modelData.update.error !== "")
                  text: "!"
                  tint: root.urgent
                  bold: true
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

              // The head, two lines beside its author's avatar: the name, its
              // version and whether it is on; then who wrote it, the license
              // and the kinds.
              Row {
                width: parent.width
                spacing: Style.space(12)

                Avatar {
                  id: detailAvatar
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.detailAvatarSize
                  height: root.detailAvatarSize
                  plugin: root.current
                  initials: root.initials(root.current)
                  fontSize: Style.font.body
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - detailAvatar.width - parent.spacing
                  spacing: Style.space(4)

                  Row {
                    width: parent.width
                    spacing: Style.spacing.lg

                    Text {
                      id: detailName
                      width: Math.min(implicitWidth,
                                      parent.width - detailVersion.implicitWidth - detailStatus.width - parent.spacing * 2)
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: root.current ? root.current.name : ""
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.heading
                      font.bold: true
                    }

                    Text {
                      id: detailVersion
                      anchors.baseline: detailName.baseline
                      textFormat: Text.PlainText
                      text: root.current && root.current.version ? "v" + root.current.version : ""
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    Pill {
                      id: detailStatus
                      readonly property var tag: root.statusTag(root.current)
                      anchors.verticalCenter: detailName.verticalCenter
                      text: tag.text
                      tint: tag.tint
                      textColor: tag.textColor
                    }
                  }

                  Text {
                    width: parent.width
                    visible: text !== ""
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: root.byline(root.current)
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              // A section apart from the head, and airy enough to read when it
              // wraps. The padding tops the column's spacing up to sectionGap.
              Text {
                width: parent.width
                visible: text !== ""
                topPadding: root.sectionGap - detailsColumn.spacing
                lineHeight: 1.2
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.current ? root.current.description : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              // How it stands with upstream when there is news -- an update,
              // an error, never checked -- and a quiet button to ask again.
              Row {
                width: parent.width
                visible: root.updateLine(root.current).text !== ""
                spacing: Style.spacing.md

                Text {
                  readonly property var line: root.updateLine(root.current)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(implicitWidth, parent.width - checkButton.width - parent.spacing)
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: line.text
                  color: line.color
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Button {
                  id: checkButton
                  anchors.verticalCenter: parent.verticalCenter
                  foreground: root.muted
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.md
                  verticalPadding: Style.spacing.xxs
                  text: "Check"
                  tooltipText: "Look upstream for an update  (c)"
                  onClicked: root.checkCurrent()
                }
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

              // The rule between sections, with sectionGap on either side.
              Item {
                width: parent.width
                height: (root.sectionGap - detailsColumn.spacing) * 2 + 1

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width
                  height: 1
                  color: root.faint
                }
              }

              // One fact: its label, and its value wrapping under itself.
              Component {
                id: fieldDelegate

                Row {
                  id: fieldRow
                  required property var modelData
                  spacing: Style.spacing.lg

                  // On the value's first baseline, not its top: the label is
                  // the smaller of the two.
                  Text {
                    anchors.baseline: fieldValue.baseline
                    width: root.labelWidth
                    textFormat: Text.PlainText
                    text: fieldRow.modelData.label
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  // A value that opens something reads as a link.
                  Text {
                    id: fieldValue
                    width: detailsColumn.width - root.labelWidth - Style.spacing.lg
                    wrapMode: Text.WrapAnywhere
                    textFormat: Text.PlainText
                    text: fieldRow.modelData.value
                    color: fieldRow.modelData.action ? root.accent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.underline: fieldLink.containsMouse

                    MouseArea {
                      id: fieldLink
                      // As wide as the text, not the rest of the row.
                      width: parent.contentWidth
                      height: parent.height
                      enabled: !!fieldRow.modelData.action
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.fieldAction(fieldRow.modelData.action)
                    }
                  }
                }
              }

              // Shortcut and menu side by side, each a click away from its
              // dialog (see openers). Wider than the column by the cells'
              // padding, so their text lines up with the rest.
              Row {
                id: openersRow
                x: -Style.spacing.sm
                width: parent.width + Style.spacing.sm * 2
                visible: openersRepeater.count > 0
                spacing: Style.spacing.md

                Repeater {
                  id: openersRepeater
                  model: root.openers(root.current)

                  Rectangle {
                    id: openerRow
                    required property var modelData
                    readonly property bool editable: openerRow.modelData.kind !== ""

                    width: (openersRow.width - openersRow.spacing * (openersRepeater.count - 1)) / openersRepeater.count
                    height: openerText.implicitHeight + Style.spacing.sm * 2
                    radius: root.cornerRadius
                    color: openerMouse.containsMouse ? Util.alpha(root.foreground, 0.06) : "transparent"

                    Column {
                      id: openerText
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.margins: Style.spacing.sm
                      spacing: Style.spacing.xxs

                      Text {
                        textFormat: Text.PlainText
                        text: openerRow.modelData.title
                        color: root.muted
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Repeater {
                        model: openerRow.modelData.lines

                        // One shortcut or menu entry: its keys as keycaps or its
                        // path, and a tag for a shortcut Hyprland does not have.
                        Flow {
                          id: openerLine
                          required property var modelData
                          width: openerText.width
                          spacing: Style.spacing.sm

                          Text {
                            visible: openerLine.modelData.none === true
                            height: root.tagHeight
                            verticalAlignment: Text.AlignVCenter
                            textFormat: Text.PlainText
                            text: openerRow.editable ? openerRow.modelData.add : "none"
                            color: openerRow.editable ? root.accent : root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                          }

                          Repeater {
                            model: openerLine.modelData.keys || []

                            Rectangle {
                              id: keyCap
                              required property string modelData
                              width: keyText.implicitWidth + Style.spacing.md * 2
                              height: root.tagHeight
                              radius: Style.spacing.xs
                              color: root.faint
                              border.width: 1
                              border.color: root.faint

                              Text {
                                id: keyText
                                anchors.centerIn: parent
                                textFormat: Text.PlainText
                                text: keyCap.modelData
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                              }
                            }
                          }

                          Repeater {
                            model: openerLine.modelData.path || []

                            Row {
                              id: pathStep
                              required property string modelData
                              required property int index
                              spacing: Style.spacing.sm

                              Text {
                                visible: pathStep.index > 0
                                height: root.tagHeight
                                verticalAlignment: Text.AlignVCenter
                                textFormat: Text.PlainText
                                text: "›"
                                color: root.muted
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                              }

                              Text {
                                height: root.tagHeight
                                verticalAlignment: Text.AlignVCenter
                                textFormat: Text.PlainText
                                text: pathStep.modelData
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                              }
                            }
                          }

                          Text {
                            visible: !!openerLine.modelData.note
                            height: root.tagHeight
                            verticalAlignment: Text.AlignVCenter
                            leftPadding: Style.spacing.xs
                            textFormat: Text.PlainText
                            text: openerLine.modelData.note || ""
                            color: root.muted
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                          }

                          // Set from the manager, in place of what the plugin set.
                          Pill {
                            visible: openerLine.modelData.override === true
                            text: "override"
                            tint: root.foreground
                            textColor: root.muted
                          }

                          Pill {
                            visible: openerLine.modelData.inactive === true
                            text: "not active"
                            tint: root.urgent
                          }
                        }
                      }
                    }

                    MouseArea {
                      id: openerMouse
                      anchors.fill: parent
                      enabled: openerRow.editable
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openerAction(openerRow.modelData.kind)
                    }
                  }
                }
              }

              Item {
                width: parent.width
                height: (root.sectionGap - detailsColumn.spacing) * 2 + 1
                visible: openersRepeater.count > 0

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width
                  height: 1
                  color: root.faint
                }
              }

              Repeater {
                id: factsRepeater
                model: root.facts(root.current)
                delegate: fieldDelegate
              }

              // Where it comes from: the repo, and where it sits on disk.
              // A section of its own: sectionGap from any facts above, just
              // the rule's gap when it follows the rule. The default top
              // padding is the glyph overshoot it reserves. Clicking it
              // unfolds the rest of the source, or folds it again.
              PanelSectionHeader {
                topPadding: Math.ceil(fontSize * 0.15)
                  + (factsRepeater.count > 0 ? root.sectionGap - detailsColumn.spacing : 0)
                text: "SOURCE  " + (root.sourceOpen ? "" : "")
                foreground: sourceToggle.containsMouse ? root.accent : root.foreground
                fontFamily: root.fontFamily

                MouseArea {
                  id: sourceToggle
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.sourceOpen = !root.sourceOpen
                }
              }

              Repeater {
                model: root.sourceFields(root.current, root.sourceOpen)
                delegate: fieldDelegate
              }
            }
          }

          // The actions under the details: the one that matters now stands
          // out (see primaryAction), the rest stay quiet beside it, and
          // Remove keeps apart on the left.
          Item {
            id: actions
            visible: root.current !== null
            anchors.left: divider.right
            anchors.leftMargin: root.contentMargin
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Math.max(removeButton.implicitHeight, actionFlow.implicitHeight)

            // Quiet like the rest: the confirmation is where it turns red.
            Button {
              id: removeButton
              visible: !root.currentIsSelf
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              foreground: root.muted
              fontFamily: root.fontFamily
              text: "Remove"
              tooltipText: "Uninstall the plugin  (d)"
              onClicked: root.askRemove()
            }

            // Right to left, so they sit against the right edge and wrap onto
            // a second row rather than run into Remove; the children are
            // listed last to first for that reason.
            Flow {
              id: actionFlow
              anchors.left: removeButton.visible ? removeButton.right : parent.left
              anchors.leftMargin: Style.spacing.xl
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              layoutDirection: Qt.RightToLeft
              spacing: Style.spacing.controlGap

              Button {
                visible: root.primary !== null
                bordered: true
                foreground: root.accent
                background: Util.alpha(root.accent, 0.12)
                fontFamily: root.fontFamily
                text: root.primary ? root.primary.text : ""
                tooltipText: root.primary ? root.primary.tip : ""
                onClicked: root.runPrimary(root.primaryKind)
              }

              Button {
                visible: root.current !== null && !root.currentIsSelf && !!root.current.openCommand
                  && root.primaryKind !== "open"
                foreground: root.current && root.current.enabled ? root.foreground : root.muted
                fontFamily: root.fontFamily
                text: "Open"
                tooltipText: "Close the manager and open this plugin  (⏎)"
                onClicked: root.openPlugin()
              }

              Button {
                visible: root.current !== null
                foreground: root.foreground
                fontFamily: root.fontFamily
                text: "Read"
                tooltipText: "Its files, what can run, and its README  (i)"
                onClicked: root.inspectCurrent()
              }

              Button {
                visible: root.current !== null && root.current.rollback !== null && root.current.rollback !== undefined
                foreground: root.foreground
                fontFamily: root.fontFamily
                text: "Roll back"
                tooltipText: "Go back to where it was before its last update  (b)"
                onClicked: root.askRollback()
              }

              Button {
                visible: !root.currentIsSelf && root.primaryKind !== "enable"
                foreground: root.foreground
                fontFamily: root.fontFamily
                text: root.current && root.current.enabled ? "Disable" : "Enable"
                tooltipText: "Switch the plugin on or off  (e)"
                onClicked: root.toggleEnabled()
              }            }
          }
        }

        // ---------------------------------------------------------- footer
        Item {
          id: footer
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          height: Math.max(root.footerHeight, footerActions.implicitHeight)

          // The width left of the line once Import… and Export have theirs.
          readonly property real free: width - (footerActions.x + footerActions.width) - Style.spacing.xl

          // Moving plugins between machines, at the very bottom: Import…
          // picks an export file, Export writes one to ~. Pulled out by the
          // buttons' padding, so their text meets the card's edge.
          Row {
            id: footerActions
            anchors.left: parent.left
            anchors.leftMargin: -Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xxs

            Button {
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: "Import…"
              tooltipText: "Pick an export file and choose which of its plugins to install  (I)"
              onClicked: root.pickImport()
            }

            Button {
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: "Export"
              tooltipText: "Write your plugins to a file in ~ for another Omarchy install  (x)"
              onClicked: root.exportPlugins()
            }
          }

          // The status comes next: the key hints make room for it.
          Text {
            id: statusText
            anchors.left: footerActions.right
            anchors.leftMargin: Style.spacing.xl
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, Math.min(implicitWidth, footer.free))
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.busy && root.activityLabel ? root.activityLabel + " …" : root.statusMessage
            color: root.busy ? root.accent : (root.statusError ? root.urgent : root.foreground)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // As many keys as the status leaves room for. Right to left and
          // clipped to one row, so whole hints drop off on the left; listed
          // last to first, the ones with buttons of their own in the header
          // (import, export, add) go first.
          Flow {
            id: hints
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, footer.free - (statusText.text ? statusText.implicitWidth + Style.spacing.xl : 0))
            height: statusText.implicitHeight
            clip: true
            layoutDirection: Qt.RightToLeft
            spacing: Style.spacing.lg

            Repeater {
              model: ["esc close", "⏎ open", "i read", "s shortcut", "m menu", "c check", "u update", "b roll back",
                      "e enable", "d remove", "o repo", "a add", "x export", "I import"]

              Text {
                required property string modelData
                textFormat: Text.PlainText
                text: modelData
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      // One dialog for the confirmations: removing the selected plugin, and
      // rolling it back.
      ConfirmDialog {
        id: confirm
        anchors.fill: parent
        opened: root.confirmingRemove || root.confirmingRollback
        background: root.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        cornerRadius: root.cornerRadius
        cancelText: "Cancel"
        confirmText: root.confirmingRollback ? "Roll back" : "Remove"
        message: {
          if (root.confirmingRollback) return root.rollbackMessage()
          var p = root.current
          if (!p) return ""
          return "Remove " + p.name + "? Its folder is deleted; the git repo stays upstream."
        }
        onCanceled: {
          root.confirmingRemove = false
          root.confirmingRollback = false
          keyCatcher.forceActiveFocus()
        }
        onConfirmed: {
          if (root.confirmingRollback) root.rollbackCurrent()
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

      // ------------------------------------------------------------- read
      // A plugin before it runs: what the shell loads it as, the files it
      // ships with the executable ones called out, and its README.
      Item {
        id: inspectDialog
        anchors.fill: parent
        visible: root.inspecting

        readonly property var info: root.inspection
        readonly property var plugin: root.inspecting ? root.inspectedPlugin() : null

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(root.background, 0.7)

          MouseArea {
            anchors.fill: parent
            onClicked: root.closeInspect()
          }
        }

        BorderSurface {
          id: inspectCard
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
            anchors.topMargin: inspectCard.contentTopInset
            anchors.rightMargin: inspectCard.contentRightInset
            anchors.bottomMargin: inspectCard.contentBottomInset
            anchors.leftMargin: inspectCard.contentLeftInset

            Text {
              id: inspectTitle
              anchors { left: parent.left; right: parent.right; top: parent.top }
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: inspectDialog.info ? inspectDialog.info.name : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              id: inspectSummary
              anchors { left: parent.left; right: parent.right; top: inspectTitle.bottom; topMargin: Style.spacing.md }
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              text: {
                var i = inspectDialog.info
                if (!i) return ""
                var parts = [(i.kinds || []).join(", ") || "no kinds",
                             i.files.length + (i.files.length === 1 ? " file" : " files"),
                             root.sizeText(i.size)]
                if (i.keepLoaded) parts.push("stays loaded")
                var text = parts.join("  ·  ")
                var p = inspectDialog.plugin
                if (p && !p.enabled && !p.self)
                  text += "\nIt is disabled. Plugins run unsandboxed inside the shell, so read it before you switch it on."
                return text
              }
            }

            Text {
              id: inspectRunnable
              anchors { left: parent.left; right: parent.right; top: inspectSummary.bottom; topMargin: Style.spacing.md }
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              readonly property var runnable: inspectDialog.info ? inspectDialog.info.executables : []
              text: runnable.length === 0
                ? "No executable files: it runs only as QML inside the shell."
                : "⚠ Can run outside the shell: " + runnable.join(", ")
              color: runnable.length === 0 ? root.muted : root.urgent
            }

            Flickable {
              id: inspectView
              anchors {
                left: parent.left; right: parent.right
                top: inspectRunnable.bottom; topMargin: Style.spacing.lg
                bottom: inspectFooter.top; bottomMargin: Style.spacing.md
              }
              clip: true
              contentWidth: width
              contentHeight: inspectColumn.implicitHeight
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: inspectColumn
                width: inspectView.width
                spacing: Style.spacing.xxs

                Repeater {
                  model: inspectDialog.info ? inspectDialog.info.files : []

                  Row {
                    id: inspectFile
                    required property var modelData
                    spacing: Style.spacing.lg

                    Text {
                      width: Style.space(64)
                      horizontalAlignment: Text.AlignRight
                      textFormat: Text.PlainText
                      text: root.sizeText(inspectFile.modelData.size)
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      width: inspectColumn.width - Style.space(64) - Style.spacing.lg
                      elide: Text.ElideMiddle
                      textFormat: Text.PlainText
                      text: inspectFile.modelData.path + (inspectFile.modelData.executable ? "   (executable)" : "")
                      color: inspectFile.modelData.executable ? root.urgent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                Item {
                  width: parent.width
                  height: Style.spacing.lg
                }

                Rectangle {
                  width: parent.width
                  height: 1
                  color: root.faint
                }

                Item {
                  width: parent.width
                  height: Style.spacing.lg
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: inspectDialog.info && inspectDialog.info.readme ? Text.MarkdownText : Text.PlainText
                  text: inspectDialog.info && inspectDialog.info.readme
                    ? root.readmeText(inspectDialog.info.readme)
                    : "It has no README."
                  color: inspectDialog.info && inspectDialog.info.readme ? root.foreground : root.muted
                  linkColor: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            Item {
              id: inspectFooter
              anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
              height: inspectButtons.implicitHeight

              Text {
                anchors.left: parent.left
                anchors.right: inspectButtons.left
                anchors.rightMargin: Style.spacing.xl
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: "↑↓ PgUp PgDn scroll   f open folder   e enable   esc close"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Row {
                id: inspectButtons
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.controlGap

                Button {
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  text: "Open folder"
                  tooltipText: "Read the code in the file manager; the manager closes  (f)"
                  onClicked: root.openFolder(inspectDialog.info ? inspectDialog.info.path : "")
                }

                Button {
                  visible: inspectDialog.plugin !== null && !inspectDialog.plugin.enabled && !inspectDialog.plugin.self
                  bordered: true
                  foreground: root.accent
                  fontFamily: root.fontFamily
                  text: "Enable"
                  onClicked: root.enableInspected()
                }

                Button {
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  text: "Close"
                  onClicked: root.closeInspect()
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
              elide: Text.ElideMiddle
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
              // A shortcut set outside the manager is not its to move: saving
              // adds another next to it.
              readonly property var own: root.binding ? root.managedShortcut(root.current) : null
              readonly property var other: root.binding && root.current && root.current.opens
                && root.current.opens.shortcuts.length ? root.current.opens.shortcuts[0] : null
              visible: text !== ""
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: own ? "Now: " + own.keys
                          + (own.addedBy === "plugin" ? ", set by the plugin itself" : ", set here earlier")
                          + ". Saving moves it."
                : other ? "Now: " + other.keys + ", set outside the manager. Saving adds this one; that one stays."
                : ""
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Free combinations to pick from, beside typing one.
            Flow {
              width: parent.width
              visible: root.showSuggestions
              spacing: Style.spacing.sm

              Text {
                visible: root.keySuggestions.length === 0
                textFormat: Text.PlainText
                text: keyProc.running && root.keyMode !== "check" ? "Looking …"
                  : "None of the usual combinations is free; type one"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: root.keySuggestions

                Button {
                  required property string modelData
                  bordered: true
                  selected: bindField.text.trim() === modelData
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.md
                  verticalPadding: Style.spacing.xxs
                  text: modelData
                  onClicked: root.pickSuggestion(modelData)
                }
              }
            }

            Item {
              width: parent.width
              height: bindButtons.implicitHeight

              Button {
                anchors.left: parent.left
                bordered: true
                active: root.showSuggestions
                foreground: root.foreground
                fontFamily: root.fontFamily
                text: "Suggestions"
                tooltipText: "Free combinations made from the plugin's name"
                onClicked: root.toggleSuggestions()
              }

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

      // ------------------------------------------------------------ import
      // The plugins in the export file picked to import: those it can install
      // ticked, the rest greyed out with the reason, and Import for the ticked.
      Item {
        id: importDialog
        anchors.fill: parent
        visible: root.importPreview !== null

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(root.background, 0.7)

          MouseArea {
            anchors.fill: parent
            onClicked: root.cancelImport()
          }
        }

        BorderSurface {
          id: importCard
          width: Math.min(parent.width - Style.space(32), Style.space(560))
          height: importCard.contentTopInset + importCard.contentBottomInset + importColumn.implicitHeight
          anchors.centerIn: parent
          color: root.background
          borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
          padding: Style.space(18)
          radius: root.cornerRadius

          MouseArea {
            anchors.fill: parent
            onClicked: keyCatcher.forceActiveFocus()
          }

          Column {
            id: importColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: importCard.contentTopInset
            anchors.leftMargin: importCard.contentLeftInset
            anchors.rightMargin: importCard.contentRightInset
            spacing: Style.spacing.lg

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: "Import plugins"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            // Where the file came from, and the file itself on one line,
            // however deep it sits.
            Column {
              width: parent.width
              spacing: Style.spacing.xxs

              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: {
                  var p = root.importPreview
                  if (!p) return ""
                  return "From " + (p.host || "another machine") + (p.exportedAt ? ", exported " + root.ago(p.exportedAt) : "")
                }
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                width: parent.width
                elide: Text.ElideMiddle
                textFormat: Text.PlainText
                text: root.importPreview ? root.homePath(root.importPreview.path) : ""
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // With nothing in the file to install, say so; Close is all that
            // is left to do.
            Text {
              width: parent.width
              visible: root.importInstallable === 0
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.importAllHere ? "Everything in this file is already installed."
                                       : "Nothing in this file can be installed here."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            // Scrolls once there are more than fit.
            ListView {
              id: importList
              width: parent.width
              height: Math.min(contentHeight, Style.space(300))
              clip: true
              interactive: contentHeight > height
              boundsBehavior: Flickable.StopAtBounds
              spacing: Style.spacing.xxs
              model: root.importPlan

              delegate: Rectangle {
                id: importRow
                required property var modelData
                required property int index
                readonly property bool installable: importRow.modelData.action === "install"
                readonly property bool ticked: importRow.installable && root.importChosen[importRow.modelData.id] === true
                readonly property bool cursor: importRow.installable && importRow.index === root.importCursor
                readonly property bool installed: importRow.modelData.reason === "already installed"

                width: importList.width
                height: root.rowHeight
                radius: root.cornerRadius
                color: importRow.cursor ? root.selectedBackground : "transparent"

                // The tick box: filled when the plugin will be imported, and
                // a greyed-out tick when it is already installed.
                Rectangle {
                  id: tickBox
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.rowPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.round(Style.font.body * 1.25)
                  height: width
                  radius: Style.spacing.xs
                  opacity: importRow.installable ? 1 : (importRow.installed ? 0.6 : 0.35)
                  color: importRow.ticked ? root.accent : (importRow.installed ? Util.alpha(root.foreground, 0.15) : "transparent")
                  border.width: 1
                  border.color: importRow.ticked ? root.accent : root.muted

                  Text {
                    anchors.centerIn: parent
                    visible: importRow.ticked || importRow.installed
                    textFormat: Text.PlainText
                    text: "✓"
                    color: importRow.ticked ? root.background : root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Column {
                  anchors.left: tickBox.right
                  anchors.leftMargin: Style.spacing.xl
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.spacing.xxs

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: importRow.modelData.name
                    color: !importRow.installable ? root.muted : (importRow.cursor ? root.selectedText : root.foreground)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: !importRow.installable ? importRow.modelData.reason
                      : importRow.modelData.enabled
                        ? "switched on" + (importRow.modelData.where ? " " + importRow.modelData.where : "")
                        : "added switched off"
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  enabled: importRow.installable
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.importCursor = importRow.index
                  onClicked: root.toggleImport(importRow.index)
                }
              }
            }

            // What the export itself left out, and why.
            Text {
              width: parent.width
              visible: text !== ""
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: {
                var left = root.importPreview && root.importPreview.skippedAtExport ? root.importPreview.skippedAtExport : []
                return left.length === 0 ? ""
                  : "Not in the file: " + left.map(function(s) { return s.name + " (" + s.reason + ")" }).join(", ")
              }
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item {
              width: parent.width
              height: importButtons.implicitHeight

              Text {
                anchors.left: parent.left
                anchors.right: importButtons.left
                anchors.rightMargin: Style.spacing.xl
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.importInstallable > 0 ? "↑↓ choose   space tick   ⏎ import   esc cancel" : "⏎ or esc close"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Row {
                id: importButtons
                anchors.right: parent.right
                spacing: Style.spacing.controlGap

                Button {
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  text: root.importInstallable > 0 ? "Cancel" : "Close"
                  onClicked: root.cancelImport()
                }

                Button {
                  visible: root.importInstallable > 0
                  bordered: true
                  foreground: root.importPicked.length > 0 ? root.accent : root.muted
                  fontFamily: root.fontFamily
                  text: "Import (" + root.importPicked.length + ")"
                  onClicked: root.importChosenPlugins()
                }
              }
            }
          }
        }
      }

      // -------------------------------------------------------------- menu
      // An entry for the plugin in the Omarchy menu: where it goes, what it
      // says, and a preview of where it will show.
      Item {
        id: menuDialog
        anchors.fill: parent
        visible: root.menuing

        readonly property var own: root.menuing ? root.managedMenu(root.current) : null

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(root.background, 0.7)

          MouseArea {
            anchors.fill: parent
            onClicked: root.closeMenu()
          }
        }

        BorderSurface {
          id: menuCard
          width: Math.min(parent.width - Style.space(32), Style.space(560))
          height: menuCard.contentTopInset + menuCard.contentBottomInset + menuColumn.implicitHeight
          anchors.centerIn: parent
          color: root.background
          borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
          padding: Style.space(18)
          radius: root.cornerRadius

          MouseArea {
            anchors.fill: parent
            onClicked: menuLabel.forceActiveFocus()
          }

          Column {
            id: menuColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: menuCard.contentTopInset
            anchors.leftMargin: menuCard.contentLeftInset
            anchors.rightMargin: menuCard.contentRightInset
            spacing: Style.spacing.lg

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.current ? "Menu entry for " + root.current.name : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              elide: Text.ElideMiddle
              textFormat: Text.PlainText
              text: root.current ? "Runs: " + root.current.openCommand : ""
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm

              Text {
                textFormat: Text.PlainText
                text: "Where"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Flow {
                width: parent.width
                spacing: Style.spacing.controlGap

                Repeater {
                  model: root.menuPlaces

                  Button {
                    required property var modelData
                    bordered: true
                    selected: root.menuParent === modelData.key
                    foreground: selected ? root.accent : root.foreground
                    fontFamily: root.fontFamily
                    text: modelData.label
                    onClicked: root.menuParent = modelData.key
                  }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.spacing.lg

              Column {
                width: parent.width - menuIconColumn.width - Style.spacing.lg
                spacing: Style.spacing.sm

                Text {
                  textFormat: Text.PlainText
                  text: "Label"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: menuLabel
                  width: parent.width
                  foreground: root.foreground
                  placeholderText: "The name in the menu"
                  Keys.onPressed: function(event) { root.menuKey(event) }
                }
              }

              Column {
                id: menuIconColumn
                width: Style.space(72)
                spacing: Style.spacing.sm

                Text {
                  textFormat: Text.PlainText
                  text: "Icon"
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  id: menuIcon
                  width: parent.width
                  foreground: root.foreground
                  horizontalAlignment: TextInput.AlignHCenter
                  Keys.onPressed: function(event) { root.menuKey(event) }
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm

              Text {
                textFormat: Text.PlainText
                text: "Description, shown under the label and searched"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: menuDescription
                width: parent.width
                foreground: root.foreground
                placeholderText: "Optional"
                Keys.onPressed: function(event) { root.menuKey(event) }
              }
            }

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: "Shows as: " + root.menuPreview()
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              width: parent.width
              // An entry written outside the manager is not its to move:
              // saving adds another next to it.
              readonly property var other: root.menuing && root.current && root.current.opens
                && root.current.opens.menu.length ? root.current.opens.menu[0] : null
              visible: text !== ""
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: menuDialog.own
                ? "Now: " + menuDialog.own.path
                  + (menuDialog.own.addedBy === "plugin" ? ", added by the plugin itself" : ", added here earlier")
                  + ". Saving moves it."
                : other ? "Now: " + other.path + ", added outside the manager. Saving adds this one; that one stays."
                : ""
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item {
              width: parent.width
              height: menuButtons.implicitHeight

              Row {
                id: menuButtons
                anchors.right: parent.right
                spacing: Style.spacing.controlGap

                Button {
                  visible: menuDialog.own !== null
                  bordered: true
                  foreground: root.urgent
                  fontFamily: root.fontFamily
                  text: "Remove entry"
                  onClicked: root.removeMenu()
                }

                Button {
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  text: "Cancel"
                  onClicked: root.closeMenu()
                }

                Button {
                  bordered: true
                  foreground: root.accent
                  fontFamily: root.fontFamily
                  text: "Save"
                  onClicked: root.saveMenu()
                }
              }
            }
          }
        }
      }
    }
  }
}
