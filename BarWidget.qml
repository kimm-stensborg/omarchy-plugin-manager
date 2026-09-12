import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// A bar button that opens the Plugin Manager and counts the plugins with an
// update waiting. The count comes from the cache bin/plugin-manager keeps, so
// the manager and every bar (one per monitor) always agree; a check runs at
// startup and every six hours, and the backend's lock makes the widgets on
// other monitors wait for it and then read the same result.
BarWidget {
  id: root
  moduleName: "io.github.kimm-stensborg.plugin-manager"

  // Injected for third-party entry points that declare them.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.kimm-stensborg.plugin-manager"
  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: root.manifest && root.manifest.__sourceDir
    ? String(root.manifest.__sourceDir)
    : root.home + "/.config/omarchy/plugins/" + root.pluginId
  readonly property string cachePath: (Quickshell.env("XDG_CACHE_HOME") || root.home + "/.cache")
    + "/omarchy/plugin-manager/updates.json"
  readonly property int staleSeconds: 6 * 3600

  property var pending: []
  readonly property int updateCount: root.pending.length

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The backend rewrites the cache in place, so a read can land between the
  // truncate and the write. Such a read is skipped rather than taken for "no
  // updates"; the write that completes it fires the watcher again.
  function readCache(content) {
    var cache = null
    try { cache = JSON.parse(String(content || "")) } catch (e) { return }
    if (!cache || typeof cache !== "object") return
    var names = []
    var entries = cache.plugins || ({})
    for (var id in entries) {
      var entry = entries[id]
      if (entry && entry.checkable && !entry.error && entry.behind > 0) names.push(id.split(".").pop())
    }
    root.pending = names
  }

  function openManager() {
    if (root.shell && typeof root.shell.toggle === "function") root.shell.toggle(root.pluginId, "{}")
    else if (root.bar) root.bar.run("omarchy-shell shell toggle " + root.pluginId + " '{}'")
  }

  FileView {
    id: cacheFile
    path: root.cachePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readCache(text())
    onLoadFailed: root.pending = []
  }

  Process {
    id: checkProc
    command: [root.pluginDir + "/bin/plugin-manager", "check", "--if-stale", String(root.staleSeconds)]
    // The cache may not have existed for the watcher to watch until now.
    onExited: cacheFile.reload()
  }

  Timer {
    interval: root.staleSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!checkProc.running) checkProc.running = true
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐱"
    tooltipText: root.updateCount === 0
      ? "Plugins"
      : "Plugins: " + (root.updateCount === 1 ? "1 update" : root.updateCount + " updates")
        + " (" + root.pending.join(", ") + ")"
    onPressed: root.openManager()
  }

  Rectangle {
    visible: root.updateCount > 0
    anchors.right: button.right
    anchors.top: button.top
    anchors.rightMargin: Style.space(1)
    anchors.topMargin: Style.space(2)
    width: Math.max(height, badgeText.implicitWidth + Style.space(4))
    height: badgeText.implicitHeight
    radius: height / 2
    color: Color.accent

    Text {
      id: badgeText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: root.updateCount > 9 ? "9+" : String(root.updateCount)
      color: Color.background
      font.family: Style.font.family
      font.pixelSize: Math.max(7, Style.font.caption - 2)
      font.bold: true
    }
  }
}
