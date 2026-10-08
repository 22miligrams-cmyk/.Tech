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

    readonly property string wallpaperPath: bar.wallpaperPath

    // открыта ли хоть одна панель
    readonly property bool overlayOpen: settingsMenuComp.visible || calendarComp.visible || sysMenuComp.visible
        || volMenuComp.visible || mprisPanelComp.visible || notifCenterComp.visible
        || clipPanelComp.visible || trayPanelComp.visible || btMenuComp.visible || wsOverviewComp.visible
        || lyricsPanelComp.visible
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
        notifCenterComp: notifCenterComp
        clipPanelComp: clipPanelComp
        trayPanelComp: trayPanelComp
        btMenuComp: btMenuComp
        wsOverviewComp: wsOverviewComp
    }

    Calendar {
        id: calendarComp
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

    NotifCenter {
        id: notifCenterComp
        wallpaper: visualRoot.wallpaperPath
        blurEnabled: settingsMenuComp.blurEnabled
        blurRadius: settingsMenuComp.blurPx
        store: visualRoot.notify
        colBg: logic.colBg
        colGlass: logic.colGlass
        colAccent: logic.colAccent
        colText: logic.colText
        colSecondary: logic.colSecondary
    }

    ClipboardPanel {
        id: clipPanelComp
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

    SettingsMenu {
        id: settingsMenuComp
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
                             notifCenterComp, clipPanelComp, trayPanelComp, btMenuComp, wsOverviewComp, altTabComp, lyricsPanelComp]
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
        function notifications(): void { only(notifCenterComp) }
        function clipboard(): void { only(clipPanelComp) }
        function tray(): void { only(trayPanelComp) }
        function bluetooth(): void { only(btMenuComp) }
        function workspaces(): void { only(wsOverviewComp) }
        function settings(): void { only(settingsMenuComp) }

        function alttab(): void { altTabStart(1) }
        function alttabPrev(): void { altTabStart(-1) }
        function alttabCommit(): void { altTabComp.commit() }
        function altTabStart(d): void {
            if (!altTabComp.visible) {
                const all = [settingsMenuComp, calendarComp, sysMenuComp, volMenuComp, mprisPanelComp,
                             notifCenterComp, clipPanelComp, trayPanelComp, btMenuComp, wsOverviewComp, lyricsPanelComp]
                for (const o of all)
                    if (o.visible && !o.isClosing) o.toggleMenu()
            }
            altTabComp.cycle(d)
        }
        function dnd(): void { settingsMenuComp.doNotDisturb = !settingsMenuComp.doNotDisturb }
    }

    // управление обновлениями из терминала: quickshell ipc -p ~/.tech/shell call updater check|status|apply
    IpcHandler {
        target: "updater"

        function check(): void { updaterComp.check(true) }
        function apply(): void { updaterComp.apply() }
        function status(): string { return updaterComp.statusText() }
    }

    Binding { target: visualRoot.notify; property: "wallpaper"; value: visualRoot.wallpaperPath }
    Binding { target: visualRoot.notify; property: "blurEnabled"; value: settingsMenuComp.blurEnabled }
    Binding { target: visualRoot.notify; property: "blurRadius"; value: settingsMenuComp.blurPx * 0.55 }
}
