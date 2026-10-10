// CcIconTile.qml
//
// Зачем это: квадратная плитка только с иконкой - для ряда переключателей и ряда
// действий (замок, сон, перезагрузка, выключение) в центре управления.
// Стиль тот же, что у CcTile: без рамки, скругление 6, включённая подсвечивается акцентом.
// armed - режим "точно?": плитка красится в красный (для опасных действий вроде выключения).
// Логики тут нет: клик отдаёт clicked().

import QtQuick

Rectangle {
    id: tile

    property string glyph: ""
    property bool active: false
    property bool usable: true
    property bool armed: false
    property color colAccent: "#a3cef1"
    property color colText: "#e0e1dd"
    property color colDanger: "#f38ba8"
    property real iconSize: 16
    // базовая прозрачность фона неактивной плитки (внутри CcCard ставим повыше, чтобы плитки читались)
    property real baseAlpha: 0.06

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"

    signal clicked()

    height: 44
    radius: 6
    opacity: usable ? 1.0 : 0.4
    color: armed ? Qt.alpha(colDanger, 0.28)
         : active ? Qt.alpha(colAccent, ma.containsMouse && usable ? 0.24 : 0.16)
                  : Qt.alpha(colText, ma.containsMouse && usable ? baseAlpha + 0.05 : baseAlpha)

    Behavior on color { ColorAnimation { duration: 150 } }
    Behavior on opacity { NumberAnimation { duration: 150 } }

    SequentialAnimation {
        id: pulse
        NumberAnimation { target: tile; property: "scale"; to: 0.94; duration: 70; easing.type: Easing.OutQuad }
        NumberAnimation { target: tile; property: "scale"; to: 1; duration: 200; easing.type: Easing.OutBack; easing.overshoot: 2.5 }
    }

    Text {
        anchors.centerIn: parent
        text: tile.glyph
        color: tile.armed ? tile.colDanger : tile.active ? tile.colAccent : Qt.alpha(tile.colText, 0.8)
        font.pixelSize: tile.iconSize
        font.family: tile.fontFamily

        Behavior on color { ColorAnimation { duration: 150 } }
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
