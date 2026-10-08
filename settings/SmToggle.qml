// Маленький тумблер вкл/выкл для карточек. Состояние берёт снаружи через active, ничего не хранит.
import QtQuick

Item {
    id: root
    property bool active: false
    required property string colBg
    required property string colAccent
    required property string colSecondary

    width: 48
    height: 24

    Rectangle {
        anchors.fill: parent
        radius: 6
        color: root.active ? root.colAccent : root.colBg

        Behavior on color { ColorAnimation { duration: 200 } }

        Rectangle {
            id: thumb
            width: 20
            height: 18
            radius: 3
            y: 3
            x: root.active ? parent.width - width - 3 : 3
            color: root.active ? root.colBg : root.colSecondary

            Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 200 } }
        }
    }
}
