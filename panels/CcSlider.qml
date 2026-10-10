// CcSlider.qml
//
// Зачем это: ползунок для центра управления (громкость, яркость), нарисован так же,
// как регулятор громкости в MprisPanel: заливка и остаток дорожки разделены просветом,
// вместо кружка - вертикальная палочка, проценты справа.
// Слева иконка-глиф (по клику отдаёт glyphClicked(), например для mute).
// Сам значение не хранит: показывает value (0..1), а когда тянут - шлёт moved(v).
// Колёсиком мыши меняет значение шагом 5%.

import QtQuick

Item {
    id: sl

    property string glyph: ""
    property real value: 0
    // приглушить (например когда звук выключен)
    property bool dimmed: false
    property bool usable: true
    property real radius: 6

    property color colAccent: "#a3cef1"
    property color colText: "#e0e1dd"

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"
    readonly property bool hot: usable && (dragMa.containsMouse || dragMa.pressed)

    signal moved(real v)
    signal glyphClicked()

    height: 22
    opacity: !usable ? 0.4 : (dimmed ? 0.5 : 1.0)
    Behavior on opacity { NumberAnimation { duration: 150 } }

    // иконка слева
    Rectangle {
        id: ico
        width: 24
        height: 22
        radius: sl.radius
        color: Qt.alpha(sl.colText, icoMa.containsMouse && sl.usable ? 0.12 : 0.0)

        Behavior on color { ColorAnimation { duration: 150 } }

        Text {
            anchors.centerIn: parent
            text: sl.glyph
            color: sl.colAccent
            font.pixelSize: 15
            font.family: sl.fontFamily
        }

        MouseArea {
            id: icoMa
            anchors.fill: parent
            hoverEnabled: true
            enabled: sl.usable
            cursorShape: Qt.PointingHandCursor
            onClicked: sl.glyphClicked()
        }
    }

    // проценты справа
    Text {
        id: pct
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: 32
        horizontalAlignment: Text.AlignRight
        text: Math.round(sl.value * 100) + "%"
        color: sl.hot ? sl.colAccent : Qt.alpha(sl.colText, 0.6)
        font.pixelSize: 10
        font.bold: true
        font.family: sl.fontFamily

        Behavior on color { ColorAnimation { duration: 140 } }
    }

    // дорожка
    Item {
        id: track
        anchors.left: ico.right
        anchors.leftMargin: 6
        anchors.right: pct.left
        anchors.rightMargin: 6
        height: parent.height

        property real thick: sl.hot ? 5 : 4
        readonly property real gap: 6
        property real vf: Math.max(0, Math.min(1, sl.value))
        readonly property real cx: Math.max(2, Math.min(width - 2, vf * width))

        Behavior on vf {
            enabled: !dragMa.pressed
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
        Behavior on thick { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        // заполненная часть
        Rectangle {
            x: 0
            y: (parent.height - height) / 2
            width: Math.max(0, track.cx - track.gap)
            height: track.thick
            radius: height / 2
            color: sl.colAccent
            visible: width > 0.5
        }

        // остаток
        Rectangle {
            x: track.cx + track.gap
            y: (parent.height - height) / 2
            width: Math.max(0, track.width - x)
            height: track.thick
            radius: height / 2
            color: Qt.alpha(sl.colText, 0.2)
            visible: width > 0.5
        }

        // палочка-ручка
        Rectangle {
            width: dragMa.pressed ? 2.5 : 4
            height: sl.hot ? 20 : 16
            radius: width / 2
            color: sl.colAccent
            x: track.cx - width / 2
            y: (parent.height - height) / 2

            Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        }

        MouseArea {
            id: dragMa
            anchors.fill: parent
            hoverEnabled: true
            enabled: sl.usable
            cursorShape: Qt.PointingHandCursor

            function emitAt(px) { sl.moved(Math.max(0, Math.min(1, px / width))) }

            onPressed: (m) => emitAt(m.x)
            onPositionChanged: (m) => { if (pressed) emitAt(m.x) }
            onWheel: (w) => {
                sl.moved(Math.max(0, Math.min(1, sl.value + (w.angleDelta.y > 0 ? 0.05 : -0.05))))
                w.accepted = true
            }
        }
    }
}
