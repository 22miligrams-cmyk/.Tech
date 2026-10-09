// Главное окно настроек на весь экран (оверлей). Внутри хаб: первой идёт пассивная карточка «О шелле»
// (версия, обновление, ссылки), дальше разделы бар, лаунчеры, бинды; шапка, редактор бара и редактор биндов. Фон размывается через LiveBackdrop, меню слегка
// двигается и наклоняется за мышкой (эффект камеры). Вся логика разложена по модулям Sm*,
// здесь только общее состояние и навигация.
import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import "../bar"
import "../panels"
import "../notifications"
import "../common"
import "../lang"

PanelWindow {
    id: settingsMenu

    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary
    required property var barLayout
    property string wallpaper: ""

    property bool showWorkspaces: true
    property bool showMpris: true
    property bool showBluetooth: true
    property bool showCenterApp: true
    property bool showSearch: true
    property bool showSystemStats: true
    property bool showVolume: true
    property bool showBattery: true
    readonly property bool hasBattery: UPower.displayDevice !== null && UPower.displayDevice.ready && UPower.displayDevice.isPresent
    property bool showClipboard: true
    property bool showTray: true

    readonly property var blockEnabled: ({
        ws: showWorkspaces,
        mpris: showMpris,
        bt: showBluetooth,
        app: showCenterApp,
        search: showSearch,
        sys: showSystemStats,
        vol: showVolume,
        battery: showBattery && hasBattery,
        clip: showClipboard,
        tray: showTray
    })

    property string lang: "ru"
    onLangChanged: Tr.lang = lang
    readonly property var langs: Tr.langs

    // перевод ключа на текущий язык
    function tr(key) { return Tr.tr(key) }

    // переключает язык на следующий, сохраняет настройки и пересобирает бинды (у них тоже есть тексты)
    function cycleLang() {
        lang = cycleList(langs, lang)
        storeCtl.save()
        if (bdEnabled) bindsCtl.scheduleApply()
    }

    property bool doNotDisturb: false

    // Updater из Visual.qml: из него карточка «О шелле» берёт версию и статус, а toggleMenu() дёргает тихую проверку
    property var updater: null

    anchors { top: true; bottom: true; left: true; right: true }
    margins { top: 0; bottom: 0; left: 0; right: 0 }

    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "settings-menu"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    visible: false

    property bool blurEnabled: true
    property real blurStrength: 0.5
    readonly property real blurPx: 4 + blurStrength * 56
    readonly property real blurRadius: blurPx
    property bool blurLive: false

    readonly property bool camOn: barLayout.camEffect !== false
    property real camStrength: 1.0
    property real camMoveX: 50
    property real camMoveY: 28
    property real camTilt: 3.5
    readonly property real camTargetX: (camOn && camHover.hovered && width > 0)
        ? clamp01(camHover.point.position.x / width) * 2 - 1 : 0
    readonly property real camTargetY: (camOn && camHover.hovered && height > 0)
        ? clamp01(camHover.point.position.y / height) * 2 - 1 : 0
    property real camX: camTargetX
    property real camY: camTargetY
    Behavior on camX { SmoothedAnimation { velocity: 2.2; maximumEasingTime: 300 } }
    Behavior on camY { SmoothedAnimation { velocity: 2.2; maximumEasingTime: 300 } }

    property bool blurPreload: false
    property real blurDim: 0.12

    readonly property string blurFilePath: (Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")) + "/qs-blur/settings.json"

    SmBlur { id: blurMod; menu: settingsMenu }
    SmStore { id: storeMod; menu: settingsMenu }
    SmHypr { id: hyprMod; menu: settingsMenu }
    SmBinds { id: bindsMod; menu: settingsMenu }
    SmLaunchSettings { id: launchMod; menu: settingsMenu }
    SmBarSettings { id: barMod; menu: settingsMenu }

    property alias blurCtl: blurMod
    property alias storeCtl: storeMod
    property alias hyprCtl: hyprMod
    property alias bindsCtl: bindsMod
    property alias launchCtl: launchMod
    property alias barCtl: barMod
    property alias bindEditor: bindEditorItem
    property alias hubGrid: hubView
    property alias settingsGrid: sectionView

    Component.onCompleted: { blurCtl.load(); storeCtl.load(); hyprCtl.reloadHypr() }

    property string tab: "bar"
    readonly property var tabs: ["bar", "launchers", "binds"]

    // переключает вкладку внутри раздела (по Tab). Для биндов заново читает hyprland.lua
    function setTab(id) {
        if (tab === id) return
        tab = id
        if (id === "binds") hyprCtl.reloadHypr()
        Qt.callLater(() => { settingsGrid.currentIndex = 0; settingsGrid.forceActiveFocus() })
    }

    // следующая вкладка по кругу
    function nextTab() {
        setTab(tabs[(tabs.indexOf(tab) + 1) % tabs.length])
    }

    property int removedAt: -1
    property bool removeSettling: false
    property bool cardsInstant: false
    property string view: "hub"

    readonly property var hubModel: [
        { id: "about",     glyph: "\uf05a" },   // всегда первая
        { id: "bar",       icon: "bar" },
        { id: "launchers", icon: "launchers" },
        { id: "binds",     icon: "binds" }
    ]

    readonly property real hubDepthNear: 255
    readonly property real hubDepthStep: 95
    readonly property real setDepthNear: 182
    readonly property real setDepthStep: 68

    // заходит из хаба в выбранный раздел и ставит фокус на первую карточку
    // Enter / кнопка на карточке «О шелле»: есть новая версия — запустить установщик, иначе тихо перепроверить
    function aboutAction() {
        if (!updater) return
        if (updater.updateAvailable) {
            updater.apply()
            toggleMenu()          // закрываем меню, чтобы был виден терминал
        } else {
            updater.check(false, true)
        }
    }

    function enterSection(id) {
        // «О шелле» — пассивная карточка, отдельного раздела у неё нет
        if (id === "about") { aboutAction(); return }
        tab = id
        if (id === "binds") hyprCtl.reloadHypr()
        view = "section"
        Qt.callLater(() => { settingsGrid.currentIndex = 0; settingsGrid.forceActiveFocus() })
    }

    // возвращает в хаб, фокус на карточке раздела, из которого вышли
    function goHub() {
        view = "hub"
        Qt.callLater(() => { hubGrid.currentIndex = Math.max(0, hubModel.findIndex(m => m.id === tab)); hubGrid.forceActiveFocus() })
    }

    // Esc: из раздела в хаб, из хаба закрыть меню
    function goBack() {
        if (view === "section") goHub()
        else toggleMenu()
    }

    property real lnBlur: 0.5
    property real lnTint: 0.55
    property bool lnIntro: true
    property string lnTerminal: "auto"
    property string wlTransition: "grow"
    property real wlDuration: 1.5

    property string bdMod: "auto"
    property string hyprSrc: ""
    readonly property var bdMods: ["auto", "SUPER", "ALT", "CTRL", "SHIFT"]
    readonly property var parsed: hyprCtl.parseBinds(hyprSrc, bdMod)

    property bool bdEnabled: false
    property var bdKeys: ({ launcher: "D", wall: "W", files: "E" })
    property string bdCapture: ""

    property var bdCustom: []

    readonly property string shellQmlPath: (Quickshell.shellDir || Quickshell.shellRoot || "")
    readonly property string ipcPrefix: "quickshell ipc" + (shellQmlPath ? " -p '" + shellQmlPath + "/shell.qml'" : "")

    property string bdStatus: ""

    readonly property var lnTerminals: ["auto", "kitty", "foot", "alacritty", "wezterm"]
    readonly property var wlTransitions: ["grow", "fade", "wipe", "wave", "outer", "center", "simple", "any"]

    // зажимает число в диапазон 0..1
    function clamp01(v) { return Math.max(0, Math.min(1, v)) }

    // берёт следующий элемент списка после cur, в конце возвращается к началу
    function cycleList(list, cur) { return list[(list.indexOf(cur) + 1) % list.length] }

    // открывает или закрывает меню. При открытии сбрасывает на хаб, запускает анимацию и блюр
    function toggleMenu() {
        if (visible) {
            closeAnim.start()
        } else {
            visible = true
            tab = "bar"
            view = "hub"
            // каждый раз при открытии настроек тихо сверяем версию с GitHub
            if (updater) updater.refresh()
            backdropTimer.stop()
            if (backdropDelay > 0) {
                backdropOn = false
                backdropTimer.restart()
            } else {
                backdropOn = true
            }
            openAnim.start()
            Qt.callLater(() => { hubGrid.currentIndex = 0; hubGrid.forceActiveFocus() })
        }
    }

    property bool backdropOn: false
    property int backdropDelay: 0
    Timer { id: backdropTimer; interval: settingsMenu.backdropDelay; onTriggered: settingsMenu.backdropOn = true }
    readonly property bool blurReady: backdropOn && backdrop.width > 0
    property real blurIn: blurReady ? 1 : 0
    Behavior on blurIn { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

    LiveBackdrop {
        id: backdrop
        screenObj: settingsMenu.screen
        wallpaper: settingsMenu.wallpaper
        autoDetect: false
        active: settingsMenu.visible && settingsMenu.blurEnabled && settingsMenu.backdropOn
        pollInterval: 2000
        liveCapture: settingsMenu.blurLive
        parkOthers: settingsMenu.blurPreload
        texScale: 0.5
        wsDelay: 150
        baseColor: "#14141a"
        x: -width - 64
        y: -height - 64
    }

    BarBlur {
        source: (settingsMenu.blurEnabled && backdrop.width > 0 && settingsMenu.backdropOn) ? backdrop.texture : null
        srcSize: Qt.size(backdrop.width, backdrop.height)
        originX: 0
        originY: 0
        rect: ({ x: 0, y: 0, w: settingsMenu.width, h: settingsMenu.height })
        cornerRadius: 0
        blurRadius: settingsMenu.blurRadius
        tint: Qt.rgba(0, 0, 0, settingsMenu.blurDim)
        strength: Math.min(1, menuContainer.opacity * 2) * settingsMenu.blurIn
    }

    Rectangle {
        anchors.fill: parent
        color: "black"
        visible: !settingsMenu.blurEnabled
        opacity: menuContainer.opacity * 0.5
    }

    Item {
        id: camSurface
        anchors.fill: parent
        HoverHandler { id: camHover }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: settingsMenu.toggleMenu()
    }

    Item {
        id: menuContainer
        anchors.centerIn: parent
        width: parent.width
        height: 500

        scale: 0.0
        opacity: 0.0

        transform: [
            Translate {
                x: -settingsMenu.camX * settingsMenu.camMoveX * settingsMenu.camStrength
                y: -settingsMenu.camY * settingsMenu.camMoveY * settingsMenu.camStrength
            },
            Rotation {
                origin.x: menuContainer.width / 2
                origin.y: menuContainer.height / 2
                axis { x: 0; y: 1; z: 0 }
                angle: settingsMenu.camX * settingsMenu.camTilt * settingsMenu.camStrength
            },
            Rotation {
                origin.x: menuContainer.width / 2
                origin.y: menuContainer.height / 2
                axis { x: 1; y: 0; z: 0 }
                angle: -settingsMenu.camY * settingsMenu.camTilt * settingsMenu.camStrength
            }
        ]

        MouseArea {
            anchors.fill: menuContainer
            onClicked: (mouse) => mouse.accepted = true
        }

        ParallelAnimation {
            id: openAnim
            NumberAnimation { target: menuContainer; property: "scale"; from: 0.88; to: 1.0; duration: 280; easing.type: Easing.OutCubic }
            NumberAnimation { target: menuContainer; property: "opacity"; from: 0.0; to: 1.0; duration: 200; easing.type: Easing.OutCubic }
        }

        ParallelAnimation {
            id: closeAnim
            NumberAnimation { target: menuContainer; property: "scale"; from: 1.0; to: 0.7; duration: 200; easing.type: Easing.InCubic }
            NumberAnimation { target: menuContainer; property: "opacity"; from: 1.0; to: 0.0; duration: 150; easing.type: Easing.InCubic }
            onFinished: { settingsMenu.visible = false; settingsMenu.backdropOn = false }
        }
        ColumnLayout {
            anchors.centerIn: parent
            width: parent.width
            spacing: 25

            SmHeader {
                menu: settingsMenu
                Layout.fillWidth: true
                Layout.preferredWidth: settingsMenu.width
                Layout.maximumWidth: settingsMenu.width
            }

            SmHub { id: hubView; menu: settingsMenu; visible: settingsMenu.view === "hub" }
            SmSection { id: sectionView; menu: settingsMenu; visible: settingsMenu.view === "section" }

            BarEditor {
                Layout.fillWidth: true
                Layout.maximumWidth: 1200
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredHeight: 116
                visible: settingsMenu.view === "section" && settingsMenu.tab === "bar"
                barLayout: settingsMenu.barLayout
                enabledMap: settingsMenu.blockEnabled
                colBg: settingsMenu.colBg
                colAccent: settingsMenu.colAccent
                colText: settingsMenu.colText
                colSecondary: settingsMenu.colSecondary
            }

            Item {
                visible: !(settingsMenu.view === "section" && settingsMenu.tab === "bar")
                Layout.fillWidth: true
                Layout.preferredHeight: 116
            }
        }
    }

    SmBindEditor { id: bindEditorItem; menu: settingsMenu; anchors.fill: parent; z: 200 }
}
