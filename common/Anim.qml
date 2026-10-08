// Anim.qml
//
// Зачем это: анимация появления бара при старте шелла. Без неё бар просто
// резко выскакивает на экране, а так он плавно выезжает от края и заодно
// проявляется из прозрачного. Запускается сама, как только компонент создан,
// ничего вызывать руками не надо.
//
// Как юзать: Anim { targetItem: bar }
// у targetItem должны быть свойства slide и opacity, иначе анимировать нечего
import QtQuick
import "../bar"
import "../panels"
import "../notifications"
import "../settings"


ParallelAnimation {
    id: animRoot

    // то, что анимируем (обязательно передать)
    required property Item targetItem

    // стартуем сразу как создались
    Component.onCompleted: {
        animRoot.start()
    }

    // выезд: полоса бара едет к краю экрана, 85 -> 0 (0 = на месте)
    NumberAnimation {
        target: animRoot.targetItem
        property: "slide"      // сдвиг полосы бара к краю экрана (0 = на месте)
        from: 85;  to: 0
        duration: 2000
        easing.type: Easing.OutCubic
    }
    // проявление: из прозрачного в видимый, чуть быстрее чем выезд
    NumberAnimation {
        target: animRoot.targetItem
        property: "opacity"
        from: 0.0
        to:1.0
        duration:1400
        easing.type: Easing.OutCubic
    }
}
