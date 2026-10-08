// Шапка меню: в хабе просто «⚙ Настройки», внутри раздела ещё кнопка «назад»
// и хлебная крошка «Настройки › Название раздела».
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property var menu
    readonly property string colBg: menu.colBg
    readonly property string colAccent: menu.colAccent
    readonly property string colText: menu.colText
    readonly property string colSecondary: menu.colSecondary
    readonly property bool inSection: menu.view === "section"
    readonly property string font: "JetBrainsMono Nerd Font, Monospace"
    spacing: 0

    RowLayout {
        Layout.alignment: Qt.AlignHCenter
        Layout.preferredHeight: 60
        spacing: 12

        Item {
            Layout.preferredHeight: 60
            Layout.preferredWidth: root.inSection ? 60 : 0
            opacity: root.inSection ? 1 : 0
            clip: true
            Behavior on Layout.preferredWidth { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 180 } }

            Rectangle {
                width: 60; height: 60
                radius: 14
                color: backArea.containsMouse ? colAccent : Qt.alpha(colSecondary, 0.9)
                Behavior on color { ColorAnimation { duration: 150 } }

                Text {
                    anchors.centerIn: parent
                    text: "󰁍"
                    font.pixelSize: 28
                    font.family: root.font
                    color: backArea.containsMouse ? colBg : colText
                    Behavior on color { ColorAnimation { duration: 150 } }
                }
            }

            MouseArea {
                id: backArea
                anchors.fill: parent
                enabled: root.inSection
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: menu.goHub()
            }
        }

        Rectangle {
            Layout.preferredHeight: 60
            Layout.preferredWidth: plateRow.implicitWidth + 36
            radius: 14
            color: Qt.alpha(colSecondary, 0.9)
            Behavior on Layout.preferredWidth { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

            RowLayout {
                id: plateRow
                anchors.centerIn: parent
                spacing: 14

                Rectangle {
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    radius: 10
                    color: colAccent

                    Text {
                        anchors.centerIn: parent
                        text: "󰒓"
                        color: colBg
                        font.pixelSize: 24
                        font.family: root.font
                    }
                }

                Text {
                    text: menu.tr("title.hub")
                    font.bold: true
                    font.pixelSize: 20
                    font.family: root.font
                    color: colText
                    opacity: root.inSection ? (hubArea.containsMouse ? 0.9 : 0.5) : 1.0
                    Behavior on opacity { NumberAnimation { duration: 150 } }

                    MouseArea {
                        id: hubArea
                        anchors.fill: parent
                        enabled: root.inSection
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: menu.goHub()
                    }
                }

                Text {
                    visible: root.inSection
                    text: "›"
                    font.bold: true
                    font.pixelSize: 20
                    font.family: root.font
                    color: colText
                    opacity: 0.35
                }

                Text {
                    visible: root.inSection
                    text: menu.tr("title." + menu.tab)
                    font.bold: true
                    font.pixelSize: 20
                    font.family: root.font
                    color: colAccent
                }
            }
        }
    }
}
