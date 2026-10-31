import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Runs one pane provider (providers/<providerId>.py) and keeps its latest layouts. If it dies it
// comes back after 2 s, doubling to 30 s, instead of leaving that app's panes silently gone.
QtObject {
  id: watch
  required property string providerId
  required property string scriptPath
  property var layouts: []

  // Ask for a fresh read (labels the app sends no event for); see providers/README.md.
  function refresh() { if (proc.running) proc.write("refresh\n") }

  property bool run: true
  property int backoff: 2000

  property Timer restart: Timer {
    onTriggered: watch.run = true
  }

  property Process proc: Process {
    running: watch.run
    stdinEnabled: true
    command: ["python3", "-I", watch.scriptPath]
    onExited: {
      watch.layouts = []
      console.warn("jgarza.minimap: " + watch.providerId + " provider exited, restarting in " + watch.backoff + " ms")
      watch.run = false
      watch.restart.interval = watch.backoff
      watch.restart.restart()
      watch.backoff = Math.min(30000, watch.backoff * 2)
    }
    stdout: SplitParser {
      onRead: function (line) {
        var list = Model.parsePaneLayouts(line, watch.providerId)
        if (!list) return
        watch.backoff = 2000
        watch.layouts = list
      }
    }
  }
}
