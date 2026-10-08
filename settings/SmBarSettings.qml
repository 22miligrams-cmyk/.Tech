// Раздел «Бар»: модель карточек (какие блоки показывать, позиция, прозрачность, блюр, язык и т.д.)
// и управление выпадающим подменю карточки с клавиатуры и мышью.
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root
    required property var menu

    property string subOpenId: ""
    property int subIndex: 0
    property int openIdx: -1
    property bool revert: false

    property real pushY: subOpen ? (subItems.length * 36 + 20) * 1.12 : 0
    Behavior on pushY { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
    Binding { target: root.menu.barLayout; property: "subPush"; value: root.pushY }
    readonly property bool subOpen: subOpenId !== ""

    // карточка, на которой сейчас стоит курсор
    function currentItem() {
        return menu.settingsGrid.model[menu.settingsGrid.currentIndex]
    }

    readonly property var subItems: {
        for (let i = 0; i < barModel.length; i++)
            if (barModel[i].id === subOpenId) return barModel[i].sub || []
        return []
    }

    // раскрывает подменю текущей карточки, false если подменю у неё нет
    function openSub() {
        const it = currentItem()
        if (!it || !it.sub || it.sub.length === 0) return false
        subOpenId = it.id
        subIndex = 0
        openIdx = menu.settingsGrid.currentIndex
        return true
    }

    // закрывает подменю
    function closeSub() { subOpenId = ""; subIndex = 0 }

    // двигает выбор в подменю на d пунктов, по кругу
    function moveSub(d) {
        const n = subItems.length
        if (n > 0) subIndex = (subIndex + d + n) % n
    }

    // применяет выбранный пункт подменю: у шагового крутит значение, у остальных переключает
    function applySub() {
        const s = subItems[subIndex]
        if (!s) return
        if (s.kind === "step") { if (s.loop) s.loop(); else s.step(1) }
        else s.set(!s.get())
    }

    // выбирает пункт под номером i (клавиши 1-9) и сразу применяет
    function applySubAt(i) {
        if (i < 0 || i >= subItems.length) return
        subIndex = i
        applySub()
    }

    // обработка клавиш пока открыто подменю. Возвращает true, если клавишу забрали
    function handleKey(key) {
        if (!subOpen) return key === Qt.Key_Up ? openSub() : false

        let s = subItems[subIndex]
        if (key === Qt.Key_Escape) closeSub()
        else if (key === Qt.Key_Up) moveSub(-1)
        else if (key === Qt.Key_Down || key === Qt.Key_Tab) moveSub(1)
        else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space) applySub()
        else if (key === Qt.Key_Left || key === Qt.Key_Right) {
            if (s && s.kind === "step") s.step(key === Qt.Key_Right ? 1 : -1)
            else closeSub()
        }
        else if (key >= Qt.Key_1 && key <= Qt.Key_9) applySubAt(key - Qt.Key_1)
        return true
    }

    // стрелки вверх/вниз на карточке: с открытым подменю двигают пункты, иначе вверх его открывает
    function stepAlpha(d) {
        if (subOpen) moveSub(d > 0 ? -1 : 1)
        else if (d > 0) openSub()
    }

    Connections {
        target: root.menu.settingsGrid

        // если ушли с карточки при открытом подменю: для шагового пункта крутим значение
        // (и возвращаем курсор на место), иначе просто закрываем подменю
        function onCurrentIndexChanged() {
            if (root.revert || !root.subOpen) return
            const g = root.menu.settingsGrid
            const s = root.subItems[root.subIndex]
            if (s && s.kind === "step" && root.openIdx >= 0 && g.currentIndex !== root.openIdx) {
                const dir = g.currentIndex > root.openIdx ? 1 : -1
                root.revert = true
                g.currentIndex = root.openIdx
                root.revert = false
                s.step(dir)
            } else {
                root.closeSub()
            }
        }
    }

    // обёртка для set у карточек с подменю: если подменю открыто, Enter применяет его пункт, а не саму карточку
    function guard(f) { return v => root.subOpen ? root.applySub() : f(v) }

    // переключает позицию бара на следующую (top/left/right/bottom)
    function cycleBarPos() {
        const order = menu.barLayout.positions
        menu.barLayout.setPosition(order[(order.indexOf(menu.barLayout.position) + 1) % order.length])
    }

    readonly property var barModel: [
        { id: "ws", svg: "workspaces", get: () => menu.showWorkspaces, set: v => menu.showWorkspaces = v },

        { id: "mpris", svg: "player", get: () => menu.showMpris, set: root.guard(v => menu.showMpris = v),
          bs: () => root,
          sub: [
              { id: "lyrics", svg: "lyrics", get: () => menu.barLayout.showLyrics, set: v => menu.barLayout.setShowLyrics(v) },
              { id: "lyricsdot", svg: "lyrics", get: () => menu.barLayout.showLyricsDot, set: v => menu.barLayout.setShowLyricsDot(v) },
              { id: "lyricsautohide", svg: "lyrics", label: menu.lang === "ru" ? "Автоскрытие лирики" : "Lyrics auto-hide",
                get: () => menu.barLayout.lyricsAutoHide, set: v => menu.barLayout.setLyricsAutoHide(v) }
          ] },

        { id: "bt", svg: "bluetooth", get: () => menu.showBluetooth, set: v => menu.showBluetooth = v },
        { id: "center", svg: "center", get: () => menu.showCenterApp, set: v => menu.showCenterApp = v },
        { id: "search", svg: "search", get: () => menu.showSearch, set: v => menu.showSearch = v },
        { id: "stats", svg: "sys", get: () => menu.showSystemStats, set: v => menu.showSystemStats = v },
        { id: "vol", svg: "volume", get: () => menu.showVolume, set: v => menu.showVolume = v },
        { id: "battery", svg: "battery", get: () => menu.showBattery, set: v => menu.showBattery = v },

        { id: "tray", svg: "tray", get: () => menu.showTray, set: root.guard(v => menu.showTray = v),
          bs: () => root,
          sub: [
              { id: "clip", svg: "clipboard", get: () => menu.showClipboard, set: v => menu.showClipboard = v }
          ] },

        { id: "pos", get: () => true, set: root.guard(v => root.cycleBarPos()),
          bs: () => root,
          sub: [
              { id: "autohide", svg: "autohide", get: () => menu.barLayout.autoHide, set: v => menu.barLayout.setAutoHide(v) },
              { id: "solid", svg: "solid", get: () => menu.barLayout.solidBar, set: v => menu.barLayout.setSolidBar(v) },
              { id: "island", svg: "island", get: () => menu.barLayout.island, set: v => menu.barLayout.setIsland(v) },
              { id: "clock12", svg: "clock12", get: () => menu.barLayout.clock12, set: v => menu.barLayout.setClock12(v) }
          ] },

        { id: "alpha", svg: "alpha", get: () => true, set: root.guard(v => menu.barLayout.cycleGlass()),
          bs: () => root,
          sub: [
              { id: "blur", svg: "blur", get: () => menu.blurEnabled, set: v => menu.blurCtl.setBlurEnabled(v) },
              { id: "blurpx", kind: "step", svg: "blurpx", get: () => menu.blurEnabled,
                valueText: () => Math.round(menu.blurStrength * 100) + "%",
                step: d => menu.blurCtl.setBlurStrength(Math.max(0, Math.min(1, menu.blurStrength + d * 0.05))),
                loop: () => menu.blurCtl.setBlurStrength(menu.blurStrength >= 0.99 ? 0 : Math.min(1, menu.blurStrength + 0.05)),
                set: v => menu.blurCtl.cycleBlur() },
              { id: "blurlive", svg: "blur", label: menu.lang === "ru" ? "Живой блюр" : "Live blur",
                get: () => menu.blurLive, set: v => menu.blurCtl.setBlurLive(v) },
              { id: "blurpreload", svg: "blur", label: menu.lang === "ru" ? "Предзагрузка воркспейсов" : "Preload workspaces",
                get: () => menu.blurPreload, set: v => menu.blurCtl.setBlurPreload(v) },
              { id: "cameffect", svg: "blur", label: menu.lang === "ru" ? "Эффект камеры" : "Camera effect",
                get: () => menu.barLayout.camEffect, set: v => menu.barLayout.setCamEffect(v) }
          ] },

        { id: "dnd", svg: "dnd", get: () => menu.doNotDisturb, set: v => menu.doNotDisturb = v },

        { id: "lang", kind: "cycle", svg: "lang", get: () => true,
          valueText: () => menu.lang === "ru" ? "Русский" : "English", set: v => menu.cycleLang() }
    ]
}
