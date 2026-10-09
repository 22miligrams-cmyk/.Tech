// Notify.qml
//
// Мозг всей системы уведомлений. Тут сразу несколько вещей:
//   1. NotificationServer — принимает уведомления от приложений по D-Bus
//   2. historyModel — история для центра уведомлений (живёт пока юзер сам не удалит)
//   3. notifModel — всплывашки справа сверху (живут несколько секунд и уезжают)
//   4. PanelWindow с карточками, анимацией появления/ухода и блюром под стеклом
//
// Как связано с остальным:
//   - NotifCenter.qml берёт отсюда history и выставляет centerOpen
//   - DND (doNotDisturb) приходит из меню настроек: всплывашки не показываем, история копится
//   - если приложение само закрыло уведомление (прочитал в мессенджере) — шлём sourceRead,
//     и карточка пропадает из центра
//
// Блюр свой (LiveBackdrop + BarBlur), Hyprland-овские layer rules не нужны.
import QtQuick
import Quickshell
import Quickshell.Services.Notifications
import Quickshell.Wayland
import "../bar"
import "../panels"
import "../settings"
import "../common"


Scope {
    id: notifRoot

    // Тема берётся прямо из Logic (те же цвета что у бара, обновляются вместе с ним)
    required property var logic
    readonly property color colGlass: logic.colGlass
    readonly property string colAccent: logic.colAccent
    readonly property string colText: logic.colText
    readonly property string colSecondary: logic.colSecondary
    readonly property real cr: 6    // радиус как у остальных панелей
    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"

    // ---------- Блюр под карточками ----------
    property string wallpaper: ""      // путь к обоям (приходит из Visual.qml, как и у NotifCenter)
    property bool blurEnabled: true    // включается в меню настроек
    property real blurRadius: 16       // сила размытия, px
    property color blurTint: Qt.rgba(0.05, 0.05, 0.07, 0.25)

    readonly property int maxVisible: 3      // больше трёх карточек на экране не держим
    readonly property int maxHistory: 100    // и больше сотни в истории тоже
    property int nextUid: 0

    // Открыт ли центр уведомлений (это выставляет сам NotifCenter)
    property bool centerOpen: false

    // Не беспокоить (из меню настроек): всплывашки не показываем, история всё равно копится
    property bool doNotDisturb: false

    // Всплывающие карточки
    ListModel { id: notifModel }

    // История для центра: хранится пока юзер сам не удалит
    ListModel { id: historyModel }
    property alias history: historyModel
    readonly property int unreadCount: historyModel.count

    // Живые уведомления от приложений (uid -> Notification). Держим их, чтобы узнать
    // когда приложение само закроет уведомление (сообщение прочитано в источнике)
    property var live: ({})

    // Сообщение прочитано в самом приложении -> убрать из центра
    signal sourceRead(int uid)

    // Нажали «Обновить» на карточке обновления (Visual.qml ловит и запускает Updater.apply())
    signal updateRequested()


    // Приложение закрыло уведомление само (прочитали в мессенджере).
    // Всплывашка, если ещё висит, уезжает; из истории убираем либо плавно (если центр открыт),
    // либо сразу (если закрыт)
    function markReadFromSource(uid) {
        for (var i = 0; i < notifModel.count; i++) {
            if (notifModel.get(i).uid === uid && !notifModel.get(i).closing) {
                notifModel.setProperty(i, "closing", true);
                break;
            }
        }

        // открытый центр сам плавно уберёт карточку, закрытый — просто удаляем
        if (centerOpen)
            sourceRead(uid);
        else
            removeHistory(uid);
    }

    // Удаляет одну запись из истории по uid и говорит приложению что уведомление закрыто
    function removeHistory(uid) {
        var n = live[uid];
        if (n) {
            delete live[uid];
            n.dismiss();
        }

        for (var i = 0; i < historyModel.count; i++) {
            if (historyModel.get(i).uid === uid) {
                historyModel.remove(i);
                return;
            }
        }
    }

    // Чистит всю историю разом и закрывает все живые уведомления
    function clearHistory() {
        var all = live;
        live = ({});
        historyModel.clear();
        for (var k in all) all[k].dismiss();
    }

    // Отправляет все текущие всплывашки в анимацию ухода
    function dismissPopups() {
        for (var i = 0; i < notifModel.count; i++) {
            if (!notifModel.get(i).closing)
                notifModel.setProperty(i, "closing", true);
        }
    }

    // включили DND -> убираем то, что уже висит на экране
    onDoNotDisturbChanged: {
        if (doNotDisturb) dismissPopups();
    }

    // открыли центр -> всплывашки уезжают, чтобы не торчать под ним
    onCenterOpenChanged: {
        if (centerOpen) dismissPopups();
    }

    // Окончательно выкидывает всплывашку из модели (зовётся когда анимация ухода закончилась)
    function removeByUid(uid) {
        for (var i = 0; i < notifModel.count; i++) {
            if (notifModel.get(i).uid === uid) {
                notifModel.remove(i);
                return;
            }
        }
    }

    // Принимает готовое уведомление: кладёт в историю (всегда), а потом, если можно,
    // показывает всплывашкой и следит чтобы на экране было не больше maxVisible
    // force = true — системное уведомление (например, апдейт): пробивает «Не беспокоить»
    function pushNotification(item, force) {
        // 1. история — сохраняем всегда
        historyModel.insert(0, {
            uid: item.uid,
            appName: item.appName,
            summary: item.summary,
            body: item.body,
            kind: item.kind,
            actionText: item.actionText,
            timeText: Qt.formatDateTime(new Date(), "dd.MM HH:mm")
        });
        while (historyModel.count > maxHistory)
            removeHistory(historyModel.get(historyModel.count - 1).uid);

        // 2. всплывашку не показываем если открыт центр или включён DND
        //    (force пробивает DND, но не открытый центр — он и так перекрывает экран)
        if (centerOpen || (doNotDisturb && !force))
            return;

        // новая всегда сверху
        notifModel.insert(0, item);

        // считаем "живые" карточки (те что ещё не уезжают)
        var liveCount = 0;
        for (var i = 0; i < notifModel.count; i++) {
            if (!notifModel.get(i).closing) liveCount++;
        }

        // лишние старые (с конца) отправляем закрываться
        for (var j = notifModel.count - 1; j >= 0 && liveCount > maxVisible; j--) {
            if (!notifModel.get(j).closing) {
                notifModel.setProperty(j, "closing", true);
                liveCount--;
            }
        }
    }


    // Своё уведомление шелла (не через D-Bus), всегда пробивает DND.
    //   kind = "update" — карточка с кнопками «Обновить» / «Позже» и долгим таймаутом
    //   kind = "info"   — обычная карточка
    function pushSystem(title, body, kind, actionText, laterText) {
        pushNotification({
            uid: nextUid++,
            appName: ".Tech",
            summary: title || "",
            body: body || "",
            timeout: kind === "update" ? 30000 : 8000,
            closing: false,
            kind: kind || "info",
            actionText: actionText || "",
            laterText: laterText || ""
        }, true);
    }


    // Сервер уведомлений: сюда прилетает всё, что шлют приложения
    NotificationServer {
        id: server
        bodySupported: true

        onNotification: notification => {
            var app = notification.appName ? notification.appName.toLowerCase() : "";

            // скриншотер игнорируем: ни всплывашки, ни истории
            if (notification.summary === "Скриншот")
                return;

            // максимум 10 секунд на экране, у мессенджеров покороче
            var timeout = 10000;
            if (app.includes("telegram") || app.includes("discord") || app.includes("vesktop") || app.includes("tg") || app.includes("ayugram")) {
                timeout = 6000;
            }

            var uid = notifRoot.nextUid++;

            // Держим уведомление: если приложение закроет его само (прочитано в источнике),
            // считаем сообщение прочитанным и в центре тоже
            notification.tracked = true;
            notifRoot.live[uid] = notification;
            notification.closed.connect(function(reason) {
                delete notifRoot.live[uid];
                if (reason === NotificationCloseReason.CloseRequested)
                    notifRoot.markReadFromSource(uid);
            });

            notifRoot.pushNotification({
                uid: uid,
                appName: notification.appName || "Уведомление",
                summary: notification.summary || "",
                body: notification.body || "",
                timeout: timeout,
                closing: false,
                kind: "normal",
                actionText: "",
                laterText: ""
            });
        }
    }


    PanelWindow {
        id: popupWin
        visible: true

        // 380 карточка + 20 отступ справа: окно упирается прямо в край экрана,
        // поэтому карточка обрезается ровно по краю, а не за 20px до него
        implicitWidth: 400
        // высота фиксированная: ресайз layer-shell во время анимаций даёт дёрганье
        implicitHeight: 700
        color: "transparent"

        anchors.top: true
        anchors.right: true
        // под бар не залезаем, если он сверху или справа
        margins.top: 20 + (logic.barPosition === "top" ? 42 : 0)
        margins.right: logic.barPosition === "right" ? 42 : 0

        exclusionMode: ExclusionMode.Ignore

        // клики принимает только область с карточками, пустая часть окна для мыши "прозрачна"
        mask: Region { item: mainColumn }

        WlrLayershell.namespace: "notifications"
        WlrLayershell.keyboardFocus: WlrLayershell.KeyboardFocusOnDemand

        // Положение окна в координатах экрана (нужно для блюра: он считается по снимку всего экрана)
        readonly property real scrX: (screen ? screen.width : 0) - implicitWidth - margins.right
        readonly property real scrY: margins.top

        // «Живой» фон под карточками: обои + окна. Работает только пока есть всплывашки
        LiveBackdrop {
            id: backdrop
            screenObj: popupWin.screen
            wallpaper: notifRoot.wallpaper
            autoDetect: false
            active: popupWin.visible && notifRoot.blurEnabled && notifModel.count > 0
            roi: Qt.rect(popupWin.scrX, popupWin.scrY, popupWin.width, popupWin.height)
            pollInterval: 500
            baseColor: "#14141a"     // обоев нет — ровный тёмный фон вместо пустоты
            x: -width - 64
            y: -height - 64
        }


        Column {
            id: mainColumn
            width: parent.width
            spacing: 0

            Repeater {
                id: notifRep
                model: notifModel

                // Один слот = одна всплывашка. Высота слота анимируется (slot 0..1),
                // за счёт этого соседи плавно сдвигаются при появлении/уходе
                delegate: Item {
                    id: slotItem

                    required property int uid
                    required property string appName
                    required property string summary
                    required property string body
                    required property int timeout
                    required property bool closing
                    required property string kind
                    required property string actionText
                    required property string laterText

                    readonly property Item card: cardRect    // нужно для расчёта области blur
                    readonly property int gap: 10
                    readonly property int edgePad: 20        // отступ карточки от правого края экрана

                    // 0 -> 1 при появлении, 1 -> 0 при исчезновении
                    property real slot: 0
                    property bool hiding: false

                    width: mainColumn.width
                    height: (cardRect.height + gap) * slot
                    clip: true


                    // Запускает анимацию ухода (один раз; повторные вызовы игнорим)
                    function dismiss() {
                        if (hiding) return;
                        hiding = true;
                        animShow.stop();
                        animHide.start();
                    }

                    // карточку пометили как "лишнюю" (пришла 4-я и т.д.) -> уходит
                    onClosingChanged: {
                        if (closing) dismiss();
                    }

                    Component.onCompleted: animShow.start()


                    // Блюр под стеклом: повторяет форму карточки и выезжает вместе с ней
                    // (слот обрезает по краю окна, за экран ничего не вылезает)
                    BarBlur {
                        source: (notifRoot.blurEnabled && backdrop.width > 0) ? backdrop.texture : null
                        srcSize: Qt.size(backdrop.width, backdrop.height)
                        originX: popupWin.scrX + slotItem.x
                        originY: popupWin.scrY + slotItem.y
                        rect: ({ x: cardRect.x, y: cardRect.y, w: cardRect.width, h: cardRect.height })
                        cornerRadius: cardRect.radius
                        blurRadius: notifRoot.blurRadius
                        tint: notifRoot.blurTint
                        strength: 1
                    }

                    Rectangle {
                        id: cardRect

                        x: slotItem.width    // старт: целиком за правым краем экрана
                        y: 0

                        width: slotItem.width - slotItem.edgePad
                        height: contentCol.height + 20
                        color: notifRoot.colGlass
                        radius: notifRoot.cr

                        Behavior on color { ColorAnimation { duration: 300 } }

                        // клик по карточке = прочитано: убираем и из центра тоже
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                notifRoot.removeHistory(slotItem.uid);
                                slotItem.dismiss();
                            }
                        }

                        Column {
                            id: contentCol
                            x: 10;  y: 10
                            width: cardRect.width - 20
                            spacing: 6

                            // Шапка как у панелей: иконка на colSecondary + название + крестик
                            Item {
                                width: parent.width
                                height: 22

                                Rectangle {
                                    id: iconBox
                                    width: 22;  height: 22
                                    radius: notifRoot.cr
                                    color: notifRoot.colSecondary

                                    Text {
                                        anchors.centerIn: parent
                                        text: "\uf0f3"
                                        color: notifRoot.colAccent
                                        font.pixelSize: 12
                                        font.family: notifRoot.fontFamily
                                    }
                                }

                                Text {
                                    anchors.left: iconBox.right
                                    anchors.leftMargin: 8
                                    anchors.right: closeBtn.left
                                    anchors.rightMargin: 4
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: slotItem.appName
                                    color: notifRoot.colAccent
                                    font.bold: true
                                    font.pixelSize: 11
                                    font.family: notifRoot.fontFamily
                                    elide: Text.ElideRight
                                }

                                Rectangle {
                                    id: closeBtn
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 20;  height: 20
                                    radius: notifRoot.cr
                                    color: closeMa.containsMouse ? Qt.alpha(notifRoot.colText, 0.12) : "transparent"

                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    Text {
                                        anchors.centerIn: parent
                                        text: "×"
                                        color: Qt.alpha(notifRoot.colText, 0.7)
                                        font.pixelSize: 14
                                        font.family: notifRoot.fontFamily
                                    }

                                    MouseArea {
                                        id: closeMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            notifRoot.removeHistory(slotItem.uid);
                                            slotItem.dismiss();
                                        }
                                    }
                                }
                            }

                            // Сам текст сообщения во внутреннем блоке (как Card в SysMonitor)
                            Rectangle {
                                width: parent.width
                                visible: slotItem.summary !== "" || slotItem.body !== ""
                                height: msgCol.implicitHeight + 16
                                radius: notifRoot.cr
                                color: Qt.alpha(notifRoot.colText, 0.06)

                                Column {
                                    id: msgCol
                                    x: 8;  y: 8
                                    width: parent.width - 16
                                    spacing: 3

                                    Text {
                                        text: slotItem.summary
                                        width: parent.width
                                        visible: text !== ""
                                        color: notifRoot.colText
                                        font.bold: true
                                        font.pixelSize: 12
                                        font.family: notifRoot.fontFamily
                                        wrapMode: Text.WordWrap
                                    }

                                    Text {
                                        text: slotItem.body
                                        width: parent.width
                                        visible: text !== ""
                                        color: Qt.alpha(notifRoot.colText, 0.75)
                                        font.pixelSize: 11
                                        font.family: notifRoot.fontFamily
                                        wrapMode: Text.WordWrap
                                        maximumLineCount: 4
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }
                    }


                    // Появление: место раскрывается (остальные едут вниз), карточка выезжает из-за края
                    ParallelAnimation {
                        id: animShow

                        NumberAnimation { target: slotItem; property: "slot"; to: 1; duration: 320; easing.type: Easing.OutCubic }
                        NumberAnimation { target: cardRect; property: "x"; to: 0; duration: 380; easing.type: Easing.OutCubic }
                    }

                    // Уход: карточка уезжает вправо за край (без fade), потом место схлопывается
                    // и остальные плавно поднимаются. В конце выкидываем из модели
                    SequentialAnimation {
                        id: animHide

                        ParallelAnimation {
                            NumberAnimation { target: cardRect; property: "x"; to: slotItem.width; duration: 300; easing.type: Easing.InCubic }
                        }
                        NumberAnimation { target: slotItem; property: "slot"; to: 0; duration: 220; easing.type: Easing.OutCubic }

                        onFinished: notifRoot.removeByUid(slotItem.uid)
                    }

                    // автозакрытие по таймауту
                    Timer {
                        interval: slotItem.timeout
                        running: slotItem.timeout > 0 && !slotItem.hiding
                        repeat: false
                        onTriggered: slotItem.dismiss()
                    }
                }
            }
        }
    }
}
