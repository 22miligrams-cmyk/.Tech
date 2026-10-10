// CcTile.qml
//
// Зачем это: одна плитка-переключатель в центре управления (Wi-Fi, Bluetooth, не беспокоить, микрофон).
// Стиль как у чипов в MprisPanel: без рамки, скругление 6, включённая подсвечивается акцентом.
// Иконка-глиф слева, название и подпись состояния справа.
// Логики тут нет: клик просто отдаёт clicked(), что делать - решает ControlCenter.qml.

import QtQuick

Rectangle {
    id: tile

    // что рисуем
    property string glyph: ""
    property string title: ""
    property string sub: ""
    property bool active: false
    property bool usable: true

    // цвета приходят снаружи, из темы шелла
    property color colAccent: "#a3cef1"
    property color colText: "#e0e1dd"

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"

    signal clicked()

    height: 46
    radius: 6
    opacity: usable ? 1.0 : 0.4
    color: active ? Qt.alpha(colAccent, ma.containsMouse && usable ? 0.24 : 0.16)
                  : Qt.alpha(colText, ma.containsMouse && usable ? 0.11 : 0.06)

    Behavior on color { ColorAnimation { duration: 150 } }
    Behavior on opacity { NumberAnimation { duration: 150 } }

    // нажатие: плитка чуть сжимается и пружинит обратно
    SequentialAnimation {
        id: pulse
        NumberAnimation { target: tile; property: "scale"; to: 0.96; duration: 70; easing.type: Easing.OutQuad }
        NumberAnimation { target: tile; property: "scale"; to: 1; duration: 200; easing.type: Easing.OutBack; easing.overshoot: 2.5 }
    }

    Row {
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.right: parent.right
        anchors.rightMargin: 8
        spacing: 10

        Text {
            width: 20
            horizontalAlignment: Text.AlignHCenter
            anchors.verticalCenter: parent.verticalCenter
            text: tile.glyph
            color: tile.active ? tile.colAccent : Qt.alpha(tile.colText, 0.8)
            font.pixelSize: 16
            font.family: tile.fontFamily

            Behavior on color { ColorAnimation { duration: 150 } }
        }

        Column {
            width: parent.width - 30
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Text {
                width: parent.width
                text: tile.title
                color: tile.active ? tile.colAccent : tile.colText
                font.pixelSize: 11
                font.bold: true
                font.family: tile.fontFamily
                elide: Text.ElideRight

                Behavior on color { ColorAnimation { duration: 150 } }
            }

            Text {
                width: parent.width
                text: tile.sub
                color: Qt.alpha(tile.colText, 0.5)
                font.pixelSize: 10
                font.family: tile.fontFamily
                elide: Text.ElideRight
            }
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        enabled: tile.usable
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            pulse.restart()
            tile.clicked()
        }
    }
}
