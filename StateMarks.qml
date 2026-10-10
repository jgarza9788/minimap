import QtQuick
import QtQuick.Shapes

// Tiny window-state marks drawn inside a box, no font needed:
//   pinned      a dot in the top-right corner
//   fullscreen  four corner brackets
//   floating    a dashed outline just inside the edge
// Hidden when the box is too small to carry them.
Item {
  id: marks

  property bool pinned: false
  property bool fullscreen: false
  property bool floating: false
  property color ink: "#000000"

  anchors.fill: parent
  readonly property bool roomy: width >= 10 && height >= 10
  readonly property real m: 2                                  // margin from the edge
  readonly property real arm: Math.max(2, Math.min(4, Math.min(width, height) / 3))

  // floating: dashed outline
  Shape {
    anchors.fill: parent
    visible: marks.roomy && marks.floating && !marks.fullscreen
    opacity: 0.8
    ShapePath {
      strokeColor: marks.ink
      strokeWidth: 1
      fillColor: "transparent"
      strokeStyle: ShapePath.DashLine
      dashPattern: [2, 2]
      startX: marks.m + 0.5
      startY: marks.m + 0.5
      PathLine { x: marks.width - marks.m - 0.5; y: marks.m + 0.5 }
      PathLine { x: marks.width - marks.m - 0.5; y: marks.height - marks.m - 0.5 }
      PathLine { x: marks.m + 0.5; y: marks.height - marks.m - 0.5 }
      PathLine { x: marks.m + 0.5; y: marks.m + 0.5 }
    }
  }

  // fullscreen: corner brackets (0 TL, 1 TR, 2 BL, 3 BR)
  Repeater {
    model: marks.roomy && marks.fullscreen ? 4 : 0

    Item {
      required property int index
      readonly property bool atRight: index === 1 || index === 3
      readonly property bool atBottom: index === 2 || index === 3
      Rectangle {   // horizontal arm
        x: parent.atRight ? marks.width - marks.m - marks.arm : marks.m
        y: parent.atBottom ? marks.height - marks.m - 1.2 : marks.m
        width: marks.arm
        height: 1.2
        color: marks.ink
        opacity: 0.9
      }
      Rectangle {   // vertical arm
        x: parent.atRight ? marks.width - marks.m - 1.2 : marks.m
        y: parent.atBottom ? marks.height - marks.m - marks.arm : marks.m
        width: 1.2
        height: marks.arm
        color: marks.ink
        opacity: 0.9
      }
    }
  }

  // pinned: dot
  Rectangle {
    visible: marks.roomy && marks.pinned
    x: marks.width - marks.m - 4
    y: marks.m + (marks.fullscreen ? 3 : 0)
    width: 4
    height: 4
    radius: 2
    color: marks.ink
    opacity: 0.95
  }
}
