// Кнопка-шестерёнка для бара. Сама ничего не открывает, только кидает сигнал clicked(),
// а при наведении слегка подсвечивается.
import QtQuick
import "../bar"
import "../panels"
import "../notifications"
import "../common"

Rectangle {
    id: settingsBtn
    width: 30; height: 30
    implicitWidth: 30
    implicitHeight: 30
    radius: 6
    color: glass

    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary

    property color glass: colBg
    property bool animateColor: true

    signal clicked()

    Behavior on color { enabled: settingsBtn.animateColor; ColorAnimation { duration: 300 } }

    Text {
        anchors.centerIn: parent
        text: "󰒓"
        color: colAccent
        font.pixelSize: 14
        font.family: "JetBrainsMono Nerd Font, Monospace"
        Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: settingsBtn.clicked()

        Rectangle {
            anchors.fill: parent
            radius: settingsBtn.radius
            color: Qt.alpha(settingsBtn.colText, ma.containsMouse ? 0.12 : 0.0)
            Behavior on color { ColorAnimation { duration: 150 } }
        }
    }
}
