// icons/Icon.qml
//
// Зачем это: маленький компонент для иконок. Кладёшь рядом svg-шки, пишешь
// Icon { name: "play" } и получаешь иконку нужного цвета. Нужен чтобы не
// рисовать каждую иконку отдельным Image и не красить их вручную в каждом
// месте - цвет берётся из темы шелла и меняется на лету.
//
// Как юзать:
//   Icon { name: "play"; color: root.colAccent; size: 18 }
// name - это имя svg-файла из этой же папки, без ".svg"
// dim  - затемнение: 1.0 = цвет как есть, больше = темнее (для неактивных)

import QtQuick
import QtQuick.Effects


Item {
    id: root

    // имя svg без расширения, пустое - значит ничего не рисуем
    property string name: ""
    property color color: "white"
    property real size: 24
    property real dim: 1.0

    implicitWidth: size;  implicitHeight: size


    // сама картинка, но её не показываем: она нужна только как маска для
    // MultiEffect ниже, который её перекрашивает. sourceSize x2 чтобы не мылилось
    Image {
        id: img
        anchors.fill: parent
        visible: false
        source: root.name !== "" ? Qt.resolvedUrl(root.name + ".svg") : ""
        sourceSize: Qt.size(Math.ceil(root.width * 2), Math.ceil(root.height * 2))
        fillMode: Image.PreserveAspectFit
        smooth: true;  mipmap: true
    }

    // красит иконку в один цвет: brightness+colorization на максимум, и
    // svg становится просто силуэтом нужного цвета. Если dim != 1 - темним
    MultiEffect {
        anchors.fill: img
        source: img
        brightness: 1.0
        colorization:1.0
        colorizationColor: root.dim === 1.0 ? root.color : Qt.darker(root.color, root.dim)
    }
}
