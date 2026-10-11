import QtQuick

// WaterEffect.qml - вода-заливка (шейдер ../assets/WaterFill.frag.qsb) с лёгкой физикой.
// Используется в плитках удержания (HoldTile), в полосках (FatSlider) и в индикаторах (WaterBar).
// Размер и положение задаёт тот, кто использует (anchors.fill / width+height).
ShaderEffect {
    id: hw
    property real level: 0               // 0..1
    property bool active: false          // идёт удержание: поверхность плещется
    property color fillColor: "#a3cef1"
    property real cornerRadius: 6
    property int idleFps: 30             // частота фоновой анимации воды (кадров/с): медленная волна не нуждается в 60-144 fps

    visible: level > 0.002
    // анимации идут только пока окно с панелью реально показано (скрытая панель не тратит ресурсы)
    readonly property bool _live: visible && Window.window !== null && Window.window.visible
    // полный стакан: поверхность плоская, двигать нечего - анимацию времени останавливаем совсем
    readonly property bool _full: level > 0.998 && !active
    // физика (пружина/рябь) считается покадрово только пока вода реально движется, в покое FrameAnimation стоит
    property bool _busy: false
    onLevelChanged: _busy = true
    // текстура воды = маска, по которой иконка краснеет в тёмный (см. HoldTile); для простых полосок слой не нужен
    property bool layered: true
    layer.enabled: layered
    fragmentShader: Qt.resolvedUrl("../assets/WaterFill.frag.qsb")

    property size tileSize: Qt.size(width, height)
    property real time: 0
    property real slosh: active ? 0.25 : 0
    property real radiusPx: cornerRadius
    property real fillAlpha: 0.9
    property real tilt: 0                // физика: покачивание поверхности (пружина), в шейдер
    property real ripple: 0              // физика: рябь от резких изменений уровня, в шейдер
    Behavior on slosh { NumberAnimation { duration: 300 } }
    // смена цвета воды (акцент от обложки/темы) плавная, как в Bar.qml
    Behavior on fillColor { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }

    // физика: сглаженная скорость уровня -> ускорение раскачивает пружину-«плеск» (tilt),
    // а модуль скорости даёт рябь, которая затухает сама
    property real _prev: 0
    property real _vel: 0
    property real _tv: 0
    FrameAnimation {
        running: hw._live && hw._busy
        onTriggered: {
            const dt = Math.min(frameTime, 0.033)
            if (dt <= 0) return
            const v = (hw.level - hw._prev) / dt
            hw._prev = hw.level
            const vNew = hw._vel + (v - hw._vel) * Math.min(1, dt * 18)
            const acc = Math.max(-80, Math.min(80, (vNew - hw._vel) / dt))
            hw._vel = vNew
            const w = 11, z = 0.14            // частота (рад/с) и затухание пружины
            hw._tv += (-w * w * hw.tilt - 2 * z * w * hw._tv + acc) * dt
            hw.tilt = Math.max(-1.2, Math.min(1.2, hw.tilt + hw._tv * dt))
            hw.ripple = Math.max(hw.ripple * Math.exp(-dt * 3), Math.min(1.5, Math.abs(vNew) * 0.35))
            // всё улеглось: обнуляем и выключаем покадровый расчёт до следующего изменения уровня
            if (Math.abs(vNew) < 0.005 && Math.abs(hw.tilt) < 0.003 && Math.abs(hw._tv) < 0.003 && hw.ripple < 0.003) {
                hw.tilt = 0; hw._tv = 0; hw.ripple = 0; hw._vel = 0
                hw._busy = false
            }
        }
    }
    onVisibleChanged: {
        _prev = level
        if (!visible) { tilt = 0; ripple = 0; _vel = 0; _tv = 0 }
    }

    // время для фоновой ряби/каустики: таймер на idleFps вместо покадровой анимации, период цикла 8 с.
    // Все частоты в шейдере по времени целые, поэтому сброс по модулю 2π шва не даёт
    property double _last: 0
    Timer {
        interval: Math.round(1000 / Math.max(1, hw.idleFps))
        repeat: true
        running: hw._live && !hw._full
        onRunningChanged: if (running) hw._last = Date.now()
        onTriggered: {
            const n = Date.now()
            hw.time = (hw.time + (n - hw._last) * 6.283185307 / 8000) % 6.283185307
            hw._last = n
        }
    }
}
