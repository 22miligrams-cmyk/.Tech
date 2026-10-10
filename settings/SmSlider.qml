// Простой слайдер для карточек: подпись со значением сверху и дорожка с ползунком.
// Сам значение не хранит, только просит изменить его через valueRequested.
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root
    property string label: ""
    property real value: 0
    property real labelOpacity: 1.0
    required property string colBg
    required property string colAccent
    required property string colText

    signal activated()
    signal valueRequested(real v)

    spacing: 8

    Text {
        Layout.alignment: Qt.AlignHCenter
        text: root.label
        color: root.colAccent
        opacity: root.labelOpacity
        font.pixelSize: 16
        font.bold: true
        font.family: "JetBrainsMono Nerd Font, Monospace"
    }

    Item {
        id: track
        Layout.alignment: Qt.AlignHCenter
        Layout.preferredWidth: 150
        Layout.preferredHeight: 24

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 6
            radius: 3
            color: root.colBg

            Rectangle {
                width: parent.width * root.value
                height: parent.height
                radius: 3
                color: root.colAccent
            }
        }

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 14
            height: 18
            radius: 4
            x: (track.width - width) * root.value
            color: root.colText
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            // не даём карусели (ListView) перехватить жест как свайп, пока тянем ползунок
            preventStealing: true

            // переводит позицию мыши в значение 0..1 (с учётом половины ширины ползунка по краям)
            function setFrom(mx) { root.valueRequested((mx - 7) / (width - 14)) }

            onPressed: (mouse) => { root.activated(); setFrom(mouse.x) }
            onPositionChanged: (mouse) => { if (pressed) setFrom(mouse.x) }
        }
    }
}
