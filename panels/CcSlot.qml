// CcSlot.qml
//
// Зачем это: ячейка для ряда плиток, которая плавно появляется и исчезает.
// Когда shown меняется (например выдернули bluetooth-свисток), ячейка за ~280мс
// сужается до нуля и гаснет, а соседи плавно занимают освободившееся место.
// Ширину, когда ячейка показана, ряд задаёт сам через full (ширина ряда / число плиток).
// gap - зазор между плитками: он внутри ячейки (по gap/2 с каждой стороны),
// поэтому у схлопнувшейся ячейки не остаётся лишнего отступа.
// Плитку кладём внутрь и растягиваем: CcSlot { CcIconTile { anchors.fill: parent } }.
// Пока ячейка скрыта, клики в неё не попадают.

import QtQuick

Item {
    id: slot

    property bool shown: true
    property real full: 0
    property real gap: 6

    default property alias content: holder.data

    width: shown ? full : 0
    height: 44
    opacity: shown ? 1 : 0
    visible: width > 0.5
    enabled: shown

    Behavior on width { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
    Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

    Item {
        id: holder
        x: slot.gap / 2
        width: Math.max(0, slot.width - slot.gap)
        height: parent.height
    }
}
