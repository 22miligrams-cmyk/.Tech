// BarChip.qml
//
// Зачем это: одна "таблетка" в баре (воркспейсы, громкость, батарея и т.д.).
// Показывает иконку (svg или глиф из шрифта) и подпись, умеет значок-счётчик
// в углу и текст с анимацией смены (например название трека). Если shown=false -
// плавно схлопывается в ноль и гаснет. По клику отдаёт сигнал clicked().

import QtQuick
import "../panels"
import "../notifications"
import "../settings"
import "../common"
import "../icons"

Rectangle {
    id: chip

    // цвета приходят снаружи, из темы шелла
    required property string colAccent
    required property string colText

    // фон плашки (стекло) и второй цвет - им красится бейдж
    property color glass: "transparent"
    property color colSecondary: "#313244"
    // что рисуем: svg-иконка (в приоритете) или глиф из шрифта + текст
    property string svg: ""
    property string glyph: ""
    property string label: ""
    // капшн - текст с анимацией смены, ширину задаём снаружи (0 = капшна нет)
    property real captionWidth: 0
    property string caption: ""
    property bool animateCaption: true
    // shown=false - плашка схлопывается и пропадает
    property bool shown: true;  property bool animateColor: true

    // клик по плашке
    signal clicked()

    // режимы: бейдж (svg + число в углу) и капшн
    readonly property bool badgeMode: svg !== ""
    readonly property bool captionMode: captionWidth > 0

    // ширина в развёрнутом виде, от неё анимируем схлопывание
    readonly property real expandedWidth: captionMode ? 20 + 17 + 6 + captionWidth
                                         : (badgeMode ? 30 : Math.max(30, row.implicitWidth + 20))

    height: 30
    width: shown ? expandedWidth : 0
    opacity: shown ? 1.0 : 0.0
    visible: opacity > 0
    radius: 6
    clip: !shown || width < expandedWidth - 0.5
    color: glass

    // плавные переходы цвета, ширины и прозрачности
    Behavior on color { enabled: chip.animateColor; ColorAnimation { duration: 300 } }
    Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutExpo } }
    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    // основной ряд: иконка, капшн, глиф, лейбл (показывается то, что нужно режиму)
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Icon {
            visible: chip.svg !== ""
            name: chip.svg
            size: 17
            color: chip.colAccent
            dim: 1.3
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
        }

        Item {
            id: capBox
            visible: chip.captionMode
            width: chip.captionWidth
            height: capText.implicitHeight
            clip: true
            anchors.verticalCenter: parent.verticalCenter

            property string shownText: chip.caption

            Text {
                id: capText
                width: parent.width
                text: capBox.shownText
                elide: Text.ElideRight
                color: chip.colText
                font.pixelSize: 11
                font.bold: true
                font.family: "JetBrainsMono Nerd Font, Monospace"

                Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
            }

            // смена текста капшна: старый уезжает вверх и гаснет, новый выезжает снизу
            SequentialAnimation {
                id: capAnim

                ParallelAnimation {
                    NumberAnimation { target: capText; property: "opacity"; to: 0; duration: 110; easing.type: Easing.InQuad }
                    NumberAnimation { target: capText; property: "y"; to: -capBox.height * 0.5; duration: 110; easing.type: Easing.InQuad }
                }

                ScriptAction {
                    script: {
                        capBox.shownText = chip.caption
                        capText.y = capBox.height * 0.6
                    }
                }

                ParallelAnimation {
                    NumberAnimation { target: capText; property: "opacity"; to: 1; duration: 320; easing.type: Easing.OutCubic }
                    NumberAnimation { target: capText; property: "y"; to: 0; duration: 320; easing.type: Easing.OutCubic }
                }
            }

            // когда caption поменялся: анимируем если можно, иначе просто подменяем текст
            Connections {
                target: chip

                function onCaptionChanged() {
                    if (chip.animateCaption && chip.shown && capBox.visible) {
                        capAnim.restart()
                    } else {
                        capAnim.stop()
                        capText.opacity = 1
                        capText.y = 0
                        capBox.shownText = chip.caption
                    }
                }
            }
        }

        Text {
            visible: chip.svg === ""
            text: chip.glyph
            color: chip.colAccent
            font.pixelSize: 14
            font.family: "JetBrainsMono Nerd Font, Monospace"
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
        }

        Text {
            visible: chip.label !== "" && !chip.badgeMode
            text: chip.label
            color: chip.colText
            font.pixelSize: 11
            font.bold: true
            font.family: "JetBrainsMono Nerd Font, Monospace"
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
        }
    }

    // бейдж-счётчик в правом верхнем углу, больше 9 показываем как "9+"
    Rectangle {
        id: badge
        width: Math.max(14, badgeText.implicitWidth+6)
        height: 14
        radius: 7
        color: chip.colSecondary
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: -3;  anchors.topMargin: -3

        scale: chip.badgeMode && chip.label !== "" ? 1 : 0
        visible: scale > 0

        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
        Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }

        Text {
            id: badgeText
            anchors.centerIn: parent
            text: { const n = parseInt(chip.label); return (!isNaN(n) && n > 9) ? "9+" : chip.label }
            color: chip.colAccent
            font.pixelSize: 9
            font.bold: true
            font.family: "JetBrainsMono Nerd Font, Monospace"
        }
    }

    // клик + лёгкая подсветка при наведении
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: chip.clicked()

        Rectangle {
            anchors.fill: parent
            radius: chip.radius
            color: Qt.alpha(chip.colText, ma.containsMouse ? 0.12 : 0.0)

            Behavior on color { ColorAnimation { duration: 150 } }
        }
    }
}
