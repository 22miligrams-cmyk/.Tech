import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../bar"
import "../panels"
import "../notifications"
import "../settings"
import "../common"
import "../lang"

PanelWindow {
    id: wsMenu

    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary

    property string wallpaper: ""
    property bool blurEnabled: true
    property real blurRadius: 20
    property real blurDim: 0.28

    property bool liveThumbs: false

    property bool isClosing: false
    property real reveal: 0.0
    property int selected: 1
    property int dropWs: -1

    readonly property int count: 9
    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"

    readonly property var mon: screen ? Hyprland.monitorFor(screen) : null
    readonly property real lw: mon && mon.scale > 0 ? mon.width / mon.scale : Math.max(1, width)
    readonly property real lh: mon && mon.scale > 0 ? mon.height / mon.scale : Math.max(1, height)
    readonly property var reservedArr: (mon && mon.lastIpcObject && mon.lastIpcObject.reserved) ? mon.lastIpcObject.reserved : [0, 0, 0, 0]
    // берём пропорции рабочей области (без бара), не всего монитора — тогда по краям сцены нет лишних полос
    readonly property real aspect: Math.max(1, lw - reservedArr[0] - reservedArr[2]) / Math.max(1, lh - reservedArr[1] - reservedArr[3])

    readonly property real stripGap: 10
    readonly property real stripCardW: Math.max(40, Math.min(190, (width * 0.9 - (count - 1) * stripGap) / count))
    readonly property real stripCardH: stripCardW / aspect
    readonly property real stripW: count * stripCardW + (count - 1) * stripGap
    readonly property real stripX: (width - stripW) / 2

    readonly property real headGap: 30
    readonly property real headH: 44
    readonly property real stageMaxH: Math.max(60, height - stripCardH - headGap - headH - 150)
    readonly property real stageW: Math.max(80, Math.min(width * 0.82, stageMaxH * aspect))
    readonly property real stageH: stageW / aspect
    readonly property real stageX: (width - stageW) / 2

    readonly property real blockH: stripCardH + headGap + headH + stageH
    readonly property real stripY: Math.max(20, (height - blockH - 30) / 2)
    readonly property real stageTop: stripY + stripCardH + headGap + headH

    function stripCardX(id) { return stripX + (id - 1) * (stripCardW + stripGap) }

    function stripAt(px, py) {
        if (py < stripY - 14 || py > stripY + stripCardH + 14) return -1
        const i = Math.floor((px - stripX + stripGap / 2) / (stripCardW + stripGap))
        return (i < 0 || i >= count) ? -1 : i + 1
    }

    // рабочая область монитора (без зон, которые занял бар), вписанная
    // в бокс W x H с одинаковым масштабом и по центру.
    function fit(m, W, H) {
        const r = (m && m.lastIpcObject && m.lastIpcObject.reserved) ? m.lastIpcObject.reserved : [0, 0, 0, 0]
        const sc = m && m.scale > 0 ? m.scale : 1
        const mw = m ? m.width / sc : lw
        const mh = m ? m.height / sc : lh
        const x0 = (m ? m.x : 0) + r[0]
        const y0 = (m ? m.y : 0) + r[1]
        const w = Math.max(1, mw - r[0] - r[2])
        const h = Math.max(1, mh - r[1] - r[3])
        const k = Math.min(W / w, H / h)
        return { k: k, x0: x0, y0: y0, ox: (W - w * k) / 2, oy: (H - h * k) / 2 }
    }

    function winCount(id) {
        let n = 0
        const v = Hyprland.toplevels.values
        for (let i = 0; i < v.length; i++) {
            const w = v[i].workspace
            if (w && w.id === id) n++
        }
        return n
    }

    function t(key, fallback) {
        const v = Tr.tr(key)
        return (v === undefined || v === null || v === "" || v === key) ? fallback : v
    }

    function fullAddr(a) {
        const s = String(a)
        return s.indexOf("0x") === 0 ? s : "0x" + s
    }

    function switchTo(id) {
        Hyprland.dispatch('hl.dsp.focus({ workspace = "' + id + '" })')
        close()
    }

    function focusWin(addr) {
        Hyprland.dispatch('hl.dsp.focus({ window = "address:' + fullAddr(addr) + '" })')
        close()
    }

    function moveWin(addr, id) {
        Hyprland.dispatch('hl.dsp.window.move({ workspace = "' + id + '", follow = false, window = "address:' + fullAddr(addr) + '" })')
        refreshTimer.restart()
    }

    function step(d) {
        selected = Math.max(1, Math.min(count, selected + d))
    }

    function close() {
        if (visible && !isClosing) closeAnim.start()
    }

    function toggleMenu() {
        if (visible) {
            close()
            return
        }
        Hyprland.refreshWorkspaces()
        Hyprland.refreshMonitors()
        Hyprland.refreshToplevels()
        const f = Hyprland.focusedWorkspace
        selected = f && f.id >= 1 && f.id <= count ? f.id : 1
        dropWs = -1
        visible = true
        openAnim.start()
        Qt.callLater(() => keyItem.forceActiveFocus())
    }
    Timer {
        id: refreshTimer
        interval: 160
        onTriggered: Hyprland.refreshToplevels()
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    margins { top: 0; bottom: 0; left: 0; right: 0 }

    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "workspaces-overview"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    visible: false

    NumberAnimation { id: openAnim; target: wsMenu; property: "reveal"; from: 0.0; to: 1.0; duration: 260; easing.type: Easing.OutCubic }
    SequentialAnimation {
        id: closeAnim
        onStarted: wsMenu.isClosing = true
        NumberAnimation { target: wsMenu; property: "reveal"; to: 0.0; duration: 170; easing.type: Easing.InCubic }
        ScriptAction { script: { wsMenu.visible = false; wsMenu.isClosing = false } }
    }

    LiveBackdrop {
        id: backdrop
        screenObj: wsMenu.screen
        wallpaper: wsMenu.wallpaper
        autoDetect: false
        active: wsMenu.visible && wsMenu.blurEnabled
        pollInterval: 500
        liveCapture: false
        parkOthers: false
        texScale: 0.5
        baseColor: "#14141a"
        x: -width - 64
        y: -height - 64
    }

    BarBlur {
        source: (wsMenu.blurEnabled && backdrop.width > 0) ? backdrop.texture : null
        srcSize: Qt.size(backdrop.width, backdrop.height)
        originX: 0
        originY: 0
        rect: ({ x: 0, y: 0, w: wsMenu.width, h: wsMenu.height })
        cornerRadius: 0
        blurRadius: wsMenu.blurRadius
        tint: Qt.rgba(0, 0, 0, wsMenu.blurDim)
        strength: wsMenu.reveal
    }
    Rectangle {
        anchors.fill: parent
        color: "black"
        visible: !wsMenu.blurEnabled
        opacity: wsMenu.reveal * 0.6
    }

    MouseArea {
        anchors.fill: parent
        onClicked: wsMenu.close()
    }

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: (event) => {
            const d = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x
            wsMenu.step(d > 0 ? -1 : 1)
            event.accepted = true
        }
    }

    Item {
        id: keyItem
        anchors.fill: parent
        focus: true

        Keys.onPressed: (e) => {
            e.accepted = true
            if (e.key === Qt.Key_Escape) wsMenu.close()
            else if (e.key >= Qt.Key_1 && e.key <= Qt.Key_9) wsMenu.switchTo(e.key - Qt.Key_0)
            else if (e.key === Qt.Key_Left || e.key === Qt.Key_Up) wsMenu.step(-1)
            else if (e.key === Qt.Key_Right || e.key === Qt.Key_Down) wsMenu.step(1)
            else if (e.key === Qt.Key_Tab) wsMenu.selected = wsMenu.selected % wsMenu.count + 1
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) wsMenu.switchTo(wsMenu.selected)
            else e.accepted = false
        }
    }

    Item {
        id: ui
        width: parent.width
        height: parent.height
        y: (1 - wsMenu.reveal) * 16
        opacity: wsMenu.reveal

        Repeater {
            model: wsMenu.count

            delegate: Rectangle {
                id: card

                required property int index
                readonly property int wsId: index + 1
                readonly property bool focusedWs: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id === wsId : false
                readonly property bool isSel: wsMenu.selected === wsId
                readonly property bool isDrop: wsMenu.dropWs === wsId
                readonly property int n: wsMenu.winCount(wsId)
                readonly property real mw: wsMenu.lw

                x: wsMenu.stripCardX(wsId)
                y: wsMenu.stripY - (isSel ? 5 : 0)
                width: wsMenu.stripCardW
                height: wsMenu.stripCardH
                radius: 6
                z: 1

                color: isDrop ? Qt.alpha(wsMenu.colAccent, 0.3)
                     : (n > 0 ? "transparent"
                              : Qt.alpha(isSel ? wsMenu.colSecondary : wsMenu.colBg, isSel ? 0.95 : 0.5))
                opacity: (n === 0 && !isSel && !isDrop) ? 0.55 : 1.0

                Behavior on y { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: 150 } }
                Behavior on opacity { NumberAnimation { duration: 150 } }

                Repeater {
                    model: Hyprland.toplevels

                    delegate: Item {
                        id: mini
                        required property var modelData

                        readonly property var ipc: modelData.lastIpcObject || ({})
                        readonly property var wm: modelData.monitor ? modelData.monitor : wsMenu.mon
                        readonly property var ft: wsMenu.fit(wm, card.width, card.height)
                        readonly property bool ok: modelData.workspace && modelData.workspace.id === card.wsId
                            && ipc.at !== undefined && ipc.size !== undefined && ipc.mapped !== false && ipc.hidden !== true

                        visible: ok
                        x: ok ? Math.max(0, ft.ox + (ipc.at[0] - ft.x0) * ft.k) : 0
                        y: ok ? Math.max(0, ft.oy + (ipc.at[1] - ft.y0) * ft.k) : 0
                        width: ok ? Math.max(4, Math.min(ipc.size[0] * ft.k, card.width - x)) : 0
                        height: ok ? Math.max(4, Math.min(ipc.size[1] * ft.k, card.height - y)) : 0

                        Item {
                            anchors.fill: parent
                            layer.enabled: true
                            layer.effect: MultiEffect {
                                maskEnabled: true
                                maskSource: miniMask
                                maskThresholdMin: 0.5
                                maskSpreadAtMin: 1.0
                            }

                            Rectangle {
                                anchors.fill: parent
                                color: thumbCopy.hasContent ? "transparent"
                                     : (mini.modelData.activated ? Qt.alpha(wsMenu.colAccent, 0.55) : Qt.alpha(wsMenu.colText, 0.22))
                            }

                            ScreencopyView {
                                id: thumbCopy
                                anchors.fill: parent
                                captureSource: (wsMenu.visible && mini.ok) ? mini.modelData.wayland : null
                                live: wsMenu.liveThumbs
                                paintCursor: false
                                visible: hasContent
                            }
                        }

                        Rectangle {
                            id: miniMask
                            anchors.fill: parent
                            radius: 6
                            visible: false
                            layer.enabled: true
                        }
                    }
                }

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: parent.height + 5
                    width: parent.width * 0.5
                    height: 3
                    radius: 1.5
                    color: wsMenu.colAccent
                    opacity: card.isSel ? 1.0 : (card.focusedWs ? 0.4 : 0.0)
                    Behavior on opacity { NumberAnimation { duration: 150 } }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: wsMenu.selected = card.wsId
                    onClicked: wsMenu.switchTo(card.wsId)
                }
            }
        }
        Row {
            x: wsMenu.stageX + 4
            y: wsMenu.stageTop - wsMenu.headH + 4
            spacing: 12

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                    text: wsMenu.t("ws.title", "Рабочий стол") + " " + wsMenu.selected
                    color: wsMenu.colText
                    font.pixelSize: 14
                    font.bold: true
                    font.family: wsMenu.fontFamily
                }

                Text {
                    text: wsMenu.t("ws.windows", "Окон") + ": " + wsMenu.winCount(wsMenu.selected)
                    color: wsMenu.colText
                    opacity: 0.55
                    font.pixelSize: 11
                    font.family: wsMenu.fontFamily
                }
            }
        }

        Rectangle {
            id: stage
            x: wsMenu.stageX
            y: wsMenu.stageTop
            width: wsMenu.stageW
            height: wsMenu.stageH
            radius: 6
            color: Qt.alpha(wsMenu.colBg, 0.5)

            Column {
                anchors.centerIn: parent
                spacing: 6
                visible: wsMenu.winCount(wsMenu.selected) === 0

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: wsMenu.t("ws.empty", "Пустой стол")
                    color: wsMenu.colText
                    opacity: 0.5
                    font.pixelSize: 16
                    font.bold: true
                    font.family: wsMenu.fontFamily
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: wsMenu.switchTo(wsMenu.selected)
            }
        }

        Repeater {
            model: Hyprland.toplevels

            delegate: Item {
                id: win

                required property var modelData

                readonly property var ipc: modelData.lastIpcObject || ({})
                readonly property int wsId: modelData.workspace ? modelData.workspace.id : -1
                readonly property var wm: modelData.monitor ? modelData.monitor : wsMenu.mon
                readonly property var ft: wsMenu.fit(wm, wsMenu.stageW, wsMenu.stageH)
                readonly property bool valid: wsId >= 1 && wsId <= wsMenu.count
                    && ipc.at !== undefined && ipc.size !== undefined
                    && ipc.mapped !== false && ipc.hidden !== true
                readonly property bool onStage: valid && wsId === wsMenu.selected

                readonly property real bx: valid ? Math.max(0, ft.ox + (ipc.at[0] - ft.x0) * ft.k) : 0
                readonly property real by: valid ? Math.max(0, ft.oy + (ipc.at[1] - ft.y0) * ft.k) : 0
                readonly property real baseX: wsMenu.stageX + bx
                readonly property real baseY: wsMenu.stageTop + by

                property real dx: 0
                property real dy: 0
                property bool drag: false
                property bool leaving: false

                width: valid ? Math.max(14, Math.min(ipc.size[0] * ft.k, wsMenu.stageW - bx)) : 0
                height: valid ? Math.max(12, Math.min(ipc.size[1] * ft.k, wsMenu.stageH - by)) : 0
                x: baseX + dx
                y: baseY + dy
                z: drag ? 200 : 10

                opacity: leaving ? 0.0 : (onStage ? (drag ? 0.92 : 1.0) : 0.0)
                visible: valid && opacity > 0.01
                scale: leaving ? 0.25 : (!onStage ? 0.96 : (drag ? 1.04 : (ma.containsMouse ? 1.012 : 1.0)))

                Behavior on dx { enabled: !win.drag; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                Behavior on dy { enabled: !win.drag; NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                Behavior on opacity { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
                Behavior on scale { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }

                onWsIdChanged: {
                    leaving = false
                    pendTimer.stop()
                    dx = 0
                    dy = 0
                }

                Timer {
                    id: pendTimer
                    interval: 900
                    onTriggered: { win.leaving = false; win.dx = 0; win.dy = 0 }
                }

                Rectangle {
                    z: -1
                    anchors.fill: parent
                    anchors.topMargin: win.drag ? 8 : 3
                    anchors.bottomMargin: win.drag ? -8 : -3
                    radius: 6
                    color: "black"
                    opacity: win.drag ? 0.4 : 0.22
                }

                Item {
                    anchors.fill: parent
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        maskEnabled: true
                        maskSource: winMask
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: Qt.alpha(wsMenu.colSecondary, 0.95)

                        Image {
                            id: appIcon
                            anchors.centerIn: parent
                            width: Math.min(64, Math.min(parent.width, parent.height) * 0.4)
                            height: width
                            sourceSize: Qt.size(96, 96)
                            source: Quickshell.iconPath(String(win.ipc["class"] || "").toLowerCase(), true)
                            visible: status === Image.Ready
                            fillMode: Image.PreserveAspectFit
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: !appIcon.visible
                            text: String(win.ipc["class"] || win.modelData.title || "?").charAt(0).toUpperCase()
                            color: wsMenu.colAccent
                            font.pixelSize: Math.max(12, Math.min(parent.width, parent.height) * 0.35)
                            font.bold: true
                            font.family: wsMenu.fontFamily
                        }
                    }

                    ScreencopyView {
                        anchors.fill: parent
                        captureSource: (wsMenu.visible && win.onStage) ? win.modelData.wayland : null
                        live: wsMenu.liveThumbs
                        paintCursor: false
                        visible: hasContent
                    }
                }

                Rectangle {
                    id: winMask
                    anchors.fill: parent
                    radius: 6
                    visible: false
                    layer.enabled: true
                }

                Rectangle {
                    visible: ma.containsMouse && !win.drag
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.margins: 8
                    height: 22
                    width: Math.min(parent.width - 16, titleTxt.implicitWidth + 16)
                    radius: 6
                    color: Qt.alpha(wsMenu.colBg, 0.92)

                    Text {
                        id: titleTxt
                        anchors.centerIn: parent
                        width: parent.width - 12
                        elide: Text.ElideRight
                        text: win.modelData.title || String(win.ipc["class"] || "")
                        color: wsMenu.colText
                        font.pixelSize: 10
                        font.family: wsMenu.fontFamily
                    }
                }

                MouseArea {
                    id: ma
                    anchors.fill: parent
                    enabled: win.onStage
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton
                    cursorShape: win.drag ? Qt.ClosedHandCursor : Qt.PointingHandCursor

                    property real sx: 0
                    property real sy: 0

                    onPressed: (m) => {
                        const p = mapToItem(ui, m.x, m.y)
                        sx = p.x
                        sy = p.y
                    }

                    onPositionChanged: (m) => {
                        if (!pressed) return
                        const p = mapToItem(ui, m.x, m.y)
                        if (!win.drag && Math.hypot(p.x - sx, p.y - sy) > 6) win.drag = true
                        if (win.drag) {
                            win.dx = p.x - sx
                            win.dy = p.y - sy
                            wsMenu.dropWs = wsMenu.stripAt(p.x, p.y)
                        }
                    }


                    onReleased: (m) => {
                        if (!win.drag) {
                            wsMenu.focusWin(win.modelData.address)
                            return
                        }
                        const p = mapToItem(ui, m.x, m.y)
                        const target = wsMenu.stripAt(p.x, p.y)
                        win.drag = false
                        wsMenu.dropWs = -1
                        if (target > 0 && target !== win.wsId) {
                            win.dx = wsMenu.stripCardX(target) + wsMenu.stripCardW / 2 - (win.baseX + win.width / 2)
                            win.dy = wsMenu.stripY + wsMenu.stripCardH / 2 - (win.baseY + win.height / 2)
                            win.leaving = true
                            pendTimer.restart()
                            wsMenu.moveWin(win.modelData.address, target)
                        } else {
                            win.dx = 0
                            win.dy = 0
                        }
                    }
                }
            }
        }
    }
}
