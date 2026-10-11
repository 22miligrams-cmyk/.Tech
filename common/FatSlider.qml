import QtQuick
import QtQuick.Effects

// FatSlider.qml - толстая полоска-ползунок с водой: без кругляшка, прямоугольник со скруглением radius,
// проценты (или label) по центру. Заливка - WaterEffect (../assets/WaterFill.frag.qsb), повёрнутый на 90°,
// так что вода "поднимается" слева направо.
//
// Нужен рядом: WaterEffect.qml (эта же папка). Шейдер лежит в ../assets.
// Если glyph задан, левые glyphZone px - кнопка (клик = glyphClicked), но потянуть ползунок можно и оттуда.
// vertical: true - вертикальная полоска (вода снизу вверх, без поворота), глиф-зоны нет (так сделан эквалайзер).
Item {
    id: fs

    property string glyph: ""
    // вместо текстового глифа - иконка кодом (SlashIcon) с анимацией перечёркивания: "mic" | "speaker" | ...
    property string iconKind: ""
    property int iconWaves: 99           // у динамика: сколько волн видно (лишние стираются сверху вниз)
    property bool iconSlashed: false
    property string label: ""            // текст по центру; пусто = проценты
    property real value: 0               // 0..1
    property bool dimmed: false          // приглушённая заливка (например, звук выключен)
    property bool usable: true
    property color colAccent: "#a3cef1"
    property color colText: "#e0e1dd"
    property color colBg: "#181825"
    property string fontFamily: "JetBrainsMono Nerd Font, Monospace"
    property real radius: 6
    property real glyphZone: 40
    property bool vertical: false
    property real textPx: 12             // размер текста по центру

    readonly property real zone: ((glyph !== "" || iconKind !== "") && !vertical) ? glyphZone : 0
    readonly property bool dragging: mouse.dragging
    readonly property bool hovered: mouse.containsMouse
    readonly property real hoverX: mouse.mouseX

    signal moved(real v)
    signal glyphClicked()
    signal wheeled(int dir)              // +1 вверх, -1 вниз
    signal doubleClicked()

    readonly property real vv: Math.max(0, Math.min(1, value))
    readonly property string text: label !== "" ? label : Math.round(vv * 100) + "%"

    // физика: показанный уровень догоняет значение через слегка недозатухающую пружину
    // (небольшой перелёт и качание); проценты и значение берутся с точного vv
    property real shown: vv
    property real shownV: 0
    readonly property real dispLevel: Math.max(0, Math.min(1, shown))
    readonly property bool filled: dispLevel > 0.002

    height: 32
    opacity: usable ? 1 : 0.4

    FrameAnimation {
        running: Math.abs(fs.shown - fs.vv) > 0.0004 || Math.abs(fs.shownV) > 0.002
        onTriggered: {
            const dt = Math.min(frameTime, 0.033)
            if (dt <= 0) return
            const w = 14, z = 0.55            // частота (рад/с) и затухание
            fs.shownV += (w * w * (fs.vv - fs.shown) - 2 * z * w * fs.shownV) * dt
            fs.shown += fs.shownV * dt
        }
        onRunningChanged: { if (!running) { fs.shown = fs.vv; fs.shownV = 0 } }
    }

    // подписи: глиф слева + текст по центру; рисуются дважды (обычным и тёмным цветом)
    component FatLabels: Item {
        id: fl
        property string glyph: ""
        property string text: ""
        property real zone: 0
        property color color: "white"
        property string fontFamily: ""
        property real px: 12
        property string iconKind: ""
        property int iconWaves: 99
        property bool iconSlashed: false

        // цвет подписей меняется плавно (тёмный цвет на воде идёт от colBg, он тоже может меняться с темой)
        Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }

        Text {
            x: 0
            width: fl.zone
            height: parent.height
            visible: fl.zone > 0 && fl.iconKind === ""
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: fl.glyph
            color: fl.color
            font.pixelSize: 15
            font.family: fl.fontFamily
        }

        SlashIcon {
            x: fl.zone / 2 - width / 2
            anchors.verticalCenter: parent.verticalCenter
            visible: fl.zone > 0 && fl.iconKind !== ""
            kind: fl.iconKind !== "" ? fl.iconKind : "mic"
            waves: fl.iconWaves
            slashed: fl.iconSlashed
            size: 16
            color: fl.color
        }

        Text {
            anchors.centerIn: parent
            text: fl.text
            color: fl.color
            font.pixelSize: fl.px
            font.bold: true
            font.family: fl.fontFamily
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: fs.radius
        color: Qt.alpha(fs.colText, mouse.containsMouse ? 0.14 : 0.10)
        Behavior on color { ColorAnimation { duration: 150 } }
    }

    // вода: обёртка нужна, чтобы маска получила уже повёрнутую картинку (слой item'а своё вращение не включает)
    Item {
        id: waterBox
        anchors.fill: parent
        layer.enabled: true               // всегда включён: пустая вода на нуле = пустая маска (WaterEffect сам скрыт при level ~ 0)

        WaterEffect {
            // горизонтально: в своих координатах плитка "стоит" (height x width), потом поворот 90° по часовой:
            // низ воды уезжает влево, поверхность идёт вправо. Вертикально: как есть, вода снизу вверх
            width: fs.vertical ? fs.width : fs.height
            height: fs.vertical ? fs.height : fs.width
            anchors.centerIn: parent
            rotation: fs.vertical ? 0 : 90
            layered: false                // слой уже есть у waterBox, свой второй не нужен
            level: fs.dispLevel
            active: mouse.dragging
            fillColor: fs.colAccent
            cornerRadius: fs.radius
            fillAlpha: fs.dimmed ? 0.4 : 0.9
        }
    }

    // подписи: обычные там, где воды нет, тёмные там, где она есть
    FatLabels {
        id: labNormal
        anchors.fill: parent
        glyph: fs.glyph
        iconKind: fs.iconKind
        iconWaves: fs.iconWaves
        iconSlashed: fs.iconSlashed
        text: fs.text
        zone: fs.zone
        px: fs.textPx
        color: fs.colText
        fontFamily: fs.fontFamily
        visible: false                    // источник для MultiEffect; слои включены всегда, чтобы текст не пропадал
        layer.enabled: true               // при переключении слоя на нуле (пружина колеблется около 0) текст терялся
        layer.smooth: true
        layer.textureSize: Qt.size(width * 2, height * 2)
    }

    FatLabels {
        id: labDark
        anchors.fill: parent
        glyph: fs.glyph
        iconKind: fs.iconKind
        iconWaves: fs.iconWaves
        iconSlashed: fs.iconSlashed
        text: fs.text
        zone: fs.zone
        px: fs.textPx
        color: fs.colBg
        fontFamily: fs.fontFamily
        visible: false
        layer.enabled: true
        layer.smooth: true
        layer.textureSize: Qt.size(width * 2, height * 2)
    }

    MultiEffect {
        anchors.fill: parent
        source: labNormal
        maskEnabled: true
        maskSource: waterBox
        maskInverted: true
    }

    MultiEffect {
        anchors.fill: parent
        source: labDark
        maskEnabled: true
        maskSource: waterBox
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: fs.usable
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        property bool dragging: false
        property real pressX: 0

        function setFrom(x, y) {
            fs.moved(fs.vertical ? Math.max(0, Math.min(1, 1 - y / fs.height))
                                 : Math.max(0, Math.min(1, x / fs.width)))
        }

        // вне зоны иконки ползунок хватается сразу; в зоне иконки - только если потянули (иначе это клик),
        // поэтому с нуля можно схватить и выкрутить, даже нажав на самый левый край
        onPressed: (m) => {
            pressX = m.x
            dragging = m.x >= fs.zone
            if (dragging) setFrom(m.x, m.y)
        }
        onPositionChanged: (m) => {
            if (!pressed) return
            if (!dragging && Math.abs(m.x - pressX) > 4) dragging = true
            if (dragging) setFrom(m.x, m.y)
        }
        onReleased: {
            if (!dragging && pressX < fs.zone) fs.glyphClicked()
            dragging = false
        }
        onDoubleClicked: fs.doubleClicked()
        onCanceled: dragging = false
        onWheel: (w) => {
            fs.wheeled(w.angleDelta.y > 0 ? 1 : -1)
            w.accepted = true
        }
    }
}
