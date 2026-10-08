import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../bar"
import "../common"

PanelWindow {
    id: altTab

    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary

    property string wallpaper: ""
    property bool blurEnabled: true
    property real blurRadius: 20
    property real blurDim: 0.28

    property bool liveThumbs: false

    property int showDelay: 130

    property bool isClosing: false
    property bool shown: false
    property real reveal: 0.0
    property int selected: 0

    property var wins: []
    readonly property int n: wins.length

    property var mru: []

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"

    readonly property real gap: 8
    readonly property real pad: 20
    readonly property real maxRowW: Math.max(200, width * 0.86 - 2 * pad)

    function layoutFor(w) {
        const th = w * 0.6
        const ch = th + 48
        const cols = Math.max(1, Math.min(n, Math.floor((maxRowW + gap) / (w + gap))))
        const rows = Math.max(1, Math.ceil(n / cols))
        return { w: w, ch: ch, cols: cols, rows: rows, h: rows * ch + (rows - 1) * gap + 2 * pad }
    }

    readonly property var lay: {
        for (let w = 196; w >= 104; w -= 8) {
            const l = layoutFor(w)
            if (l.h <= height * 0.8) return l
        }
        return layoutFor(104)
    }
    readonly property real cardW: lay.w
    readonly property real cardH: lay.ch
    readonly property real panelW: lay.cols * cardW + (lay.cols - 1) * gap + 2 * pad
    readonly property real panelH: lay.h
    readonly property real panelX: (width - panelW) / 2
    readonly property real panelY: (height - panelH) / 2


    function norm(a) {
        const s = String(a).toLowerCase()
        return s.indexOf("0x") === 0 ? s.slice(2) : s
    }

    function fullAddr(a) {
        const s = String(a)
        return s.indexOf("0x") === 0 ? s : "0x" + s
    }

    function touch(addr) {
        const a = norm(addr)
        if (a === "" || a === ",") return
        const m = [a]
        for (let i = 0; i < mru.length && m.length < 64; i++)
            if (mru[i] !== a) m.push(mru[i])
        mru = m
    }

    function forget(addr) {
        const a = norm(addr)
        mru = mru.filter(x => x !== a)
    }

    function buildList() {
        const v = Hyprland.toplevels.values
        const byAddr = {}
        const rest = []
        for (let i = 0; i < v.length; i++) {
            const w = v[i]
            const ipc = w.lastIpcObject || ({})
            if (!w.workspace || ipc.mapped === false || ipc.hidden === true) continue
            byAddr[norm(w.address)] = w
            rest.push(w)
        }

        const out = []
        const used = {}
        for (let i = 0; i < rest.length; i++) {
            if (rest[i].activated) {
                out.push(rest[i])
                used[norm(rest[i].address)] = true
                break
            }
        }


        for (let i = 0; i < mru.length; i++) {
            const w = byAddr[mru[i]]
            if (w && !used[mru[i]]) {
                out.push(w)
                used[mru[i]] = true
            }
        }

        const others = rest.filter(w => !used[norm(w.address)])
        others.sort((a, b) => {
            const ia = (a.lastIpcObject || ({})).focusHistoryID
            const ib = (b.lastIpcObject || ({})).focusHistoryID
            return (ia === undefined ? 9999 : ia) - (ib === undefined ? 9999 : ib)
        })
        wins = out.concat(others)
    }

    function focusWin(addr) {
        Hyprland.dispatch('hl.dsp.focus({ window = "address:' + fullAddr(addr) + '" })')
    }

    function cycle(d) {
        if (isClosing) return
        if (!visible) {
            buildList()
            if (n === 0) return
            selected = n > 1 ? (d > 0 ? 1 : n - 1) : 0
            reveal = 0
            shown = false
            visible = true
            Hyprland.refreshToplevels()
            showTimer.restart()
            Qt.callLater(() => keyItem.forceActiveFocus())
        } else {
            step(d)
        }
    }

    function step(d) {
        if (n === 0) return
        selected = ((selected + d) % n + n) % n
    }
    function stepRow(d) {
        if (n === 0) return
        const c = lay.cols
        const t = selected + d * c
        if (t >= 0 && t < n) selected = t
        else step(d)
    }

    function commit() {
        if (!visible || isClosing) return
        if (selected >= 0 && selected < n) focusWin(wins[selected].address)
        close()
    }
    function close() {
        if (!visible || isClosing) return
        showTimer.stop()
        if (!shown) {
            visible = false
            return
        }
        closeAnim.start()
    }
    function toggleMenu() {
        if (visible) close()
        else cycle(1)
    }
    Timer {
        id: showTimer
        interval: altTab.showDelay
        onTriggered: {
            altTab.shown = true
            openAnim.start()
        }
    }

    Connections {
        target: Hyprland
        function onRawEvent(ev) {
            if (ev.name === "activewindowv2") altTab.touch(ev.data)
            else if (ev.name === "closewindow") altTab.forget(ev.data)
        }
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
    WlrLayershell.namespace: "alttab"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    visible: false

    NumberAnimation { id: openAnim; target: altTab; property: "reveal"; from: 0.0; to: 1.0; duration: 140; easing.type: Easing.OutCubic }
    SequentialAnimation {
        id: closeAnim
        onStarted: altTab.isClosing = true
        NumberAnimation { target: altTab; property: "reveal"; to: 0.0; duration: 110; easing.type: Easing.InCubic }
        ScriptAction { script: { altTab.visible = false; altTab.isClosing = false; altTab.shown = false } }
    }
    LiveBackdrop {
        id: backdrop
        screenObj: altTab.screen
        wallpaper: altTab.wallpaper
        autoDetect: false
        active: altTab.visible && altTab.shown && altTab.blurEnabled
        pollInterval: 500
        liveCapture: false
        parkOthers: false
        texScale: 0.5
        baseColor: "#14141a"
        x: -width - 64
        y: -height - 64
    }

    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: altTab.reveal * 0.25
    }

    BarBlur {
        source: (altTab.blurEnabled && backdrop.width > 0) ? backdrop.texture : null
        srcSize: Qt.size(backdrop.width, backdrop.height)
        originX: 0
        originY: 0
        rect: ({ x: altTab.panelX, y: altTab.panelY, w: altTab.panelW, h: altTab.panelH })
        cornerRadius: 22
        blurRadius: altTab.blurRadius
        tint: Qt.rgba(0, 0, 0, altTab.blurDim)
        strength: altTab.reveal
    }

    MouseArea {
        anchors.fill: parent
        onClicked: altTab.close()
    }

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: (event) => {
            const d = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x
            altTab.step(d > 0 ? -1 : 1)
            event.accepted = true
        }
    }

    Item {
        id: keyItem
        anchors.fill: parent
        focus: true

        Keys.onPressed: (e) => {
            e.accepted = true
            if (e.key === Qt.Key_Escape) altTab.close()
            else if (e.key === Qt.Key_Tab) altTab.step((e.modifiers & Qt.ShiftModifier) ? -1 : 1)
            else if (e.key === Qt.Key_Backtab) altTab.step(-1)
            else if (e.key === Qt.Key_Right) altTab.step(1)
            else if (e.key === Qt.Key_Left) altTab.step(-1)
            else if (e.key === Qt.Key_Down) altTab.stepRow(1)
            else if (e.key === Qt.Key_Up) altTab.stepRow(-1)
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) altTab.commit()
            else e.accepted = false
        }

        Keys.onReleased: (e) => {
            if (e.key === Qt.Key_Alt) {
                altTab.commit()
                e.accepted = true
            }
        }
    }

    Item {
        id: ui
        x: altTab.panelX
        y: altTab.panelY + (1 - altTab.reveal) * 10
        width: altTab.panelW
        height: altTab.panelH
        opacity: altTab.reveal

        Rectangle {
            anchors.fill: parent
            radius: 22
            color: Qt.alpha(altTab.colBg, 0.6)
        }

        Repeater {
            model: altTab.shown ? altTab.wins : []

            delegate: Item {
                id: card

                required property var modelData
                required property int index

                readonly property var ipc: modelData.lastIpcObject || ({})
                readonly property bool isSel: altTab.selected === index
                readonly property string cls: String(ipc["class"] || "")
                readonly property int wsId: modelData.workspace ? modelData.workspace.id : 0

                readonly property real boxW: width - 20
                readonly property real boxH: height - 48
                readonly property real ratio: (ipc.size !== undefined && ipc.size[1] > 0) ? ipc.size[0] / ipc.size[1] : 16 / 9
                readonly property real fw: Math.max(10, Math.min(boxW, boxH * ratio))
                readonly property real fh: fw / ratio

                x: altTab.pad + (index % altTab.lay.cols) * (altTab.cardW + altTab.gap)
                y: altTab.pad + Math.floor(index / altTab.lay.cols) * (altTab.cardH + altTab.gap)
                width: altTab.cardW
                height: altTab.cardH

                Rectangle {
                    anchors.fill: parent
                    radius: 14
                    color: Qt.alpha(altTab.colSecondary, 0.95)
                    opacity: card.isSel ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 110 } }
                }

                Item {
                    x: 10
                    y: 10
                    width: card.boxW
                    height: card.boxH

                    Rectangle {
                        id: ph
                        anchors.centerIn: parent
                        width: card.fw
                        height: card.fh
                        radius: 6
                        color: Qt.alpha(altTab.colBg, 0.55)

                        Image {
                            id: bigIcon
                            anchors.centerIn: parent
                            width: Math.min(56, Math.min(parent.width, parent.height) * 0.45)
                            height: width
                            sourceSize: Qt.size(96, 96)
                            source: Quickshell.iconPath(card.cls.toLowerCase(), true)
                            visible: status === Image.Ready
                            fillMode: Image.PreserveAspectFit
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: !bigIcon.visible
                            text: (card.cls || card.modelData.title || "?").charAt(0).toUpperCase()
                            color: altTab.colAccent
                            font.pixelSize: Math.max(12, Math.min(parent.width, parent.height) * 0.35)
                            font.bold: true
                            font.family: altTab.fontFamily
                        }

                        ScreencopyView {
                            anchors.fill: parent
                            captureSource: altTab.visible ? card.modelData.wayland : null
                            live: altTab.liveThumbs
                            paintCursor: false
                            visible: hasContent
                        }
                    }
                }

                Item {
                    x: 12
                    y: 10 + card.boxH + 8
                    width: card.width - 24
                    height: 20

                    Image {
                        id: smallIcon
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16
                        sourceSize: Qt.size(32, 32)
                        source: Quickshell.iconPath(card.cls.toLowerCase(), true)
                        visible: status === Image.Ready
                        fillMode: Image.PreserveAspectFit
                    }

                    Text {
                        id: wsTxt
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: card.wsId > 0 ? card.wsId : "S"
                        color: altTab.colText
                        opacity: 0.45
                        font.pixelSize: 10
                        font.family: altTab.fontFamily
                    }

                    Text {
                        anchors.left: smallIcon.visible ? smallIcon.right : parent.left
                        anchors.leftMargin: smallIcon.visible ? 6 : 0
                        anchors.right: wsTxt.left
                        anchors.rightMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: card.modelData.title || card.cls
                        color: altTab.colText
                        font.pixelSize: 11
                        font.family: altTab.fontFamily
                    }
                }

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: card.height - 7
                    width: card.width * 0.4
                    height: 3
                    radius: 1.5
                    color: altTab.colAccent
                    opacity: card.isSel ? 1.0 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 110 } }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor

                    onPositionChanged: altTab.selected = card.index
                    onClicked: {
                        altTab.selected = card.index
                        altTab.commit()
                    }
                }
            }
        }
    }
}
