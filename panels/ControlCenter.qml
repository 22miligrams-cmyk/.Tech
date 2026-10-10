// ControlCenter.qml
//
// Зачем это: центр управления. Панель в общем стиле шелла (как MprisPanel / LyricsPanel):
// стекло + блюр, скругление 6, те же отступы и шрифт. Выезжает справа от края экрана,
// без затемнения; клик мимо или Esc закрывает.
//
// Панель на всю высоту (между краем экрана и баром). Сверху вниз: профиль + выход, ползунки
// громкости и яркости, ряд переключателей (Wi-Fi, Bluetooth, не беспокоить, микрофон),
// список уведомлений (занимает всё свободное место и скроллится), ряд действий
// (замок, сон, перезагрузка, выключение), карточка батареи с профилем питания.
// Замок вызывает наш экран блокировки (Lock.qml) через IPC-цель "lock".
// Уведомления берём из store (Notify.qml): history, removeHistory(), clearHistory(). Открывается кнопкой "cc" в баре или по IPC:
//   quickshell ipc -p ~/.tech/shell call shell controlCenter
//
// Что настоящее: громкость (PipeWire), микрофон (PipeWire), Bluetooth (Quickshell.Bluetooth),
// не беспокоить (settingsMenuComp.doNotDisturb), Wi-Fi (nmcli), яркость (brightnessctl; если его нет - ползунок прячется).
//
// Интерфейс для Visual.qml такой же, как у других панелей: visible, isClosing, toggleMenu().

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import "../bar"
import "../common"
import "../lang"

