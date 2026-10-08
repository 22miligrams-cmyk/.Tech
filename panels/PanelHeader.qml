import QtQuick
import QtQuick.Layouts
import "../icons"

// шапка для панелей (уведомления, буфер, Bluetooth) в стиле SmHeader из настроек:
// сплошная плашка colSecondary, radius 14, акцентный бейдж с иконкой, крупный жирный заголовок.
// кнопки справа добавляются дочерними элементами (у каждой Layout.preferredHeight: 60, radius: 14):
//   PanelHeader { iconName: "clipboard"; title: "..."; badge: "5"; Rectangle { ... } }
RowLayout {
    id: root

    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary

    property string fontFamily: "JetBrainsMono Nerd Font, Monospace"
    property string title: ""
    property string iconName: ""
    property real iconDim: 1.0
    property string badge: ""          // счётчик рядом с заголовком, пусто = не показывать

    default property alias actions: actionsRow.data

    Layout.alignment: Qt.AlignHCenter
    spacing: 12

    Rectangle {
        Layout.preferredHeight: 60
        Layout.preferredWidth: plateRow.implicitWidth + 36
        radius: 14
        color: Qt.alpha(root.colSecondary, 0.9)

        Behavior on Layout.preferredWidth { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        RowLayout {
            id: plateRow
            anchors.centerIn: parent
            spacing: 14

            Rectangle {
                Layout.preferredWidth: 40
                Layout.preferredHeight: 40
                radius: 10
                color: root.colAccent

                Icon {
                    anchors.centerIn: parent
                    name: root.iconName
                    size: 22
                    color: root.colBg
                    dim: root.iconDim
                }
            }


            Text {
                text: root.title
                color: root.colText
                font.bold: true
                font.pixelSize: 20
                font.family: root.fontFamily
            }

            Text {
                visible: root.badge !== ""
                text: root.badge
                color: root.colAccent
                font.bold: true
                font.pixelSize: 20
                font.family: root.fontFamily
            }
        }
    }

    RowLayout {
        id: actionsRow
        spacing: 12
    }
}
