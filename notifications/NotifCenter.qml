// NotifCenter.qml
//
// Центр уведомлений: полноэкранный оверлей с блюром, по центру карточки «веером»
// (глубина / поворот / затухание как у SmCard.qml в настройках), камера-параллакс
// за мышью и ступенчатое появление карточек.
//
// Кто за что отвечает:
//   - данные берём из store (это Notify.qml): store.history, store.unreadCount, removeHistory()
//   - центр сам говорит store что он открыт (centerOpen), чтобы всплывашки не лезли поверх
//   - карусель: все карточки стоят в центре, а позицию каждой считает её расстояние
//     до выбранной (currentIndex) — соседи прячутся под выбранную
//   - управление: стрелки / колесо мыши — листать, Enter/Delete — прочитано, Esc — закрыть
//
// Блюр фона свой (LiveBackdrop + BarBlur), без Hyprland.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import "../bar"
import "../panels"
import "../settings"
import "../common"
import "../icons"
import "../lang"


PanelWindow {
    id: center

    required property var store           // Notify.qml
    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary
    required property color colGlass      // (оставлено для совместимости с Visual.qml)

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"

    property bool isClosing: false

    // Выбранная карточка + «открыт ли центр» (для ступенчатого появления)
    property int currentIndex: 0
    property bool opened: false

    // Глубина веера, как setDepthNear / setDepthStep в SettingsMenu (там карточки 200 px, тут 240)
    readonly property real depthNear: 215
    readonly property real depthStep: 80

    anchors { top: true; bottom: true; left: true; right: true }
    margins { top: 0; bottom: 0; left: 0; right: 0 }

    exclusionMode: ExclusionMode.Ignore    // поверх бара: его exclusive zone окно не двигает

    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "notification-center"
    visible: false

    // пока центр открыт, новые уведомления поверх него не всплывают
    onVisibleChanged: center.store.centerOpen = visible


    // Открывает/закрывает центр. При закрытии играет анимацию, при открытии сбрасывает
    // выбор на первую карточку и отдаёт фокус карусели
    function toggleMenu() {
        if (isClosing) return;

        if (visible) {
            isClosing = true;
            openAnim.stop();
            closeAnim.start();
        } else {
            visible = true;
            currentIndex = 0;
            opened = true;
            openAnim.start();
            Qt.callLater(() => carousel.forceActiveFocus());
        }
    }

    // Помечает прочитанной (убирает) выбранную сейчас карточку
    function dismissCurrent() {
        var it = rep.itemAt(currentIndex);
        if (it) it.dismiss(0, false);
    }

    // Убирает все карточки каскадом: от выбранной к краям (чем дальше — тем позже).
    // Сама история чистится по таймеру, когда анимации уже доиграли
    function clearAll() {
        for (var i = 0; i < rep.count; i++) {
            var it = rep.itemAt(i);
            if (it)
                it.dismiss(Math.min(Math.abs(i - currentIndex), 8) * 40, true);
        }
        clearTimer.restart();
    }

    Timer {
        id: clearTimer
        interval: 800
        onTriggered: center.store.clearHistory()
    }


    // Индекс не должен вылезать за список после удалений
    Connections {
        target: center.store.history
        function onCountChanged() {
            center.currentIndex = Math.max(0, Math.min(center.currentIndex, center.store.history.count - 1));
        }
    }

    // Сообщение прочитали в самом приложении -> карточка плавно уходит из истории
    // (если центр закрыт или карточки нет на экране — просто удаляем запись)
    Connections {
        target: center.store
        function onSourceRead(uid) {
            var h = center.store.history;
            for (var i = 0; i < h.count; i++) {
                if (h.get(i).uid === uid) {
                    var it = rep.itemAt(i);
                    if (it && center.visible) {
                        it.dismiss(0, false);
                        return;
                    }
                    break;
                }
            }
            center.store.removeHistory(uid);
        }
    }


    // ---------- Блюр вместо затемнения ----------
    property string wallpaper: ""      // путь к обоям (приходит из Visual.qml)
    property bool blurEnabled: true    // включается в меню настроек
    property real blurRadius: 30       // сила размытия, px
    property real blurDim: 0.12        // лёгкое затемнение поверх блюра (0 — без него)

    // «Камера»: панель чуть смещается и наклоняется за мышью (параллакс как в настройках)
    property bool camEffect: true             // можно привязать к barLayout.camEffect из Visual.qml
    readonly property bool camOn: camEffect
    property real camStrength: 1.0            // общая сила: 0 — выкл, 1 — норма, 2 — вдвое сильнее
    property real camMoveX: 50                // макс. сдвиг по X, px
    property real camMoveY: 28                // макс. сдвиг по Y, px
    property real camTilt: 3.5                // макс. наклон, градусы

    readonly property real camTargetX: (camOn && camHover.hovered && width > 0)
        ? clamp01(camHover.point.position.x / width) * 2 - 1 : 0
    readonly property real camTargetY: (camOn && camHover.hovered && height > 0)
        ? clamp01(camHover.point.position.y / height) * 2 - 1 : 0

    property real camX: camTargetX
    property real camY: camTargetY

    // SmoothedAnimation не стартует с нуля на каждое движение мыши, поэтому слежение плавнее
    Behavior on camX { SmoothedAnimation { velocity: 2.2; maximumEasingTime: 300 } }
    Behavior on camY { SmoothedAnimation { velocity: 2.2; maximumEasingTime: 300 } }

    // Зажимает число в диапазон 0..1 (для расчёта положения мыши)
    function clamp01(v) { return Math.max(0, Math.min(1, v)) }


    // «Живой» фон: обои + окна. Самой панели и бара в нём нет, так что блюр сам себя не съедает
    LiveBackdrop {
        id: backdrop
        screenObj: center.screen
        wallpaper: center.wallpaper
        autoDetect: false
        active: center.visible && center.blurEnabled
        pollInterval: 500
        baseColor: "#14141a"     // обоев нет — ровный тёмный фон
        x: -width - 64
        y: -height - 64
    }

    // Размытый фон на весь экран (вместе с баром); появляется/исчезает вместе с панелью
    BarBlur {
        source: (center.blurEnabled && backdrop.width > 0) ? backdrop.texture : null
        srcSize: Qt.size(backdrop.width, backdrop.height)
        originX: 0
        originY: 0
        rect: ({ x: 0, y: 0, w: center.width, h: center.height })
        cornerRadius: 0
        blurRadius: center.blurRadius
        tint: Qt.rgba(0, 0, 0, center.blurDim)
        strength: Math.min(1, menuContainer.opacity * 2)
    }

    // блюр выключен -> по-старому просто затемняем
    Rectangle {
        anchors.fill: parent
        color: "black"
        visible: !center.blurEnabled
        opacity: menuContainer.opacity * 0.5
    }

    // Слежение за мышью для камеры (HoverHandler пассивный, клики не перехватывает)
    Item {
        id: camSurface
        anchors.fill: parent
        HoverHandler { id: camHover }
    }

    // клик по пустому месту закрывает центр
    MouseArea {
        anchors.fill: parent
        onClicked: center.toggleMenu()
    }


    Item {
        id: menuContainer
        anchors.centerIn: parent
        width: parent.width
        height: 400

        scale: 0.0
        opacity: 0.0

        transform: [
            Translate {
                x: -center.camX * center.camMoveX * center.camStrength
                y: -center.camY * center.camMoveY * center.camStrength
            },
            Rotation {
                origin.x: menuContainer.width / 2
                origin.y: menuContainer.height / 2
                axis { x: 0; y: 1; z: 0 }
                angle: center.camX * center.camTilt * center.camStrength
            },
            Rotation {
                origin.x: menuContainer.width / 2
                origin.y: menuContainer.height / 2
                axis { x: 1; y: 0; z: 0 }
                angle: -center.camY * center.camTilt * center.camStrength
            }
        ]

        // клики внутри центр не закрывают
        MouseArea {
            anchors.fill: parent
            onClicked: (mouse) => mouse.accepted = true
        }

        // Анимации открытия/закрытия — те же что в меню настроек
        ParallelAnimation {
            id: openAnim
            NumberAnimation { target: menuContainer; property: "scale"; from: 0.88; to: 1.0; duration: 280; easing.type: Easing.OutCubic }
            NumberAnimation { target: menuContainer; property: "opacity"; from: 0.0; to: 1.0; duration: 200; easing.type: Easing.OutCubic }
        }

        ParallelAnimation {
            id: closeAnim
            NumberAnimation { target: menuContainer; property: "scale"; from: 1.0; to: 0.7; duration: 200; easing.type: Easing.InCubic }
            NumberAnimation { target: menuContainer; property: "opacity"; from: 1.0; to: 0.0; duration: 150; easing.type: Easing.InCubic }

            onFinished: {
                center.visible = false;
                center.opened = false;
                center.isClosing = false;
            }
        }


        ColumnLayout {
            anchors.centerIn: parent
            width: parent.width
            spacing: 25

            // ==================== ШАПКА ====================
            // Обёртка на всю ширину: PanelHeader вне layout, центрируется якорем
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 60

                PanelHeader {
                    anchors.horizontalCenter: parent.horizontalCenter

                    colBg: center.colBg
                    colAccent: center.colAccent
                    colText: center.colText
                    colSecondary: center.colSecondary
                    fontFamily: center.fontFamily
                    iconName: "notifications"
                    title: Tr.tr("win.notifications")
                    badge: center.store.unreadCount > 0 ? String(center.store.unreadCount) : ""

                    // кнопка «Очистить всё» (видна только если есть что чистить)
                    Rectangle {
                        visible: center.store.unreadCount > 0
                        Layout.preferredHeight: 60
                        Layout.preferredWidth: clearText.implicitWidth + 36
                        radius: 14
                        color: clearArea.containsMouse ? center.colAccent : Qt.alpha(center.colSecondary, 0.9)

                        Behavior on color { ColorAnimation { duration: 150 } }

                        Text {
                            id: clearText
                            anchors.centerIn: parent
                            text: Tr.tr("notif.clear")
                            color: clearArea.containsMouse ? center.colBg : center.colText
                            font.pixelSize: 14
                            font.bold: true
                            font.family: center.fontFamily

                            Behavior on color { ColorAnimation { duration: 150 } }
                        }

                        MouseArea {
                            id: clearArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: center.clearAll()
                        }
                    }
                }
            }


            // ==================== КАРУСЕЛЬ ====================
            Item {
                id: carousel
                Layout.fillWidth: true
                Layout.preferredHeight: 280
                focus: true

                // заглушка «пусто», видна только когда уведомлений нет
                Row {
                    anchors.centerIn: parent
                    spacing: 8
                    opacity: center.store.unreadCount === 0 ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    Icon {
                        name: "notificationsOff"
                        size: 16
                        color: center.colAccent
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: Tr.tr("notif.empty")
                        color: center.colText
                        font.pixelSize: 12
                        font.bold: true
                        font.family: center.fontFamily
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // Карточки не в ListView: все стоят в центре, а позицию задаёт глубина
                // относительно выбранной (как depthX в SmCard) — соседи прячутся под выбранную
                Repeater {
                    id: rep
                    model: center.store.history

                    delegate: Item {
                        id: slot

                        required property int index
                        required property int uid
                        required property string appName
                        required property string summary
                        required property string body
                        required property string timeText

                        readonly property bool isCurrent: index === center.currentIndex
                        readonly property int dist: Math.abs(index - center.currentIndex)

                        property bool ready: false     // появление: false -> true со ступенчатой задержкой
                        property bool hiding: false    // карточка уходит (уменьшается и гаснет)
                        property bool keep: false      // true -> из истории её уберёт clearAll, а не сама карточка
                        property int hideDelay: 0

                        width: 240
                        height: 260
                        x: (carousel.width - width) / 2
                        y: (carousel.height - height) / 2
                        z: isCurrent ? 100 : 50 - dist


                        // Запускает уход карточки. delay — задержка перед стартом (для каскада),
                        // keepInModel — не удалять запись из истории (это потом сделает clearAll)
                        function dismiss(delay, keepInModel) {
                            if (hiding || animHide.running) return;
                            hideDelay = delay || 0;
                            keep = !!keepInModel;
                            animHide.start();
                        }

                        // Готовит ступенчатое появление: чем дальше от выбранной, тем позже раскроется
                        function armIntro() {
                            if (!center.opened) return;
                            startTimer.interval = 50 + Math.min(Math.abs(index - center.currentIndex), 6) * 35;
                            startTimer.restart();
                        }

                        Component.onCompleted: armIntro()

                        Connections {
                            target: center
                            function onOpenedChanged() {
                                if (center.opened) {
                                    slot.armIntro();
                                } else {
                                    startTimer.stop();
                                    slot.ready = false;
                                }
                            }
                        }

                        Timer {
                            id: startTimer
                            onTriggered: slot.ready = true
                        }

                        // Уход: карточка опускается, уменьшается и гаснет, потом запись уходит из истории,
                        // а соседи плавно занимают её место (их позиции анимируют Behavior'ы ниже)
                        SequentialAnimation {
                            id: animHide
                            PauseAnimation { duration: slot.hideDelay }
                            ScriptAction { script: slot.hiding = true }
                            PauseAnimation { duration: 220 }
                            ScriptAction {
                                script: {
                                    if (slot.keep) return;
                                    // выбранной остаётся та же карточка, даже если удалили левую
                                    if (slot.index < center.currentIndex) center.currentIndex--;
                                    center.store.removeHistory(slot.uid);
                                }
                            }
                        }


                        Item {
                            id: card
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.horizontalCenterOffset: depthX
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: baseOffset
                            width: 240
                            height: 240

                            // единые тайминги, чтобы всё у карточки двигалось синхронно
                            readonly property int moveMs: 360
                            readonly property int fadeMs: 260

                            // прячем только когда карточка уже полностью прозрачна
                            visible: opacity > 0.01

                            // смещение по X от центра: у выбранной 0, у остальных — вбок по глубине
                            property real depthX: {
                                if (!slot.ready) return 0;
                                if (slot.isCurrent) return 0;
                                return (slot.index > center.currentIndex ? 1 : -1)
                                    * (center.depthNear + (slot.dist - 1) * center.depthStep - 15);
                            }

                            // поворот вокруг вертикальной оси (веер)
                            property real rotAngle: {
                                if (!slot.ready) return 90;
                                if (slot.isCurrent) return 0;
                                return slot.index > center.currentIndex ? -35 : 35;
                            }

                            // смещение по Y: уходящая падает вниз, выбранная чуть приподнята
                            property real baseOffset: slot.hiding ? 70 : !slot.ready ? 30
                                : (slot.isCurrent ? -10 : Math.min(slot.dist, 4) * 8)

                            // к краю веера карточки плавно гаснут до нуля
                            opacity: {
                                if (slot.hiding) return 0.0;
                                if (!slot.ready) return 0.0;
                                return slot.isCurrent ? 1.0 : Math.max(0.0, 0.5 - (slot.dist - 1) * 0.1);
                            }

                            scale: {
                                if (slot.hiding) return 0.5;
                                if (!slot.ready) return 0.7;
                                return slot.isCurrent ? 1.12 : Math.max(0.6, 0.85 - (slot.dist - 1) * 0.06);
                            }

                            transform: Rotation {
                                origin.x: card.width / 2
                                origin.y: card.height / 2
                                axis { x: 0; y: 1; z: 0 }
                                angle: card.rotAngle
                            }

                            Behavior on depthX { NumberAnimation { duration: card.moveMs; easing.type: Easing.OutCubic } }
                            Behavior on rotAngle { NumberAnimation { duration: card.moveMs; easing.type: Easing.OutCubic } }
                            Behavior on baseOffset { NumberAnimation { duration: card.moveMs; easing.type: Easing.OutCubic } }
                            Behavior on opacity { NumberAnimation { duration: card.fadeMs; easing.type: Easing.OutCubic } }
                            Behavior on scale { NumberAnimation { duration: card.moveMs; easing.type: Easing.OutCubic } }


                            Rectangle {
                                anchors.fill: parent
                                radius: 14

                                // лёгкое «прижатие» при клике
                                scale: cardMouse.pressed ? 0.97 : 1.0
                                Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

                                color: Qt.alpha(center.colSecondary,
                                                slot.isCurrent ? 0.9 : (cardMouse.containsMouse ? 0.6 : 0.4))

                                Behavior on color { ColorAnimation { duration: 150 } }

                                // Клик: выбрать карточку; клик по уже выбранной = прочитано.
                                // Объявлена первой, чтобы кнопка закрытия была выше неё
                                MouseArea {
                                    id: cardMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (slot.isCurrent)
                                            slot.dismiss(0, false);
                                        else
                                            center.currentIndex = slot.index;
                                    }
                                }

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 16
                                    spacing: 8

                                    // верх карточки: точка + название приложения + крестик
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8

                                        Rectangle {
                                            Layout.preferredWidth: 6
                                            Layout.preferredHeight: 6
                                            radius: 2
                                            color: center.colAccent
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            text: slot.appName
                                            color: center.colAccent
                                            font.bold: true
                                            font.pixelSize: 12
                                            font.family: center.fontFamily
                                            elide: Text.ElideRight
                                        }

                                        Item {
                                            Layout.preferredWidth: 20
                                            Layout.preferredHeight: 20

                                            Icon {
                                                anchors.centerIn: parent
                                                name: "close"
                                                size: 13
                                                color: closeArea.containsMouse ? center.colAccent : center.colText
                                                opacity: closeArea.containsMouse ? 1.0 : 0.55

                                                Behavior on color { ColorAnimation { duration: 150 } }
                                                Behavior on opacity { NumberAnimation { duration: 150 } }
                                            }

                                            MouseArea {
                                                id: closeArea
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: slot.dismiss(0, false)
                                            }
                                        }
                                    }

                                    // заголовок уведомления
                                    Text {
                                        Layout.fillWidth: true
                                        visible: text !== ""
                                        text: slot.summary
                                        color: center.colText
                                        font.bold: true
                                        font.pixelSize: 13
                                        font.family: center.fontFamily
                                        wrapMode: Text.WordWrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                    }

                                    // текст уведомления
                                    Text {
                                        Layout.fillWidth: true
                                        visible: text !== ""
                                        text: slot.body
                                        color: center.colText
                                        opacity: 0.75
                                        font.pixelSize: 11
                                        font.family: center.fontFamily
                                        wrapMode: Text.WordWrap
                                        maximumLineCount: 6
                                        elide: Text.ElideRight
                                    }

                                    Item { Layout.fillHeight: true }

                                    // время внизу справа
                                    Text {
                                        Layout.alignment: Qt.AlignRight
                                        text: slot.timeText
                                        color: center.colText
                                        opacity: 0.55
                                        font.pixelSize: 10
                                        font.family: center.fontFamily
                                    }
                                }
                            }
                        }
                    }
                }


                // клавиатура: стрелки листают, Enter/Delete — прочитано, Esc — закрыть
                Keys.onLeftPressed: if (center.currentIndex > 0) center.currentIndex--
                Keys.onRightPressed: if (center.currentIndex < center.store.history.count - 1) center.currentIndex++
                Keys.onReturnPressed: center.dismissCurrent()
                Keys.onDeletePressed: center.dismissCurrent()
                Keys.onEscapePressed: center.toggleMenu()

                // колесо мыши / тачпад тоже листает карточки
                WheelHandler {
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: (event) => {
                        let delta = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x;
                        if (delta > 0 && center.currentIndex > 0) {
                            center.currentIndex--;
                        } else if (delta < 0 && center.currentIndex < center.store.history.count - 1) {
                            center.currentIndex++;
                        }
                        event.accepted = true;
                    }
                }
            }
        }
    }
}
