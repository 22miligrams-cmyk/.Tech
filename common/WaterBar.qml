import QtQuick

// WaterBar.qml - индикатор (не интерактивный) с водой: дорожка + заливка WaterEffect.
// Горизонтальный: вода слева направо (шейдер повёрнут на 90°). vertical: true - снизу вверх.
// Уровень плавно едет к value так же, как в виджетах Lock.qml (900 мс InOutQuad), цвета меняются плавно.
Item {
    id: wb

    property real value: 0               // 0..1
    property color fill: "#a3cef1"
    property color track: "#22ffffff"
    property real radius: 4
    property bool vertical: false
    property real fillAlpha: 0.9

    readonly property real vv: Math.max(0, Math.min(1, value))

    // как у плиток-виджетов в Lock.qml (FillTile): уровень едет по времени, 900 мс InOutQuad.
    // Новое значение просто меняет цель, анимация подхватывает с текущего места - без рывков
    property real level: vv
    Behavior on level { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }

    Rectangle {
        anchors.fill: parent
        radius: wb.radius
        color: wb.track

        Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
    }

    WaterEffect {
        layered: false
        // горизонтально плитка "стоит" (height x width) и поворачивается на 90°: низ воды слева
        width: wb.vertical ? wb.width : wb.height
        height: wb.vertical ? wb.height : wb.width
        anchors.centerIn: parent
        rotation: wb.vertical ? 0 : 90
        level: wb.level
        fillColor: wb.fill
        cornerRadius: wb.radius
        fillAlpha: wb.fillAlpha
    }
}
