// Карусель карточек внутри раздела. Показывает модель текущей вкладки (бар, лаунчеры или бинды)
// и обрабатывает клавиатуру: стрелки, Enter, Tab, Esc, запись клавиш для биндов, E/Delete на своих биндах.
import QtQuick
import QtQuick.Layouts

ListView {
    id: settingsGrid
    required property var menu
    Layout.fillWidth: true
    height: 280
    orientation: ListView.Horizontal
    spacing: 0
    clip: false
    focus: true

    cacheBuffer: Math.max(1600, count * 210)

    preferredHighlightBegin: width / 2 - 110
    preferredHighlightEnd: width / 2 + 110
    highlightRangeMode: ListView.StrictlyEnforceRange
    highlightMoveDuration: menu.cardsInstant ? 0 : 100

    model: menu.view !== "section" ? []
         : (menu.tab === "bar" ? menu.barCtl.barModel
         : (menu.tab === "launchers" ? menu.launchCtl.launcherModel : menu.bindsCtl.bindModel))

    delegate: SmCard { menu: settingsGrid.menu; grid: settingsGrid }

    Keys.onPressed: (event) => {
        if (menu.bdCapture === "") {
            const it = model[currentIndex]
            if (it && menu.tab === "binds") {
                if (it.custom && event.key === Qt.Key_E) { event.accepted = true; it.edit(); return }
                if (it.remove && event.key === Qt.Key_Delete) { event.accepted = true; it.remove(); return }
            }
            event.accepted = false; return
        }
        event.accepted = true
        menu.bindsCtl.captureKey(event)
    }
    Keys.onLeftPressed: if (currentIndex > 0) currentIndex--
    Keys.onRightPressed: if (currentIndex < count - 1) currentIndex++
    Keys.onReturnPressed: {
        let item = model[currentIndex];
        if (item) item.set(!item.get());
    }
    Keys.onUpPressed: { menu.barCtl.stepAlpha(0.05); menu.blurCtl.stepBlur(0.05); menu.launchCtl.stepItem(0.05) }
    Keys.onDownPressed: { menu.barCtl.stepAlpha(-0.05); menu.blurCtl.stepBlur(-0.05); menu.launchCtl.stepItem(-0.05) }
    Keys.onTabPressed: menu.nextTab()
    Keys.onBacktabPressed: menu.nextTab()
    Keys.onEscapePressed: menu.goBack()

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: (event) => {
            let delta = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x;
            if (delta > 0 && settingsGrid.currentIndex > 0) {
                settingsGrid.currentIndex--;
            } else if (delta < 0 && settingsGrid.currentIndex < settingsGrid.count - 1) {
                settingsGrid.currentIndex++;
            }
            event.accepted = true;
        }
    }
}