PanelWindow {
    id: cc

    function t(key, fallback) {
        const v = Tr.tr(key)
        return (!v || v === key) ? fallback : v
    }

    // ---- что приходит снаружи (из Visual.qml) ----
    property var settings: null          // SettingsMenu: оттуда берём doNotDisturb
    property var store: null             // Notify.qml: история уведомлений
    property var sink: null              // visualRoot.sinkAudio (громкость выхода)

    property string side: "bottom"       // где бар: от этого зависит вертикальное положение панели
    property var anchorRect: ({ x: 0, y: 0, w: 0, h: 0, lo: 0, hi: 0 })

    property string wallpaper: ""
    property bool blurEnabled: true
    property real blurRadius: 16
    property color blurTint: Qt.rgba(0.05, 0.05, 0.07, 0.25)

    property color colBg: "#181825"
    property color colAccent: "#a3cef1"
    property color colText: "#e0e1dd"
    property color colSecondary: "#3d5a80"
    property color colDanger: "#f38ba8"
    property color colGlass: Qt.alpha(colBg, 0.6)

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"

    // ---- геометрия ----
    readonly property real pad: 16
    readonly property real cr: 6
    readonly property real gap: 8
    readonly property real pw: 340
    // панель на всю высоту: от края экрана до бара (или с другой стороны, если бар сверху)
    readonly property real availTop: (hasAnchor && side === "top") ? anchorRect.y + anchorRect.h + gap : gap
    readonly property real availBottom: (hasAnchor && side === "bottom") ? anchorRect.y - gap : height - gap
    readonly property real ph: Math.max(300, availBottom - availTop)

    function clamp(v, lo, hi) { return Math.max(lo, Math.min(v, hi)) }

    readonly property bool hasAnchor: anchorRect.w > 0 && anchorRect.h > 0

    // по горизонтали всегда у правого края; если бар справа - встаём вплотную к нему
    readonly property real px: (side === "right" && hasAnchor) ? anchorRect.x - pw - gap : width - pw - gap

    readonly property real py: availTop

    // ---- открытие / закрытие ----
    property bool isClosing: false
    property real p: 0

    function toggleMenu() {
        if (isClosing) return

        if (visible) {
            isClosing = true
            openAnim.stop()
            closeAnim.start()
        } else {
            p = 0
            visible = true
            openAnim.restart()
            refresh()
            Qt.callLater(() => keys.forceActiveFocus())
        }
    }

    function close() { if (visible && !isClosing) toggleMenu() }

    // перечитать состояние того, что узнаём через внешние программы
    function refresh() {
        wifiDev.running = true
        wifiGet.running = true
        brGet.running = true
        osGet.running = true
        chassisGet.running = true
    }

    // ---- окно ----
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    visible: false

    // пока панель открыта, новые уведомления не всплывают поверх неё (сразу падают в историю)
    onVisibleChanged: { if (store) store.centerOpen = visible }

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "control-center"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    LiveBackdrop {
        id: backdrop
        screenObj: cc.screen
        wallpaper: cc.wallpaper
        autoDetect: false
        active: cc.visible && cc.blurEnabled
        roi: Qt.rect(holder.x, holder.y, holder.width, holder.height)
        pollInterval: 700
        texScale: 0.5
        x: -width - 64
        y: -height - 64
    }

    // ---- микрофон: PipeWire отдаёт audio только пока объект отслеживается ----
    PwObjectTracker { objects: [Pipewire.defaultAudioSource] }
    readonly property var micAudio: Pipewire.defaultAudioSource && Pipewire.defaultAudioSource.audio
        ? Pipewire.defaultAudioSource.audio : null
    readonly property bool micMuted: micAudio ? micAudio.muted : false

    // ---- bluetooth: берём первый адаптер, как и плашка в баре ----
    readonly property var btAdapter: Bluetooth.adapters.values.length > 0 ? Bluetooth.adapters.values[0] : null
    readonly property bool btOn: btAdapter ? btAdapter.enabled : false

    // ---- не беспокоить ----
    readonly property bool dndOn: settings ? settings.doNotDisturb : false

    // ---- wi-fi через nmcli ----
    property bool wifiOn: false

    // есть ли wi-fi железо: у любого беспроводного интерфейса в /sys есть папка wireless
    // (так видно и встроенный модуль, и usb-свисток; nmcli для этого не нужен)
    property bool wifiAvail: false

    Process {
        id: wifiDev
        command: ["sh", "-c", "for d in /sys/class/net/*/wireless; do [ -e \"$d\" ] && echo yes && exit; done; echo no"]
        stdout: StdioCollector {
            onStreamFinished: cc.wifiAvail = text.trim() === "yes"
        }
    }

    Process {
        id: wifiGet
        command: ["nmcli", "radio", "wifi"]
        stdout: StdioCollector {
            onStreamFinished: cc.wifiOn = text.trim() === "enabled"
        }
    }

    Process { id: wifiSet }

    // включить/выключить wi-fi; состояние меняем сразу, не ждём nmcli
    function setWifi(on) {
        wifiOn = on
        wifiSet.command = ["nmcli", "radio", "wifi", on ? "on" : "off"]
        wifiSet.running = true
    }

    // ---- яркость через brightnessctl ----
    property real bright: 0.5
    property bool brightAvail: false

    Process {
        id: brGet
        command: ["sh", "-c", "brightnessctl -m -c backlight 2>/dev/null | cut -d, -f4 | tr -d '%'"]
        stdout: StdioCollector {
            onStreamFinished: {
                const v = parseInt(text.trim())
                cc.brightAvail = !isNaN(v)
                if (!isNaN(v)) cc.bright = v / 100
            }
        }
    }

    Process { id: brSet }

    // не дёргаем brightnessctl на каждый пиксель перетаскивания, ставим не чаще раза в 70мс
    Timer {
        id: brApply
        interval: 70
        onTriggered: {
            if (brSet.running) { restart(); return }
            // в ноль не опускаем, чтоб случайно не погасить экран совсем
            brSet.command = ["brightnessctl", "-q", "set", Math.max(1, Math.round(cc.bright * 100)) + "%"]
            brSet.running = true
        }
    }

    function setBright(v) {
        bright = v
        brApply.restart()
    }

    // ---- профиль: имя пользователя и система ----
    property string userName: Quickshell.env("USER") || "user"
    property string osName: ""

    Process {
        id: osGet
        command: ["sh", "-c", ". /etc/os-release 2>/dev/null; echo \"$PRETTY_NAME\""]
        stdout: StdioCollector {
            onStreamFinished: cc.osName = text.trim()
        }
    }

    // ---- ноут или пк ----
    // chassis берём из hostnamectl (laptop / convertible / tablet / desktop ...);
    // если он пустой (виртуалка и т.п.), считаем ноутом то, где есть батарея
    property string chassis: ""

    Process {
        id: chassisGet
        command: ["sh", "-c", "hostnamectl chassis 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: cc.chassis = text.trim()
        }
    }

    readonly property bool isLaptop: ["laptop", "convertible", "tablet", "handset", "watch"].indexOf(chassis) >= 0
        || (chassis === "" && batHasDevice)

    // ---- батарея и профиль питания (UPower / power-profiles-daemon) ----
    readonly property var bat: UPower.displayDevice
    readonly property bool batHasDevice: bat !== null && bat.isPresent
    // на пк батареей может оказаться ибп - такое не показываем
    readonly property bool batAvail: batHasDevice && isLaptop
    readonly property int batPct: batAvail ? Math.round(bat.percentage * 100) : 0
    readonly property bool batCharging: batAvail && bat.state === UPowerDeviceState.Charging
    readonly property bool batFull: batAvail && bat.state === UPowerDeviceState.FullyCharged

    function batText() {
        if (batFull) return t("cc.bat.full", "Заряжена")
        if (batCharging) return t("cc.bat.charging", "Заряжается")
        return t("cc.bat.discharging", "От батареи")
    }

    function batGlyph() {
        if (batCharging) return "\uf0e7"
        if (batPct > 85) return "\uf240"
        if (batPct > 60) return "\uf241"
        if (batPct > 35) return "\uf242"
        if (batPct > 10) return "\uf243"
        return "\uf244"
    }

    // ---- действия: замок, сон, перезагрузка, выключение, выход ----
    Process { id: actProc }

    function run(cmd) {
        actProc.command = cmd
        actProc.running = true
        close()
    }

    // Запустить команду только после того, как панель полностью закрылась и пропала с экрана.
    // Нужно для блокировки: Lock делает снимок экрана (grim) в момент вызова, и если панель ещё
    // открыта или доезжает анимацией, она попадает в кадр, а после разблокировки резко исчезает.
    property var pendingCmd: null
    property int afterCloseDelay: 250   // запас, чтобы композитор успел убрать поверхность (подними, если в кадр ещё попадает хвост)

    function runAfterClose(cmd) {
        if (!visible) {
            actProc.command = cmd
            actProc.running = true
            return
        }
        pendingCmd = cmd
        close()   // если уже закрывается - команда всё равно подхватится в onFinished
    }

    Timer {
        id: afterCloseTimer
        interval: cc.afterCloseDelay
        onTriggered: {
            const c = cc.pendingCmd
            cc.pendingCmd = null
            if (c) {
                actProc.command = c
                actProc.running = true
            }
        }
    }

    // опасные (и не только) действия - только удержанием, как на экране блокировки (Lock.qml)
    property int holdMs: 700             // сколько держать кнопку, чтобы сработало (мс)

    // =====================================================================
    //  Inline-компоненты (тот же приём, что и в Lock.qml: удержание + вода)
    // =====================================================================

    // вода удержания: тот же шейдер WaterFill.frag.qsb, что и в Lock.qml (лежит рядом, в этой же папке)
    component HoldWater: ShaderEffect {
        id: hw
        property real level: 0               // 0..1
        property bool active: false          // идёт удержание: поверхность плещется
        property color fillColor: "#a3cef1"
        property real cornerRadius: 6

        anchors.fill: parent
        visible: level > 0.002
        fragmentShader: Qt.resolvedUrl("WaterFill.frag.qsb")

        property size tileSize: Qt.size(width, height)
        property real time: 0
        property real slosh: active ? 0.25 : 0
        property real radiusPx: cornerRadius
        property real fillAlpha: 0.9
        Behavior on slosh { NumberAnimation { duration: 300 } }

        NumberAnimation on time {
            from: 0
            to: 6.283185307
            duration: 8000
            loops: Animation.Infinite
            running: hw.visible
        }
    }

    // управление удержанием: press() наливает с постоянной скоростью от текущего уровня,
    // release() быстро сливает, дошло до верха - fired() и всё сбрасывается
    component HoldCtl: Item {
        id: hc
        property real hold: 0                // 0..1
        property real duration: 2000
        readonly property bool holding: fillAnim.running
        signal fired()

        function press() {
            if (fillAnim.running) return
            drainAnim.stop()
            fillAnim.duration = Math.max(1, duration * (1 - hold))
            fillAnim.start()
        }

        function release() {
            if (!fillAnim.running) return
            fillAnim.stop()
            drainAnim.restart()
        }

        NumberAnimation {
            id: fillAnim
            target: hc
            property: "hold"
            to: 1
            easing.type: Easing.Linear
            onFinished: { hc.fired(); hc.hold = 0 }
        }

        NumberAnimation {
            id: drainAnim
            target: hc
            property: "hold"
            to: 0
            duration: 350
            easing.type: Easing.OutCubic
        }
    }

    // готовая плитка-кнопка на удержание: прямоугольник + глиф + наполнение водой + MouseArea.
    // Заменяет CcIconTile там, где раньше было подтверждение вторым кликом (armedAct/confirmRun).
    // active/usable добавлены для переключателей (Wi-Fi, Bluetooth, DND, микрофон):
    // active подсвечивает плитку акцентом (вкл/выкл), usable гасит и блокирует удержание
    component HoldTile: Rectangle {
        id: tile
        radius: cc.cr
        property bool active: false
        property bool usable: true
        property string glyph: ""
        property real iconSize: 16
        property color fillColor: cc.colAccent
        signal fired()

        opacity: usable ? 1 : 0.4
        color: tile.active
            ? Qt.alpha(cc.colAccent, mouse.containsMouse ? 0.26 : 0.18)
            : Qt.alpha(cc.colText, mouse.containsMouse ? 0.14 : 0.08)
        Behavior on color { ColorAnimation { duration: 150 } }

        HoldCtl {
            id: hold
            duration: cc.holdMs
            onFired: { if (tile.usable) tile.fired() }
        }

        HoldWater {
            level: hold.hold
            active: hold.holding
            fillColor: tile.fillColor
            cornerRadius: tile.radius
        }

        Text {
            anchors.centerIn: parent
            text: tile.glyph
            color: hold.hold > 0.5 ? cc.colBg : (tile.active ? cc.colAccent : cc.colText)
            font.pixelSize: tile.iconSize
            font.family: cc.fontFamily
            Behavior on color { ColorAnimation { duration: 200 } }
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: tile.usable ? Qt.PointingHandCursor : Qt.ArrowCursor
            onPressed: { if (tile.usable) hold.press() }
            onReleased: hold.release()
            onCanceled: hold.release()
        }
    }

    // ---- интерфейс ----
    Item {
        id: keys
        anchors.fill: parent
        focus: true

        Keys.onEscapePressed: cc.close()

        // клик мимо панели закрывает её (без затемнения, как у остальных панелей)
        MouseArea {
            anchors.fill: parent
            onClicked: cc.close()
        }

        NumberAnimation {
            id: openAnim
            target: cc
            property: "p"
            to: 1
            duration: 420
            easing.type: Easing.OutQuint
        }

        NumberAnimation {
            id: closeAnim
            target: cc
            property: "p"
            to: 0
            duration: 300
            easing.type: Easing.InOutCubic
            onFinished: {
                cc.visible = false
                cc.isClosing = false
                if (cc.pendingCmd) afterCloseTimer.restart()
            }
        }

        // окно-обрезка: тянется от панели до правого края экрана, чтобы панель выезжала именно из-за края
        Item {
            id: holder
            x: cc.px
            y: cc.py
            width: (cc.side === "right" && cc.hasAnchor) ? cc.pw : cc.width - cc.px
            height: cc.ph
            clip: true

            BarBlur {
                source: (cc.blurEnabled && backdrop.width > 0) ? backdrop.texture : null
                srcSize: Qt.size(backdrop.width, backdrop.height)
                originX: holder.x
                originY: holder.y
                rect: ({ x: panel.x, y: panel.y, w: panel.width, h: panel.height })
                corners: Qt.vector4d(cc.cr, cc.cr, cc.cr, cc.cr)
                blurRadius: cc.blurRadius
                tint: cc.blurTint
                strength: panel.opacity
            }

            Rectangle {
                id: panel
                width: cc.pw
                height: cc.ph
                x: (1 - cc.p) * holder.width
                y: 0
                opacity: Math.min(1, cc.p * 1.6)
                radius: cc.cr
                color: cc.colGlass
                border.width: 1
                border.color: Qt.alpha(cc.colText, 0.12)

                // клики по панели не долетают до фона и не закрывают её
                MouseArea {
                    anchors.fill: parent
                    onClicked: (mouse) => mouse.accepted = true
                }

                Column {
                    id: topCol
                    x: cc.pad
                    y: cc.pad
                    width: parent.width - cc.pad * 2
                    spacing: 10

                    // шапка: значок, имя, система, кнопка выхода
                    Item {
                        width: parent.width
                        height: 32

                        Rectangle {
                            id: badge
                            width: 32
                            height: 32
                            radius: cc.cr
                            color: cc.colSecondary

                            Text {
                                anchors.centerIn: parent
                                text: "\uf007"
                                color: cc.colAccent
                                font.pixelSize: 15
                                font.family: cc.fontFamily
                            }
                        }

                        Column {
                            anchors.left: badge.right
                            anchors.leftMargin: 10
                            anchors.right: logoutBtn.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1

                            Text {
                                width: parent.width
                                text: cc.userName
                                color: cc.colText
                                font.pixelSize: 13
                                font.bold: true
                                font.family: cc.fontFamily
                                elide: Text.ElideRight
                            }

                            Text {
                                width: parent.width
                                text: cc.osName
                                visible: text !== ""
                                color: Qt.alpha(cc.colText, 0.5)
                                font.pixelSize: 10
                                font.family: cc.fontFamily
                                elide: Text.ElideRight
                            }
                        }

                        HoldTile {
                            id: logoutBtn
                            anchors.right: parent.right
                            width: 32
                            height: 32
                            glyph: "\uf08b"
                            iconSize: 14
                            fillColor: cc.colDanger
                            onFired: cc.run(["hyprctl", "dispatch", "exit"])
                        }
                    }

                    // блок 1: ползунки
                    CcCard {
                        width: parent.width
                        cr: cc.cr
                        colText: cc.colText

                        Column {
                            width: parent.width
                            spacing: 10

                    CcSlider {
                        width: parent.width
                        glyph: cc.sink && (cc.sink.muted || cc.sink.volume <= 0) ? "\uf026" : "\uf028"
                        value: cc.sink ? cc.sink.volume : 0
                        dimmed: cc.sink ? cc.sink.muted : false
                        usable: cc.sink !== null
                        colAccent: cc.colAccent
                        colText: cc.colText
                        radius: cc.cr
                        onMoved: (v) => {
                            if (!cc.sink) return
                            cc.sink.volume = v
                            if (v > 0 && cc.sink.muted) cc.sink.muted = false
                        }
                        onGlyphClicked: { if (cc.sink) cc.sink.muted = !cc.sink.muted }
                    }

                    CcSlider {
                        width: parent.width
                        visible: cc.brightAvail && cc.isLaptop
                        height: visible ? 22 : 0
                        glyph: "\uf185"
                        value: cc.bright
                        colAccent: cc.colAccent
                        colText: cc.colText
                        radius: cc.cr
                        onMoved: (v) => cc.setBright(v)
                    }

                        }
                    }

                    // блок 2: переключатели
                    CcCard {
                        width: parent.width
                        cr: cc.cr
                        colText: cc.colText

                    Row {
                        id: toggles
                        // ячейки несут зазор внутри себя, поэтому ряд чуть шире и сдвинут на ползазора
                        x: -3
                        width: parent.width + 6
                        spacing: 0
                        readonly property int count: 1 + (cc.wifiAvail ? 1 : 0) + (cc.btAdapter !== null ? 1 : 0) + (cc.micAudio !== null ? 1 : 0)
                        readonly property real slot: width / count

                        CcSlot {
                            shown: cc.wifiAvail
                            full: toggles.slot

                            HoldTile {
                                anchors.fill: parent
                                glyph: "\uf1eb"
                                active: cc.wifiOn
                                fillColor: cc.colAccent
                                onFired: cc.setWifi(!cc.wifiOn)
                            }
                        }

                        CcSlot {
                            shown: cc.btAdapter !== null
                            full: toggles.slot

                            HoldTile {
                                anchors.fill: parent
                                glyph: "\uf293"
                                active: cc.btOn
                                usable: cc.btAdapter !== null
                                fillColor: cc.colAccent
                                onFired: { if (cc.btAdapter) cc.btAdapter.enabled = !cc.btAdapter.enabled }
                            }
                        }

                        CcSlot {
                            full: toggles.slot

                            HoldTile {
                                anchors.fill: parent
                                glyph: cc.dndOn ? "\uf1f6" : "\uf0f3"
                                active: cc.dndOn
                                fillColor: cc.colAccent
                                onFired: { if (cc.settings) cc.settings.doNotDisturb = !cc.settings.doNotDisturb }
                            }
                        }

                        CcSlot {
                            shown: cc.micAudio !== null
                            full: toggles.slot

                            HoldTile {
                                anchors.fill: parent
                                glyph: cc.micMuted ? "\uf131" : "\uf130"
                                active: cc.micAudio !== null && !cc.micMuted
                                usable: cc.micAudio !== null
                                fillColor: cc.colAccent
                                onFired: { if (cc.micAudio) cc.micAudio.muted = !cc.micAudio.muted }
                            }
                        }
                    }

                    }
                }

                // ---- уведомления: занимают всё место между верхним и нижним блоками ----
                CcCard {
                    id: notifArea
                    cr: cc.cr
                    colText: cc.colText
                    x: cc.pad
                    width: parent.width - cc.pad * 2
                    anchors.top: topCol.bottom
                    anchors.topMargin: 10
                    anchors.bottom: bottomCol.top
                    anchors.bottomMargin: 10

                    readonly property int count: cc.store ? cc.store.history.count : 0

                    // шапка списка: заголовок + кнопка "Очистить"
                    Item {
                        id: nHead
                        width: parent.width
                        height: 26

                        Text {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: cc.t("cc.notifs", "Уведомления") + (notifArea.count > 0 ? "  " + notifArea.count : "")
                            color: Qt.alpha(cc.colText, 0.7)
                            font.pixelSize: 11
                            font.bold: true
                            font.family: cc.fontFamily
                        }

                        Rectangle {
                            id: clearBtn
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: notifArea.count > 0
                            width: clearTxt.implicitWidth + 20
                            height: 24
                            radius: cc.cr
                            color: Qt.alpha(cc.colText, clearMa.containsMouse ? 0.18 : 0.10)

                            Behavior on color { ColorAnimation { duration: 150 } }

                            Text {
                                id: clearTxt
                                anchors.centerIn: parent
                                text: "\uf00d  " + cc.t("notif.clear", "Очистить")
                                color: cc.colText
                                font.pixelSize: 10
                                font.family: cc.fontFamily
                            }

                            MouseArea {
                                id: clearMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { if (cc.store) cc.store.clearHistory() }
                            }
                        }
                    }

                    // линия под шапкой списка
                    Rectangle {
                        id: nDiv
                        anchors.top: nHead.bottom
                        anchors.topMargin: 4
                        width: parent.width
                        height: 1
                        color: Qt.alpha(cc.colText, 0.10)
                    }

                    // заглушка, когда пусто
                    Column {
                        anchors.centerIn: parent
                        spacing: 8
                        visible: notifArea.count === 0
                        opacity: 0.5

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "\uf1f6"
                            color: cc.colAccent
                            font.pixelSize: 22
                            font.family: cc.fontFamily
                        }

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: cc.t("notif.empty", "Нет уведомлений")
                            color: cc.colText
                            font.pixelSize: 11
                            font.family: cc.fontFamily
                        }
                    }

                    ListView {
                        id: nList
                        anchors.top: nDiv.bottom
                        anchors.topMargin: 8
                        anchors.bottom: parent.bottom
                        width: parent.width
                        clip: true
                        spacing: 6
                        boundsBehavior: Flickable.StopAtBounds
                        model: cc.store ? cc.store.history : null

                        remove: Transition {
                            ParallelAnimation {
                                NumberAnimation { property: "opacity"; to: 0; duration: 160 }
                                NumberAnimation { property: "x"; to: nList.width / 2; duration: 160; easing.type: Easing.InCubic }
                            }
                        }
                        displaced: Transition {
                            NumberAnimation { property: "y"; duration: 200; easing.type: Easing.OutCubic }
                        }

                        delegate: Rectangle {
                            id: card

                            required property int uid
                            required property string appName
                            required property string summary
                            required property string body
                            required property string timeText

                            width: nList.width
                            height: cardCol.implicitHeight + 20
                            radius: cc.cr
                            color: Qt.alpha(cc.colText, cardMa.containsMouse ? 0.15 : 0.09)

                            Behavior on color { ColorAnimation { duration: 150 } }

                            // клик по карточке = прочитано; объявлен первым, крестик выше него
                            MouseArea {
                                id: cardMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { if (cc.store) cc.store.removeHistory(card.uid) }
                            }

                            Column {
                                id: cardCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: 10
                                spacing: 3

                                Row {
                                    width: parent.width
                                    spacing: 6

                                    Rectangle {
                                        width: 6
                                        height: 6
                                        radius: 2
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: cc.colAccent
                                    }

                                    Text {
                                        width: parent.width - 6 - 6 - timeLbl.implicitWidth - 6 - 6
                                        text: card.appName
                                        color: cc.colAccent
                                        font.pixelSize: 10
                                        font.bold: true
                                        font.family: cc.fontFamily
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        id: timeLbl
                                        text: card.timeText
                                        color: Qt.alpha(cc.colText, 0.5)
                                        font.pixelSize: 9
                                        font.family: cc.fontFamily
                                    }
                                }

                                Text {
                                    width: parent.width
                                    visible: text !== ""
                                    text: card.summary
                                    color: cc.colText
                                    font.pixelSize: 11
                                    font.bold: true
                                    font.family: cc.fontFamily
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
                                }

                                Text {
                                    width: parent.width
                                    visible: text !== ""
                                    text: card.body
                                    color: Qt.alpha(cc.colText, 0.7)
                                    font.pixelSize: 10
                                    font.family: cc.fontFamily
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 3
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }

                // ---- низ: действия + батарея, прижаты к нижнему краю ----
                Column {
                    id: bottomCol
                    x: cc.pad
                    width: parent.width - cc.pad * 2
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: cc.pad
                    spacing: 10

                    // блок: действия
                    CcCard {
                        width: parent.width
                        cr: cc.cr
                        colText: cc.colText

                    Row {
                        id: actions
                        width: parent.width
                        spacing: 6
                        readonly property real cell: (width - spacing * 3) / 4

                        HoldTile {
                            width: actions.cell
                            height: actions.cell
                            glyph: "\uf023"
                            fillColor: cc.colAccent
                            onFired: cc.runAfterClose(["sh", "-c", "quickshell ipc -p ~/.tech/shell call lock lock"])
                        }

                        HoldTile {
                            width: actions.cell
                            height: actions.cell
                            glyph: "\uf186"
                            fillColor: cc.colAccent
                            onFired: cc.run(["systemctl", "suspend"])
                        }

                        HoldTile {
                            width: actions.cell
                            height: actions.cell
                            glyph: "\uf021"
                            fillColor: cc.colDanger
                            onFired: cc.run(["systemctl", "reboot"])
                        }

                        HoldTile {
                            width: actions.cell
                            height: actions.cell
                            glyph: "\uf011"
                            fillColor: cc.colDanger
                            onFired: cc.run(["systemctl", "poweroff"])
                        }
                    }
                    }

                    // батарея + профиль питания (на десктопе без батареи не показывается)
                    CcCard {
                        width: parent.width
                        height: cc.batAvail ? 54 : 0
                        visible: cc.batAvail
                        inset: 8
                        cr: cc.cr
                        colText: cc.colText

                        Row {
                            anchors.left: parent.left
                            anchors.leftMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 10

                            Text {
                                width: 20
                                horizontalAlignment: Text.AlignHCenter
                                anchors.verticalCenter: parent.verticalCenter
                                text: cc.batGlyph()
                                color: (!cc.batCharging && cc.batPct <= 15) ? cc.colDanger : cc.colAccent
                                font.pixelSize: 17
                                font.family: cc.fontFamily
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1

                                Text {
                                    text: cc.batPct + "%"
                                    color: cc.colText
                                    font.pixelSize: 13
                                    font.bold: true
                                    font.family: cc.fontFamily
                                }

                                Text {
                                    text: cc.batText()
                                    color: Qt.alpha(cc.colText, 0.5)
                                    font.pixelSize: 10
                                    font.family: cc.fontFamily
                                }
                            }
                        }

                        // профили: экономия / баланс / производительность
                        Row {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 4
                            visible: PowerProfiles.hasPerformanceProfile !== undefined

                            Repeater {
                                model: [
                                    { g: "\uf06c", p: PowerProfile.PowerSaver },
                                    { g: "\uf24e", p: PowerProfile.Balanced },
                                    { g: "\uf0e4", p: PowerProfile.Performance }
                                ]

                                delegate: CcIconTile {
                                    required property var modelData
                                    width: 36
                                    height: 36
                                    baseAlpha: 0.10
                                    glyph: modelData.g
                                    iconSize: 14
                                    active: PowerProfiles.profile === modelData.p
                                    usable: modelData.p !== PowerProfile.Performance || PowerProfiles.hasPerformanceProfile
                                    colAccent: cc.colAccent
                                    colText: cc.colText
                                    onClicked: PowerProfiles.profile = modelData.p
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
