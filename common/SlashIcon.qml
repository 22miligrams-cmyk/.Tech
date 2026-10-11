import QtQuick
import QtQuick.Shapes
import QtQuick.Effects

// SlashIcon.qml - иконка, нарисованная кодом, с анимированным перечёркиванием (вынесена из ControlCenter.qml).
// иконка, нарисованная кодом (без svg), с анимированным перечёркиванием: микрофон и колокольчик.
// kind: "mic" | "bell" | "bluetooth" | "speaker" (динамик: при slashed вместо черты рисуется крестик, волны стираются; число видимых волн задаёт waves). slashed меняется -> диагональный фронт (слева-сверху вправо-вниз):
// за ним тело с вырезами под черту, перед ним целое тело. Черта растёт ровно на фронте.
// У динамика готового контура "с вырезами" нет (off пустой): вырез под черту делается маской - за фронтом тело
// показывается везде, кроме полосы вокруг диагонали, так что черта растёт/стирается сверху вниз ровно на фронте.
// Координаты - как в svg 24x24 (контуры взяты из micOff.svg / notificationsOff.svg)
Item {
    id: si
    property string kind: "mic"
    property real size: 24
    property color color: "white"
    property bool slashed: false
    property int duration: 350
    property int waves: 99           // динамик: сколько волн видно (0..2); лишние стираются сверху вниз, недостающие растут снизу вверх
    property real slashWidth: 2      // толщина черты (единицы 24x24), одинаковая у всех

    readonly property var defs: ({
        mic: {
            sw: 2,
            on:  "M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z M19 10v2a7 7 0 0 1-14 0v-2 M12 19v3",
            off: "M18.89 13.23A7.12 7.12 0 0 0 19 12v-2 M5 10v2a7 7 0 0 0 12 5 M15 9.34V5a3 3 0 0 0-5.68-1.33 M9 9v3a3 3 0 0 0 5.12 2.12 M12 19v3"
        },
        bluetooth: {
            sw: 2,
            on:  "M7 7l10 10-5 5V2l5 5L7 17",
            off: "M17 17l-5 5V12l-5 5 M14.5 9.5L17 7l-5-5v4.5"
        },
        speaker: {
            sw: 1.7,
            cross: true,     // вместо перечёркивания - крестик справа от корпуса (как volumeMute.svg), рисуется двумя штрихами
            on:  "M4 9.5v5h3.5l4.5 4v-13l-4.5 4z",
            off: "",
            // волны (от ближней к дальней): путь и вертикальный размах (единицы 24x24) для стирания сверху вниз
            waves: [
                { path: "M15.5 9.2a4 4 0 0 1 0 5.6", y0: 9.2, y1: 14.8 },
                { path: "M18.2 6.8a8 8 0 0 1 0 10.4", y0: 6.8, y1: 17.2 }
            ]
        },
        bell: {
            sw: 1.7,
            on:  "M6 16v-4.8a6 6 0 0 1 12 0V16l1.6 2.3H4.4Z M10 21h4",
            off: "M18 16v-4.8a6 6 0 0 0-8.6-5.4 M6.2 9.2a6 6 0 0 0-.2 2V16l-1.6 2.3h11.4 M10 21h4"
        }
    })
    readonly property var d: defs[kind] !== undefined ? defs[kind] : defs.mic
    readonly property real k: size / 24
    readonly property bool cross: d.cross === true    // динамик: крестик вместо диагональной черты
    readonly property bool cut: !cross && d.off === ""     // нет готового контура с вырезами: вырез делаем маской
    readonly property real gapPx: (slashWidth / 2 + 1.6) * k * 1.41421356   // полуширина выреза вдоль диагонали, px

    // динамик: при выключении волны стираются сверху вниз, пока рисуется крестик, при включении - наоборот
    readonly property int wavesEff: slashed ? 0 : waves

    property real progress: slashed ? 1 : 0
    Behavior on progress { NumberAnimation { duration: si.duration; easing.type: Easing.InOutCubic } }

    width: size
    height: size

    // целое тело (источник для MultiEffect, сам не рисуется)
    GlyphLayer {
        id: onSrc
        width: si.size; height: si.size
        visible: false
        GlyphShape { svgPath: si.d.on; sw: si.d.sw; strokeCol: si.color; unit: si.k }

        // волны динамика: каждая показана окном, верхняя граница которого едет вниз (стирание) или вверх (появление)
        Repeater {
            model: si.d.waves !== undefined ? si.d.waves : []

            Item {
                id: wv
                required property int index
                required property var modelData
                property real reveal: index < si.wavesEff ? 1 : 0
                Behavior on reveal { NumberAnimation { duration: 300; easing.type: Easing.InOutCubic } }

                readonly property real top0: (modelData.y0 - 1.5) * si.k
                readonly property real bot: (modelData.y1 + 1.5) * si.k

                x: 0
                y: top0 + (1 - reveal) * (bot - top0)
                width: si.size
                height: si.size - y
                clip: true     // visible не переключаем: показ/скрытие элемента внутри слоя-источника ломало повторное появление

                GlyphShape { y: -wv.y; svgPath: wv.modelData.path; sw: si.d.sw; strokeCol: si.color; unit: si.k }
            }
        }
    }

    // тело с вырезами под черту
    GlyphLayer {
        id: offSrc
        width: si.size; height: si.size
        visible: false
        GlyphShape { svgPath: si.d.off; sw: si.d.sw; strokeCol: si.color; unit: si.k }
    }

    // маска-шторка: полуплоскость x + y < t, граница под 45° едет вдоль диагонали
    GlyphLayer {
        id: wipeSrc
        width: si.size; height: si.size
        visible: false

        Rectangle {
            id: wipeRect
            readonly property real t: -2 + si.progress * (si.size * 2 + 4)
            width: si.size * 2
            height: si.size * 3
            x: t / 2 - width
            y: t / 2 - height / 2
            transformOrigin: Item.Right
            rotation: 45
            antialiasing: true
            color: "black"
        }
    }

    // маска для тела с вырезом: за фронтом (x + y < t) всё, кроме полосы вокруг диагонали (|x - y| < gapPx).
    // Это два клина, каждый - прямоугольник, повёрнутый на 45° углом в точку фронта
    GlyphLayer {
        id: cutSrc
        width: si.size; height: si.size
        visible: false
        layer.enabled: si.cut

        Item {
            x: (wipeRect.t + si.gapPx) / 2
            y: (wipeRect.t - si.gapPx) / 2
            rotation: 45
            Rectangle { x: -si.size * 3; y: -si.size * 3; width: si.size * 3; height: si.size * 3; antialiasing: true; color: "black" }
        }
        Item {
            x: (wipeRect.t - si.gapPx) / 2
            y: (wipeRect.t + si.gapPx) / 2
            rotation: 45
            Rectangle { x: -si.size * 3; y: 0; width: si.size * 3; height: si.size * 3; antialiasing: true; color: "black" }
        }
    }

    // перед фронтом - целое тело
    MultiEffect {
        anchors.fill: parent
        visible: !si.cross
        source: onSrc
        maskEnabled: true
        maskSource: wipeSrc
        maskInverted: true
    }

    // динамик: тело с волнами как есть, без маски
    MultiEffect {
        anchors.fill: parent
        visible: si.cross
        source: onSrc
    }

    // за фронтом - тело с вырезами (готовый контур) или целое тело, обрезанное маской выреза
    MultiEffect {
        anchors.fill: parent
        visible: !si.cross
        source: si.cut ? onSrc : offSrc
        maskEnabled: true
        maskSource: si.cut ? cutSrc : wipeSrc
    }

    // черта (2,2) -> (22,22), голова на фронте шторки.
    // Скрытый источник + MultiEffect, как и остальные куски: иначе вложенный видимый слой
    // не рисуется, пока родитель (glyphNormal/glyphDark) скрыт во время удержания
    GlyphLayer {
        id: lineSrc
        width: si.size; height: si.size
        visible: false

        Shape {
            width: 24
            height: 24
            scale: si.k
            transformOrigin: Item.TopLeft

            ShapePath {
                id: ln
                readonly property real head: Math.max(2, Math.min(22, wipeRect.t / (2 * si.k)))
                fillColor: "transparent"
                strokeColor: head > 2.02 ? si.color : "transparent"
                strokeWidth: si.slashWidth
                capStyle: ShapePath.RoundCap
                startX: 2
                startY: 2
                PathLine { x: ln.head; y: ln.head }
            }
        }
    }

    MultiEffect {
        anchors.fill: parent
        visible: !si.cross
        source: lineSrc
    }

    // крестик динамика (16,9.5)-(21,14.5) и (21,9.5)-(16,14.5): штрихи рисуются по очереди, обратно стираются в обратном порядке
    GlyphLayer {
        id: crossSrc
        width: si.size; height: si.size
        visible: false

        Shape {
            width: 24
            height: 24
            scale: si.k
            transformOrigin: Item.TopLeft

            ShapePath {
                id: xa
                readonly property real p: Math.max(0, Math.min(1, si.progress * 1.6))
                fillColor: "transparent"
                strokeColor: p > 0.01 ? si.color : "transparent"
                strokeWidth: si.d.sw
                capStyle: ShapePath.RoundCap
                startX: 16
                startY: 9.5
                PathLine { x: 16 + 5 * xa.p; y: 9.5 + 5 * xa.p }
            }

            ShapePath {
                id: xb
                readonly property real p: Math.max(0, Math.min(1, (si.progress - 0.375) * 1.6))
                fillColor: "transparent"
                strokeColor: p > 0.01 ? si.color : "transparent"
                strokeWidth: si.d.sw
                capStyle: ShapePath.RoundCap
                startX: 21
                startY: 9.5
                PathLine { x: 21 - 5 * xb.p; y: 9.5 + 5 * xb.p }
            }
        }
    }

    MultiEffect {
        anchors.fill: parent
        visible: si.cross
        source: crossSrc
    }

    // слой-источник для MultiEffect: рисуется в текстуру 2x со сглаживанием
    component GlyphLayer: Item {
        layer.enabled: true
        layer.smooth: true
        layer.samples: 4
        layer.textureSize: Qt.size(width * 2, height * 2)
    }

    // векторный контур (одна или несколько подпутей SVG-пути в системе координат 24x24), только обводка
    component GlyphShape: Shape {
        id: gs
        property string svgPath: ""
        property color strokeCol: "white"
        property real sw: 2
        property real unit: 1            // во сколько раз растянуть 24x24 до реального размера
        width: 24
        height: 24
        scale: unit
        transformOrigin: Item.TopLeft

        ShapePath {
            fillColor: "transparent"
            strokeColor: gs.strokeCol
            strokeWidth: gs.sw
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: gs.svgPath }
        }
    }
}
