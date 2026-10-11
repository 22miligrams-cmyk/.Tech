// Visual.qml — корень визуальной части шелла.
// Собирает вместе бар, панели и меню, следит какая панель сейчас открыта
// (overlayOpen / attachedPanel) и даёт общие хелперы: громкость, часы и т.д.
// Данные берёт из Logic.qml.

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.SystemTray
import Quickshell.Services.Mpris
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire

import "notifications"
import "bar"
import "panels"
import "settings"
import "updater"
import "common"
import "icons"
import "assets"
import "lang"

Item {
    id: visualRoot
    required property var logic
    required property var notify

    readonly property bool compact: bar.vertical

    property string wallpaper: Quickshell.env("QS_WALLPAPER") || ""

    // параллакс: общий выключатель + точечные по панелям.
    // parallaxOn = мастер (выкл -> параллакса нет нигде), остальные флаги = отдельные панели:
    //   Mpris / Lyrics - параллакс обложки и текста, Settings / Clip / Tray / Bt / Lock / Ws - эффект камеры (наклон за мышкой), Calendar / Sys / Volume - лёгкий сдвиг содержимого.
    // хранится в ~/.cache/quickshell/parallax.json, переключается из терминала:
    // quickshell ipc -p ~/.tech/shell call shell parallax | parallaxOn | parallaxOff | parallaxToggle <имя>
    // имена: mpris lyrics settings clip tray bt lock calendar sys volume ws
    property bool parallaxOn: true
    property bool parallaxMpris: true
    property bool parallaxLyrics: true
    property bool parallaxSettings: true
    property bool parallaxClip: true
    property bool parallaxTray: true
    property bool parallaxBt: true
    property bool parallaxLock: true
    property bool parallaxCalendar: true
    property bool parallaxSys: true
    property bool parallaxVolume: true
    property bool parallaxWs: true
    property bool parallaxLoaded: false

    readonly property var parallaxKeys: ["Mpris", "Lyrics", "Settings", "Clip", "Tray", "Bt", "Lock", "Calendar", "Sys", "Volume", "Ws"]

    // читает / пишет флаг по имени ("Mpris", "clip" и т.д., регистр не важен)
    function parallaxKey(name) {
        const n = String(name).toLowerCase()
        for (const k of parallaxKeys) if (k.toLowerCase() === n) return k
        return ""
    }
    function parallaxGet(name) { const k = parallaxKey(name); return k ? visualRoot["parallax" + k] : false }
    function parallaxSet(name, v) { const k = parallaxKey(name); if (k) visualRoot["parallax" + k] = v }

    readonly property string parallaxSnapshot: {
        const o = { on: parallaxOn }
        for (const k of parallaxKeys) o[k.toLowerCase()] = visualRoot["parallax" + k]
        return JSON.stringify(o)
    }
    onParallaxSnapshotChanged: if (parallaxLoaded) parallaxStore.setText(parallaxSnapshot)

    FileView {
        id: parallaxStore
        path: Paths.home + "/.cache/quickshell/parallax.json"
        printErrors: false
        atomicWrites: true
        onLoaded: {
            try {
                const o = JSON.parse(parallaxStore.text())
                if (typeof o.on === "boolean") visualRoot.parallaxOn = o.on
                for (const k of visualRoot.parallaxKeys) {
                    const val = o[k.toLowerCase()]
                    if (typeof val === "boolean") visualRoot["parallax" + k] = val
                }
            } catch (e) {}
            visualRoot.parallaxLoaded = true
        }
        onLoadFailed: visualRoot.parallaxLoaded = true
    }

    readonly property string wallpaperPath: bar.wallpaperPath

    // открыта ли хоть одна панель
    readonly property bool overlayOpen: settingsMenuComp.visible || calendarComp.visible || sysMenuComp.visible
        || volMenuComp.visible || mprisPanelComp.visible
        || clipPanelComp.visible || trayPanelComp.visible || btMenuComp.visible || wsOverviewComp.visible
        || lyricsPanelComp.visible || controlCenterComp.visible
    onOverlayOpenChanged: if (overlayOpen) bar.redetectBackdrop()

    readonly property bool blurOn: settingsMenuComp.blurEnabled
    readonly property real blurRadius: settingsMenuComp.blurPx * 0.5
    property color blurTint: Qt.rgba(0.05, 0.05, 0.07, 0.25)

    readonly property bool solid: barLayout.solidBar

    // панель, которая сейчас «приросла» к бару (если такая есть)
    readonly property var attachedPanel: (calendarComp.visible && calendarComp.covers) ? calendarComp
        : (sysMenuComp.visible && sysMenuComp.covers) ? sysMenuComp
        : (volMenuComp.visible && volMenuComp.covers) ? volMenuComp
        : (mprisPanelComp.visible && mprisPanelComp.covers) ? mprisPanelComp
        : (lyricsPanelComp.visible && lyricsPanelComp.covers) ? lyricsPanelComp : null

    Component.onCompleted: {
        SystemTray.isService = true
    }

    PwObjectTracker {
        objects: [Pipewire.defaultAudioSink]
    }

    readonly property var sinkAudio: Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.audio
        ? Pipewire.defaultAudioSink.audio : null
    readonly property int volPercent: sinkAudio ? Math.round(sinkAudio.volume * 100) : 0
    readonly property bool volMuted: sinkAudio ? sinkAudio.muted : false

    function volIcon() {
        if (!sinkAudio || volMuted || sinkAudio.volume <= 0) return "volumeMute"
        if (sinkAudio.volume < 0.34) return "volumeLow"
        if (sinkAudio.volume < 0.67) return "volumeMid"
        return "volume"
    }

    // delta в процентах, при увеличении заодно снимаем mute
    function stepVolume(delta) {
        if (!sinkAudio) return
        sinkAudio.volume = Math.max(0, Math.min(1, sinkAudio.volume + delta / 100))
        if (delta > 0 && sinkAudio.muted) sinkAudio.muted = false
    }

    function toggleVolMute() {
        if (sinkAudio) sinkAudio.muted = !sinkAudio.muted
    }

    function sysAnchor() { return bar.blockAnchor("sys") }
    function volAnchor() { return bar.blockAnchor("vol") }
    function mprisAnchor() { return bar.blockAnchor("mpris") }
    function lyricsAnchor() { return bar.blockAnchor("lyrics") }
    function ccAnchor() { return bar.blockAnchor("notif") }

    readonly property var noRect: ({ x: 0, y: 0, w: 0, h: 0, lo: 0, hi: 0 })

    // строка для часов: чч:мм:сс | дд.мм.гггг (в компактном режиме без года)
    function clockText() {
        const d = logic.currentTime
        const p = n => (n < 10 ? "0" : "") + n
        let h = d.getHours()
        let suffix = ""
        if (barLayout.clock12) {
            suffix = h >= 12 ? " PM" : " AM"
            h = h % 12
            if (h === 0) h = 12
        }
        return p(h) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds()) + suffix
            + "  |  " + p(d.getDate()) + "." + p(d.getMonth() + 1)
            + (visualRoot.compact ? "" : "." + d.getFullYear())
    }

    Binding {
        target: visualRoot.logic
        property: "glassAlpha"
        value: barLayout.glassAlpha
    }

    ClipStore {
        id: clipStore
        watching: settingsMenuComp.showClipboard
    }

    DndSound {
        active: settingsMenuComp.doNotDisturb
    }

    // фоновая проверка обновлений .Tech (логика — в updater/Updater.qml)
    Updater {
        id: updaterComp
        notify: visualRoot.notify
    }

    // кнопка «Обновить» на карточке уведомления -> терминал с установщиком
    Connections {
        target: visualRoot.notify
        function onUpdateRequested() { updaterComp.apply() }
    }

    Binding {
        target: visualRoot.logic
        property: "pollStats"
        value: settingsMenuComp.showSystemStats
    }


    BarLayout {
        id: barLayout
    }

    Binding {
        target: visualRoot.logic
        property: "barPosition"
        value: barLayout.autoHide ? "none" : bar.applied
    }

    Bar {
        id: bar
        visualRoot: visualRoot
        logic: visualRoot.logic
        barLayout: barLayout
        clipStore: clipStore
        ipcShell: ipcShell
        settingsMenuComp: settingsMenuComp
        calendarComp: calendarComp
        sysMenuComp: sysMenuComp
        volMenuComp: volMenuComp
        mprisPanelComp: mprisPanelComp
        lyricsPanelComp: lyricsPanelComp
        lyricsComp: lyricsComp
        notifCenterComp: controlCenterComp   // колокольчик открывает центр управления
        clipPanelComp: clipPanelComp
        trayPanelComp: trayPanelComp
        btMenuComp: btMenuComp
        wsOverviewComp: wsOverviewComp
        controlCenterComp: controlCenterComp
    }

    Calendar {
        id: calendarComp
        parallaxAllowed: visualRoot.parallaxOn && visualRoot.parallaxCalendar
        wallpaper: visualRoot.wallpaperPath
        blurEnabled: settingsMenuComp.blurEnabled
        blurRadius: settingsMenuComp.blurPx * 0.55
        screen: bar.screen
        now: logic.currentTime
        side: bar.applied
        anchorRect: calendarComp.visible ? visualRoot.sysAnchor() : visualRoot.noRect
        colBg: logic.colBg
        colGlass: logic.colGlass
        colAccent: logic.colAccent
        colText: logic.colText
        colSecondary: logic.colSecondary
    }

    SysMonitor {
        id: sysMenuComp
        parallaxAllowed: visualRoot.parallaxOn && visualRoot.parallaxSys
        wallpaper: visualRoot.wallpaperPath
        blurEnabled: settingsMenuComp.blurEnabled
        blurRadius: settingsMenuComp.blurPx * 0.55
        screen: bar.screen
        side: bar.applied
        anchorRect: sysMenuComp.visible ? visualRoot.sysAnchor() : visualRoot.noRect
        colBg: logic.colBg
        colGlass: logic.colGlass
        colAccent: logic.colAccent
        colText: logic.colText
        colSecondary: logic.colSecondary
    }

    VolumePanel {
        id: volMenuComp
        parallaxAllowed: visualRoot.parallaxOn && visualRoot.parallaxVolume
        eq: logic
        wallpaper: visualRoot.wallpaperPath
        blurEnabled: settingsMenuComp.blurEnabled
        blurRadius: settingsMenuComp.blurPx * 0.55
        screen: bar.screen
        side: bar.applied
        anchorRect: volMenuComp.visible ? visualRoot.volAnchor() : visualRoot.noRect
        colBg: logic.colBg
        colGlass: logic.colGlass
        colAccent: logic.colAccent
        colText: logic.colText
        colSecondary: logic.colSecondary
    }

    Lyrics {
        id: lyricsComp
        player: Mpris.players.values.length > 0 ? Mpris.players.values[0] : null
    }

    Binding {
        target: lyricsComp
        property: "wordHighlight"
        value: barLayout.showLyricsDot
    }

    LyricsPanel {
        id: lyricsPanelComp
        lyr: lyricsComp
        parallax: visualRoot.parallaxOn && visualRoot.parallaxLyrics
        wallpaper: visualRoot.wallpaperPath
        blurEnabled: settingsMenuComp.blurEnabled
        blurRadius: settingsMenuComp.blurPx * 0.55
        screen: bar.screen
        side: bar.applied
        anchorRect: lyricsPanelComp.visible ? visualRoot.lyricsAnchor() : visualRoot.noRect
        colBg: logic.colBg
        colGlass: logic.colGlass
        colAccent: logic.colAccent
        colText: logic.colText
        colSecondary: logic.colSecondary
    }

    MprisPanel {
        id: mprisPanelComp
        eq: logic
        parallax: visualRoot.parallaxOn && visualRoot.parallaxMpris
        wallpaper: visualRoot.wallpaperPath
        blurEnabled: settingsMenuComp.blurEnabled
        blurRadius: settingsMenuComp.blurPx * 0.55
        screen: bar.screen
        side: bar.applied
        anchorRect: mprisPanelComp.visible ? visualRoot.mprisAnchor() : visualRoot.noRect
        player: Mpris.players.values.length > 0 ? Mpris.players.values[0] : null
        colBg: logic.colBg
        colGlass: logic.colGlass
        colAccent: logic.colAccent
        colText: logic.colText
        colSecondary: logic.colSecondary
    }

    ClipboardPanel {
        id: clipPanelComp
        parallaxAllowed: visualRoot.parallaxOn && visualRoot.parallaxClip
        barLayout: barLayout
        wallpaper: visualRoot.wallpaperPath
        blurEnabled: settingsMenuComp.blurEnabled
        blurRadius: settingsMenuComp.blurPx
        store: clipStore
        colBg: logic.colBg
        colAccent: logic.colAccent
        colText: logic.colText
        colSecondary: logic.colSecondary
    }

    TrayPanel {
        id: trayPanelComp
        parallaxAllowed: visualRoot.parallaxOn && visualRoot.parallaxTray
        barLayout: barLayout
        wallpaper: visualRoot.wallpaperPath
        blurEnabled: settingsMenuComp.blurEnabled
        blurRadius: settingsMenuComp.blurPx
        colBg: logic.colBg
        colAccent: logic.colAccent
        colText: logic.colText
        colSecondary: logic.colSecondary
    }

    BtMenu {
        id: btMenuComp
        parallaxAllowed: visualRoot.parallaxOn && visualRoot.parallaxBt
        barLayout: barLayout
        wallpaper: visualRoot.wallpaperPath
        blurEnabled: settingsMenuComp.blurEnabled
        blurRadius: settingsMenuComp.blurPx
        colBg: logic.colBg
        colAccent: logic.colAccent
        colText: logic.colText
        colSecondary: logic.colSecondary
    }


    Workspaces {
        id: wsOverviewComp
        parallaxAllowed: visualRoot.parallaxOn && visualRoot.parallaxWs
        screen: bar.screen
        wallpaper: visualRoot.wallpaperPath
        blurEnabled: settingsMenuComp.blurEnabled
        blurRadius: settingsMenuComp.blurPx
        colBg: logic.colBg
        colAccent: logic.colAccent
        colText: logic.colText
        colSecondary: logic.colSecondary
    }

    AltTab {
        id: altTabComp
        wallpaper: visualRoot.wallpaperPath
        blurEnabled: settingsMenuComp.blurEnabled
        blurRadius: settingsMenuComp.blurPx
        colBg: logic.colBg
        colAccent: logic.colAccent
        colText: logic.colText
        colSecondary: logic.colSecondary
    }

    ControlCenter {
        id: controlCenterComp
        screen: bar.screen
        settings: settingsMenuComp
        sink: visualRoot.sinkAudio
        store: notify
        wallpaper: visualRoot.wallpaperPath
        blurEnabled: settingsMenuComp.blurEnabled
        blurRadius: settingsMenuComp.blurPx * 0.55
        side: bar.applied
        anchorRect: controlCenterComp.visible ? visualRoot.ccAnchor() : visualRoot.noRect
        colGlass: logic.colGlass
        colBg: logic.colBg
        colAccent: logic.colAccent
        colText: logic.colText
        colSecondary: logic.colSecondary
    }

    // экран блокировки: IPC-цель "lock" (quickshell ipc -p ~/.tech/shell call lock lock)
    Lock {
        id: lockComp
        store: notify
        parallaxAllowed: visualRoot.parallaxOn && visualRoot.parallaxLock
        barLayout: barLayout
        wallpaper: visualRoot.wallpaperPath
        blurEnabled: settingsMenuComp.blurEnabled
        colBg: logic.colBg
        colGlass: logic.colGlass
        colAccent: logic.colAccent
        colText: logic.colText
        colSecondary: logic.colSecondary
    }

    SettingsMenu {
        id: settingsMenuComp
        updater: updaterComp
        parallax: visualRoot
        barLayout: barLayout
        wallpaper: visualRoot.wallpaperPath
        onDoNotDisturbChanged: visualRoot.notify.doNotDisturb = doNotDisturb
        colBg: logic.colBg
        colAccent: logic.colAccent
        colText: logic.colText
        colSecondary: logic.colSecondary
    }

    IpcHandler {
        id: ipcShell
        target: "shell"

        function only(c): void {
            if (!c.visible) {
                const all = [settingsMenuComp, calendarComp, sysMenuComp, volMenuComp, mprisPanelComp,
                             clipPanelComp, trayPanelComp, btMenuComp, wsOverviewComp, altTabComp, lyricsPanelComp, controlCenterComp]
                for (const o of all)
                    if (o !== c && o.visible && !o.isClosing) o.toggleMenu()
            }
            c.toggleMenu()
        }

        function calendar(): void { only(calendarComp) }
        function sys(): void { only(sysMenuComp) }
        function volume(): void { only(volMenuComp) }
        function player(): void { only(mprisPanelComp) }
        function lyrics(): void { only(lyricsPanelComp) }
        function notifications(): void { only(controlCenterComp) }
        function clipboard(): void { only(clipPanelComp) }
        function tray(): void { only(trayPanelComp) }
        function bluetooth(): void { only(btMenuComp) }
        function workspaces(): void { only(wsOverviewComp) }
        function settings(): void { only(settingsMenuComp) }
        function controlCenter(): void { only(controlCenterComp) }

        function alttab(): void { altTabStart(1) }
        function alttabPrev(): void { altTabStart(-1) }
        function alttabCommit(): void { altTabComp.commit() }
        function altTabStart(d): void {
            if (!altTabComp.visible) {
                const all = [settingsMenuComp, calendarComp, sysMenuComp, volMenuComp, mprisPanelComp,
                             clipPanelComp, trayPanelComp, btMenuComp, wsOverviewComp, lyricsPanelComp, controlCenterComp]
                for (const o of all)
                    if (o.visible && !o.isClosing) o.toggleMenu()
            }
            altTabComp.cycle(d)
        }
        function dnd(): void { settingsMenuComp.doNotDisturb = !settingsMenuComp.doNotDisturb }
        function parallax(): void { visualRoot.parallaxOn = !visualRoot.parallaxOn }
        function parallaxOn(): void { visualRoot.parallaxOn = true }
        function parallaxOff(): void { visualRoot.parallaxOn = false }
        function parallaxToggle(name: string): void { visualRoot.parallaxSet(name, !visualRoot.parallaxGet(name)) }
        function parallaxMpris(): void { visualRoot.parallaxMpris = !visualRoot.parallaxMpris }
        function parallaxLyrics(): void { visualRoot.parallaxLyrics = !visualRoot.parallaxLyrics }
        function parallaxSettings(): void { visualRoot.parallaxSettings = !visualRoot.parallaxSettings }
        function parallaxClip(): void { visualRoot.parallaxClip = !visualRoot.parallaxClip }
        function parallaxTray(): void { visualRoot.parallaxTray = !visualRoot.parallaxTray }
        function parallaxBt(): void { visualRoot.parallaxBt = !visualRoot.parallaxBt }
        function parallaxLock(): void { visualRoot.parallaxLock = !visualRoot.parallaxLock }
        function parallaxCalendar(): void { visualRoot.parallaxCalendar = !visualRoot.parallaxCalendar }
        function parallaxSys(): void { visualRoot.parallaxSys = !visualRoot.parallaxSys }
        function parallaxVolume(): void { visualRoot.parallaxVolume = !visualRoot.parallaxVolume }
        function parallaxWs(): void { visualRoot.parallaxWs = !visualRoot.parallaxWs }
    }

    // управление обновлениями из терминала: quickshell ipc -p ~/.tech/shell call updater check|status|apply|autoOn|autoOff|autoToggle
    IpcHandler {
        target: "updater"

        function check(): void { updaterComp.check(true) }
        function apply(): void { updaterComp.apply() }
        function status(): string { return updaterComp.statusText() }
        function autoOn(): string { updaterComp.setAutoCheck(true); return updaterComp.autoText() }
        function autoOff(): string { updaterComp.setAutoCheck(false); return updaterComp.autoText() }
        function autoToggle(): string { updaterComp.setAutoCheck(!updaterComp.autoCheck); return updaterComp.autoText() }
    }

    Binding { target: visualRoot.notify; property: "wallpaper"; value: visualRoot.wallpaperPath }
    Binding { target: visualRoot.notify; property: "blurEnabled"; value: settingsMenuComp.blurEnabled }
    Binding { target: visualRoot.notify; property: "blurRadius"; value: settingsMenuComp.blurPx * 0.55 }
}
