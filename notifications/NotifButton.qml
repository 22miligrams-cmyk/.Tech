// NotifButton.qml
//
// Кнопка колокольчика в баре — открывает центр уведомлений.
// Что тут есть:
//   - иконка (колокольчик, а при включённом DND — «dnd»)
//   - бейдж с числом непрочитанных в правом верхнем углу (больше 9 -> "9+")
//   - подсветка при наведении
// Сама логика открытия тут не живёт: кнопка только кидает сигнал clicked(),
// а что с ним делать — решает тот, кто её вставил (Visual.qml / бар).
// Своих функций нет, всё на биндингах.
import QtQuick
import "../bar"
import "../panels"
import "../settings"
import "../common"
import "../icons"


Rectangle {
    id: notifBtn

    width: 30
    height: 30
    implicitWidth: 30;  implicitHeight: 30
    radius: 6
    color: glass

    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary

    // Фон кнопки (полупрозрачный), по умолчанию такой же как colBg
    property color glass: colBg

    // Сколько непрочитанных (для бейджа)
    property int count: 0

    // Режим "Не беспокоить" — от него зависит иконка
    property bool dnd: false

    // false — цвет меняется сразу, без анимации (нужно чтобы цельный бар анимировался синхронно)
    property bool animateColor: true

    signal clicked()

    Behavior on color { enabled: notifBtn.animateColor; ColorAnimation { duration: 300 } }


    // сама иконка
    Icon {
        anchors.centerIn: parent
        name: notifBtn.dnd ? "dnd" : "notifications"
        size: 16
        color: colAccent

        Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
    }


    // Бейдж с числом. Когда есть непрочитанные — выпрыгивает с "пружинкой" (OutBack),
    // когда нет — схлопывается в ноль и прячется
    Rectangle {
        id: badge

        width: Math.max(14, badgeText.implicitWidth + 6)
        height: 14
        radius: 7
        color: notifBtn.colAccent

        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: -4
        anchors.topMargin: -3

        scale: notifBtn.count > 0 ? 1 : 0
        visible: scale > 0

        Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack } }
        Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }

        Text {
            id: badgeText
            anchors.centerIn: parent
            text: notifBtn.count > 9 ? "9+" : String(notifBtn.count)
            color: notifBtn.colBg
            font.pixelSize: 9;  font.bold: true
            font.family: "JetBrainsMono Nerd Font, Monospace"
        }
    }


    // Клик + подсветка при наведении (лёгкая белёсая заливка поверх кнопки)
    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: notifBtn.clicked()

        Rectangle {
            anchors.fill: parent
            radius: notifBtn.radius
            color: Qt.alpha(notifBtn.colText, ma.containsMouse ? 0.12 : 0.0)

            Behavior on color { ColorAnimation { duration: 150 } }
        }
    }
}
