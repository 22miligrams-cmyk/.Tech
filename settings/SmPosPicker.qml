// Мини-схема экрана для выбора стороны бара: рисунок монитора и четыре стрелки по краям.
// Клик по стрелке кидает сигнал picked(side) с top/left/right/bottom.
import QtQuick

Item {
    id: posBlock
    property string pos: "top"
    readonly property bool vert: pos === "left" || pos === "right"
    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary

    signal picked(string side)

    Rectangle {
        id: scr
        width: 100
        height: 64
        anchors.centerIn: parent
        radius: 6
        color: Qt.alpha(colBg, 0.95)

        Rectangle {
            width: 46
            height: 28
            radius: 3
            color: Qt.alpha(colSecondary, 0.45)
            x: (scr.width - width) / 2 + (posBlock.pos === "left" ? 7 : (posBlock.pos === "right" ? -7 : 0))
            y: (scr.height - height) / 2 + (posBlock.pos === "top" ? 7 : (posBlock.pos === "bottom" ? -7 : 0))

            Behavior on x { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
            Behavior on y { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
        }

        Rectangle {
            id: miniBar
            radius: 3
            color: colAccent
            x: posBlock.pos === "right" ? scr.width - 13 : 5
            y: posBlock.pos === "bottom" ? scr.height - 13 : 5
            width: posBlock.vert ? 8 : scr.width - 10
            height: posBlock.vert ? scr.height - 10 : 8

            Behavior on x { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
            Behavior on y { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
            Behavior on width { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
        }
    }

    Repeater {
        model: [
            { side: "top", cp: 0xF0143 },
            { side: "left", cp: 0xF0141 },
            { side: "right", cp: 0xF0142 },
            { side: "bottom", cp: 0xF0140 }
        ]

        delegate: Rectangle {
            id: arrow
            required property var modelData
            readonly property bool sel: posBlock.pos === modelData.side

            width: 24
            height: 24
            radius: 6
            x: modelData.side === "left" ? 0 : (modelData.side === "right" ? posBlock.width - width : (posBlock.width - width) / 2)
            y: modelData.side === "top" ? 0 : (modelData.side === "bottom" ? posBlock.height - height : (posBlock.height - height) / 2)
            color: sel ? colAccent : Qt.alpha(colBg, arrowArea.containsMouse ? 0.95 : 0.6)
            scale: arrowArea.pressed ? 0.9 : (arrowArea.containsMouse ? 1.15 : 1.0)

            Behavior on color { ColorAnimation { duration: 200 } }
            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

            Text {
                anchors.centerIn: parent
                text: String.fromCodePoint(arrow.modelData.cp)
                color: arrow.sel ? colBg : colText
                opacity: arrow.sel ? 1.0 : 0.7
                font.pixelSize: 14

                Behavior on color { ColorAnimation { duration: 200 } }
            }

            MouseArea {
                id: arrowArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: posBlock.picked(arrow.modelData.side)
            }
        }
    }
}
