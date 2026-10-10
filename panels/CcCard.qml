// CcCard.qml
//
// Зачем это: карточка-секция для центра управления. Каждый блок (ползунки, переключатели,
// уведомления, действия, батарея) лежит в своей карточке с тонкой рамкой, чтобы сразу
// было видно, где блок начинается и где заканчивается.
// Содержимое кладётся прямо внутрь: CcCard { Row { ... } }. Дети лежат в body с отступом inset.
// Высота по умолчанию = высота содержимого + отступы (можно задать height снаружи).

import QtQuick

Rectangle {
    id: card

    property real cr: 6
    property real inset: 10
    property color colText: "#e0e1dd"

    default property alias content: body.data

    implicitHeight: body.childrenRect.height + inset * 2
    radius: cr
    color: Qt.alpha(colText, 0.05)
    border.width: 1
    border.color: Qt.alpha(colText, 0.10)

    Item {
        id: body
        anchors.fill: parent
        anchors.margins: card.inset
    }
}
