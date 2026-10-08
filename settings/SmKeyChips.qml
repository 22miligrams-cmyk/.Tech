// Ряд «кнопок клавиатуры» для показа комбинации (Super + Shift + D). Последняя клавиша
// выделена акцентом. Если ряд шире карточки, он сжимается.
import QtQuick

Item {
    id: root
    property var keys: []
    required property string colBg
    required property string colAccent
    required property string colText

    Row {
        id: keyRow
        anchors.centerIn: parent
        spacing: 4
        scale: width > 0 ? Math.min(1, parent.width / width) : 1

        Repeater {
            model: root.keys

            Rectangle {
                required property string modelData
                required property int index
                readonly property bool isLast: index === root.keys.length - 1

                height: 22
                width: keyText.implicitWidth + 14
                radius: 5
                color: isLast ? root.colAccent : root.colBg

                Text {
                    id: keyText
                    anchors.centerIn: parent
                    text: parent.modelData
                    color: parent.isLast ? root.colBg : root.colText
                    font.pixelSize: 11
                    font.bold: true
                    font.family: "JetBrainsMono Nerd Font, Monospace"
                }
            }
        }
    }
}
