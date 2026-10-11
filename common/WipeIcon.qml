import QtQuick
import QtQuick.Effects
import "../icons"

// WipeIcon.qml - переход между двумя иконками (nameA -> nameB) диагональной шторкой, как перечёркивание в SlashIcon:
// фронт идёт от левого верхнего угла к правому нижнему, перед ним одна иконка, за ним другая.
// Нужен для динамика: flipped=false - обычная иконка громкости, flipped=true - перечёркнутая (volumeMute);
// при включении звука черта стирается тем же фронтом, сверху вниз.
Item {
    id: wi

    property string nameA: ""            // показывается при flipped = false
    property string nameB: ""            // показывается при flipped = true
    property bool flipped: false
    property real size: 15
    property color color: "white"
    property real dim: 1.3
    property int duration: 350

    property real progress: flipped ? 1 : 0
    Behavior on progress { NumberAnimation { duration: wi.duration; easing.type: Easing.InOutCubic } }

    width: size
    height: size

    // слой-источник для MultiEffect: рисуется в текстуру 2x со сглаживанием
    component GlyphLayer: Item {
        layer.enabled: true
        layer.smooth: true
        layer.samples: 4
        layer.textureSize: Qt.size(width * 2, height * 2)
    }

    GlyphLayer {
        id: srcA
        width: wi.size; height: wi.size
        visible: false
        Icon { anchors.centerIn: parent; name: wi.nameA; size: wi.size; color: wi.color; dim: wi.dim }
    }

    GlyphLayer {
        id: srcB
        width: wi.size; height: wi.size
        visible: false
        Icon { anchors.centerIn: parent; name: wi.nameB; size: wi.size; color: wi.color; dim: wi.dim }
    }

    // маска-шторка: полуплоскость x + y < t, граница под 45° едет вдоль диагонали (как в SlashIcon)
    GlyphLayer {
        id: wipeSrc
        width: wi.size; height: wi.size
        visible: false

        Rectangle {
            readonly property real t: -2 + wi.progress * (wi.size * 2 + 4)
            width: wi.size * 2
            height: wi.size * 3
            x: t / 2 - width
            y: t / 2 - height / 2
            transformOrigin: Item.Right
            rotation: 45
            antialiasing: true
            color: "black"
        }
    }

    // перед фронтом - иконка A
    MultiEffect {
        anchors.fill: parent
        source: srcA
        maskEnabled: true
        maskSource: wipeSrc
        maskInverted: true
    }

    // за фронтом - иконка B
    MultiEffect {
        anchors.fill: parent
        source: srcB
        maskEnabled: true
        maskSource: wipeSrc
    }
}
