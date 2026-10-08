// EditorZone.qml
//
// Зачем это: одна из трёх зон (left / center / right) в редакторе раскладки бара.
// Рисует подложку, заголовок зоны с значком выравнивания, подсвечивается когда
// над ней тащат плашку, а если в зоне пусто - показывает заглушку "+".
// Справа ещё рисуется иконка настроек: в настоящем баре она всегда на месте.

import QtQuick
import "../panels"
import "../notifications"
import "../settings"
import "../common"
import "../lang"

Item {
    id: zoneRoot

    // host - это BarEditor, оттуда берём цвета, размеры и состояние перетаскивания
    required property var host
    required property string zone

    // над этой зоной сейчас тащат плашку / вообще что-то тащат
    readonly property bool hovered: host.hoverZone === zone
    readonly property bool dragging: host.dragChip !== null

    // пустая ли зона (выключенные блоки не считаем).
    // r = rev нужен только чтобы биндинг пересчитывался при смене раскладки
    readonly property bool empty: {
        const r = host.barLayout.rev
        const m = host.barLayout.model(zone)
        for (let i = 0; i < m.count; i++)
            if (host.isOn(m.get(i).blockId)) return false
        return true
    }

    // подложка зоны: при наведении чуть разрастается и светлеет
    Rectangle {
        id: bg
        anchors.fill: parent

        anchors.margins: zoneRoot.hovered ? -2 : 0
        radius: 14

        color: zoneRoot.hovered ? Qt.alpha(zoneRoot.host.colAccent, 0.22)
             : Qt.alpha(zoneRoot.host.colBg, zoneRoot.dragging ? 0.55 : 0.4)

        Behavior on anchors.margins { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 150 } }
    }

    // шапка зоны: три полоски (как выравнивание текста) + название
    Row {
        id: head
        y: 6
        spacing: 6
        layoutDirection: zoneRoot.zone === "right" ? Qt.RightToLeft : Qt.LeftToRight
        x: zoneRoot.zone === "left" ? 12
         : (zoneRoot.zone === "right" ? zoneRoot.width - width - 12
                                      : (zoneRoot.width - width) / 2)
        opacity: zoneRoot.hovered ? 1.0 : (zoneRoot.dragging ? 0.8 : 0.55)

        Behavior on opacity { NumberAnimation { duration: 140 } }

        // значок из трёх полосок, прижат к стороне зоны
        Item {
            id: glyph
            width: 12;  height: 10
            anchors.verticalCenter: parent.verticalCenter

            Repeater {
                model: [12, 7, 10]

                delegate: Rectangle {
                    required property int modelData
                    required property int index

                    width: modelData
                    height: 2
                    radius: 1
                    y: index*4
                    x: zoneRoot.zone === "left" ? 0
                     : (zoneRoot.zone === "right" ? glyph.width - width : (glyph.width - width) / 2)
                    color: zoneRoot.hovered ? zoneRoot.host.colAccent : zoneRoot.host.colText

                    Behavior on color { ColorAnimation { duration: 150 } }
                }
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Tr.tr("zone." + zoneRoot.zone)
            color: zoneRoot.hovered ? zoneRoot.host.colAccent : zoneRoot.host.colText
            font.pixelSize: 11
            font.bold: true
            font.family: zoneRoot.host.fontFamily

            Behavior on color { ColorAnimation { duration: 150 } }
        }
    }

    // заглушка "+" когда в зоне ничего нет
    Rectangle {
        id: slot

        readonly property real areaW: zoneRoot.width - 16 - (zoneRoot.zone === "right" ? 36 : 0)
        readonly property real fullW: 22 + 8 + 40 + 28

        opacity: zoneRoot.empty && !zoneRoot.hovered ? (zoneRoot.dragging ? 1.0 : 0.8) : 0.0
        visible: opacity > 0.01
        width: Math.min(areaW, fullW)
        height: zoneRoot.host.chipH
        x: 8 + (areaW - width) / 2
        y: zoneRoot.host.chipY
        radius: 10

        color: Qt.alpha(zoneRoot.host.colSecondary, zoneRoot.dragging ? 0.45 : 0.3)

        Behavior on opacity { NumberAnimation { duration: 140 } }
        Behavior on color { ColorAnimation { duration: 150 } }

        Row {
            anchors.centerIn: parent
            spacing: 8

            Rectangle {
                width: 22;  height: 22
                radius: 6
                anchors.verticalCenter: parent.verticalCenter
                color: Qt.alpha(zoneRoot.host.colBg, 0.6)

                Text {
                    anchors.centerIn: parent
                    text: "+"
                    color: zoneRoot.host.colAccent
                    font.pixelSize: 14
                    font.bold: true
                    font.family: zoneRoot.host.fontFamily
                }
            }
        }
    }

    // место под иконку настроек справа
    Rectangle {
        visible: zoneRoot.zone === "right"
        width: 30;  height: 30
        radius: 10
        anchors.right: parent.right
        anchors.rightMargin: 8
        y: zoneRoot.host.chipY + 1
        color: Qt.alpha(zoneRoot.host.colSecondary, 0.6)

        Text {
            anchors.centerIn: parent
            text: zoneRoot.host.settingsIcon
            color: zoneRoot.host.colAccent
            opacity: 0.8
            font.pixelSize: 13
            font.family: zoneRoot.host.fontFamily
        }
    }
}
