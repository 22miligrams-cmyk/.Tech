import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Bluetooth
import "../bar"
import "../notifications"
import "../settings"
import "../common"
import "../lang"
import "../icons"

PanelWindow {
    id: btMenu

    function tr(key) { return Tr.tr(key) }
    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary


    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"

    readonly property var adapter: Bluetooth.defaultAdapter
        ?? (Bluetooth.adapters.values.length > 0 ? Bluetooth.adapters.values[0] : null)

    property bool isClosing: false
    property string pendingAddr: ""

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    exclusionMode: ExclusionMode.Ignore

    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "bluetooth-menu"
    visible: false

    function glyph(cp) {
        return String.fromCodePoint(cp)
    }

    function iconFor(d) {
        const ic = String(d.icon || "")
        if (ic.includes("headset") || ic.includes("headphone")) return "headset"
        if (ic.includes("audio")) return "speaker"
        if (ic.includes("phone")) return "phone"
        if (ic.includes("keyboard")) return "keyboard"
        if (ic.includes("mouse") || ic.includes("tablet")) return "mouse"
        if (ic.includes("gaming")) return "gamepad"
        if (ic.includes("computer")) return "laptop"
        if (ic.includes("video") || ic.includes("display")) return "monitor"
        if (ic.includes("printer")) return "printer"
        if (ic.includes("camera")) return "camera"
        if (ic.includes("watch")) return "watch"
        return d.connected ? "bluetoothOn" : "bluetooth"
    }

    function isPaired(d) {
        return d.paired === true || d.bonded === true
    }

    function isBusy(d) {
        return d.state === BluetoothDeviceState.Connecting || d.state === BluetoothDeviceState.Disconnecting
    }
    function statusText(d) {
        if (d.state === BluetoothDeviceState.Connecting) return tr("bt.connecting")
        if (d.state === BluetoothDeviceState.Disconnecting) return tr("bt.disconnecting")
        if (d.connected) return tr("bt.connected")
        if (isPaired(d)) return tr("bt.paired")
        return tr("bt.available")
    }
    function actionText(d) {
        if (isBusy(d)) return "…"
        if (d.connected) return tr("bt.disconnect")
        if (isPaired(d)) return tr("bt.connect")
        return tr("bt.pair")
    }

    function batteryOf(d) {
        if (d.batteryAvailable && d.battery >= 0)
            return Math.round(d.battery <= 1 ? d.battery * 100 : d.battery)
        if (d.batteryPercentage !== undefined && d.batteryPercentage >= 0)
            return d.batteryPercentage
        return -1
    }

    function rank(d) {
        return d.connected ? 0 : (isPaired(d) ? 1 : 2)
    }

    function deviceList() {
        const a = btMenu.adapter
        if (!a || !a.enabled) return []
        const raw = a.devices.values
        const macLike = /^([0-9A-F]{2}[-:]){5}[0-9A-F]{2}$/i
        const out = []
        for (let i = 0; i < raw.length; i++) {
            const d = raw[i]
            if (d.connected || isPaired(d) || (d.name && !macLike.test(d.name)))
                out.push(d)
        }
        out.sort((x, y) => (rank(x) - rank(y)) || String(x.name).localeCompare(String(y.name)))
        return out
    }

    function activate(d) {
        if (!d || isBusy(d)) return
        if (d.connected) {
            d.disconnect()
        } else if (isPaired(d)) {
            d.connect()
        } else {
            pendingAddr = d.address
            d.trusted = true
            d.pair()
        }
    }

    function toggleMenu() {
        if (isClosing)
            return;

        if (visible) {
            isClosing = true;
            if (adapter) adapter.discovering = false;
            openAnim.stop();
            closeAnim.start();
        } else {
            visible = true;
            backdropOn = false;
            backdropTimer.restart();
            list.currentIndex = 0;
            openAnim.start();
            list.forceActiveFocus();
            if (adapter && adapter.enabled) adapter.discovering = true;
        }
    }
    property string wallpaper: ""
    property bool blurEnabled: true
    property real blurRadius: 30
    property real blurDim: 0.12

    // эффект камеры: панель чуть двигается и наклоняется за мышкой (параллакс как в настройках)
    property bool camEffect: true            // потом можно привязать к barLayout.camEffect из Visual.qml
    readonly property bool camOn: camEffect
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

    function clamp01(v) { return Math.max(0, Math.min(1, v)) }

    property bool blurLive: false
    property bool blurPreload: false
    property bool backdropOn: false
    property int backdropDelay: 120
    Timer { id: backdropTimer; interval: btMenu.backdropDelay; onTriggered: btMenu.backdropOn = true }
    property real blurIn: backdropOn ? 1 : 0
    Behavior on blurIn { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

    LiveBackdrop {
        id: backdrop
        screenObj: btMenu.screen
        wallpaper: btMenu.wallpaper
        autoDetect: false
        active: btMenu.visible && btMenu.blurEnabled && btMenu.backdropOn
        pollInterval: 2000
        liveCapture: btMenu.blurLive
        parkOthers: btMenu.blurPreload
        texScale: 0.5
        wsDelay: 150
        baseColor: "#14141a"
        x: -width - 64
        y: -height - 64
    }

    BarBlur {
        source: (btMenu.blurEnabled && backdrop.width > 0 && btMenu.backdropOn) ? backdrop.texture : null
        srcSize: Qt.size(backdrop.width, backdrop.height)
        originX: 0
        originY: 0
        rect: ({ x: 0, y: 0, w: btMenu.width, h: btMenu.height })
        cornerRadius: 0
        blurRadius: btMenu.blurRadius
        tint: Qt.rgba(0, 0, 0, btMenu.blurDim)
        strength: menuContainer.opacity * btMenu.blurIn
    }

    Rectangle {
        anchors.fill: parent
        color: "black"
        visible: !btMenu.blurEnabled
        opacity: menuContainer.opacity * 0.5
    }

    Item {
        id: camSurface
        anchors.fill: parent
        HoverHandler { id: camHover }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: btMenu.toggleMenu()
    }

    ScriptModel {
        id: devModel
        values: btMenu.deviceList()
    }

    Item {
        id: menuContainer
        anchors.centerIn: parent
        width: parent.width
        height: 420

        scale: 0.0
        opacity: 0.0

        transform: [
            Translate {
                x: -btMenu.camX * btMenu.camMoveX * btMenu.camStrength
                y: -btMenu.camY * btMenu.camMoveY * btMenu.camStrength
            },
            Rotation {
                origin.x: menuContainer.width / 2
                origin.y: menuContainer.height / 2
                axis { x: 0; y: 1; z: 0 }
                angle: btMenu.camX * btMenu.camTilt * btMenu.camStrength
            },
            Rotation {
                origin.x: menuContainer.width / 2
                origin.y: menuContainer.height / 2
                axis { x: 1; y: 0; z: 0 }
                angle: -btMenu.camY * btMenu.camTilt * btMenu.camStrength
            }
        ]

        MouseArea {
            anchors.fill: parent
            onClicked: (mouse) => mouse.accepted = true
        }

        ParallelAnimation {
            id: openAnim
            NumberAnimation { target: menuContainer; property: "scale"; from: 0.7; to: 1.0; duration: 250; easing.type: Easing.OutBack }
            NumberAnimation { target: menuContainer; property: "opacity"; from: 0.0; to: 1.0; duration: 200; easing.type: Easing.OutCubic }
        }

        ParallelAnimation {
            id: closeAnim
            NumberAnimation { target: menuContainer; property: "scale"; from: 1.0; to: 0.7; duration: 200; easing.type: Easing.InCubic }
            NumberAnimation { target: menuContainer; property: "opacity"; from: 1.0; to: 0.0; duration: 150; easing.type: Easing.InCubic }
            onFinished: {
                btMenu.visible = false;
                btMenu.backdropOn = false;
                btMenu.isClosing = false;
            }
        }

        ColumnLayout {
            anchors.centerIn: parent
            width: parent.width
            spacing: 25

            // обёртка на всю ширину, PanelHeader вне layout, центруется якорем
            Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 60

            PanelHeader {
                anchors.horizontalCenter: parent.horizontalCenter
                colBg: btMenu.colBg
                colAccent: btMenu.colAccent
                colText: btMenu.colText
                colSecondary: btMenu.colSecondary
                fontFamily: btMenu.fontFamily
                iconName: btMenu.adapter && btMenu.adapter.enabled ? "bluetooth" : "bluetoothOff"
                iconDim: 1.3
                title: tr("win.bluetooth")
                badge: ""

                Rectangle {
                    visible: btMenu.adapter !== null
                    Layout.preferredHeight: 60
                    Layout.preferredWidth: powerRow.implicitWidth + 36
                    radius: 14
                    color: btMenu.adapter && btMenu.adapter.enabled ? btMenu.colAccent : Qt.alpha(btMenu.colSecondary, 0.9)

                    Behavior on color { ColorAnimation { duration: 150 } }

                    Row {
                        id: powerRow
                        anchors.centerIn: parent
                        spacing: 8

                        Icon {
                            name: "power"
                            size: 15
                            color: btMenu.adapter && btMenu.adapter.enabled ? btMenu.colBg : btMenu.colText
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            text: btMenu.adapter && btMenu.adapter.enabled ? tr("bt.on") : tr("bt.off")
                            color: btMenu.adapter && btMenu.adapter.enabled ? btMenu.colBg : btMenu.colText
                            font.pixelSize: 14
                            font.bold: true
                            font.family: btMenu.fontFamily
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const a = btMenu.adapter;
                            a.enabled = !a.enabled;
                            if (!a.enabled) a.discovering = false;
                        }
                    }
                }

                Rectangle {
                    visible: btMenu.adapter !== null && btMenu.adapter.enabled
                    Layout.preferredHeight: 60
                    Layout.preferredWidth: scanRow.implicitWidth + 36
                    radius: 14
                    color: btMenu.adapter && btMenu.adapter.discovering ? btMenu.colAccent : Qt.alpha(btMenu.colSecondary, 0.9)

                    Behavior on color { ColorAnimation { duration: 150 } }


                    Row {
                        id: scanRow
                        anchors.centerIn: parent
                        spacing: 8

                        Icon {
                            id: scanIcon
                            name: "search"
                            size: 15
                            color: btMenu.adapter && btMenu.adapter.discovering ? btMenu.colBg : btMenu.colText
                            anchors.verticalCenter: parent.verticalCenter

                            NumberAnimation on rotation {
                                from: 0
                                to: 360
                                duration: 1400
                                loops: Animation.Infinite
                                running: btMenu.adapter !== null && btMenu.adapter.discovering
                                onRunningChanged: if (!running) scanIcon.rotation = 0
                            }
                        }


                        Text {
                            text: btMenu.adapter && btMenu.adapter.discovering ? tr("bt.scanning") : tr("bt.scan")
                            color: btMenu.adapter && btMenu.adapter.discovering ? btMenu.colBg : btMenu.colText
                            font.pixelSize: 14
                            font.bold: true
                            font.family: btMenu.fontFamily
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: btMenu.adapter.discovering = !btMenu.adapter.discovering
                    }
                }
            }
            }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 290

                Row {
                    anchors.centerIn: parent
                    spacing: 8
                    opacity: list.count === 0 ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    Icon {
                        name: btMenu.adapter && btMenu.adapter.enabled ? "bluetooth" : "bluetoothOff"
                        size: 15
                        color: btMenu.colAccent
                        dim: 1.3
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: {
                            if (!btMenu.adapter) return tr("bt.noadapter");
                            if (!btMenu.adapter.enabled) return tr("bt.disabled");
                            if (btMenu.adapter.discovering) return tr("bt.searching");
                            return tr("bt.nodevices");
                        }
                        color: btMenu.colText
                        font.pixelSize: 12
                        font.bold: true
                        font.family: btMenu.fontFamily
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                ListView {
                    id: list
                    anchors.fill: parent
                    orientation: ListView.Horizontal
                    spacing: 0
                    clip: false
                    focus: true

                    preferredHighlightBegin: width / 2 - 130
                    preferredHighlightEnd: width / 2 + 130
                    highlightRangeMode: ListView.StrictlyEnforceRange
                    highlightMoveDuration: 150

                    model: devModel

                    displaced: Transition {
                        NumberAnimation { properties: "x,y"; duration: 250; easing.type: Easing.OutCubic }
                    }

                    delegate: Item {
                        id: slotItem

                        required property int index
                        required property var modelData

                        readonly property bool isCurrent: index === list.currentIndex
                        readonly property bool active: modelData.connected
                        readonly property int battery: btMenu.batteryOf(modelData)

                        property bool ready: false

                        width: isCurrent ? 290 : 260
                        height: 280

                        Behavior on width { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

                        Component.onCompleted: startTimer.start()

                        Timer {
                            id: startTimer
                            interval: 60 + Math.min(slotItem.index, 6) * 45
                            onTriggered: slotItem.ready = true
                        }

                        Connections {
                            target: slotItem.modelData
                            function onPairedChanged() {
                                if (slotItem.modelData.paired && btMenu.pendingAddr === slotItem.modelData.address) {
                                    btMenu.pendingAddr = "";
                                    slotItem.modelData.connect();
                                }
                            }
                        }

                        Item {
                            id: cardContainer
                            anchors.centerIn: parent
                            width: 240
                            height: 260

                            property real rotAngle: {
                                if (!slotItem.ready) return 90;
                                if (slotItem.isCurrent) return 0;
                                return slotItem.index < list.currentIndex ? 35 : -35;
                            }

                            opacity: {
                                if (!slotItem.ready) return 0.0;
                                return slotItem.isCurrent ? 1.0 : 0.5;
                            }

                            scale: {
                                if (!slotItem.ready) return 0.7;
                                return slotItem.isCurrent ? 1.1 : 0.85;
                            }

                            transform: Rotation {
                                origin.x: cardContainer.width / 2
                                origin.y: cardContainer.height / 2
                                axis { x: 0; y: 1; z: 0 }
                                angle: cardContainer.rotAngle
                            }

                            Behavior on rotAngle { NumberAnimation { duration: 400; easing.type: Easing.OutBack } }
                            Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                            Behavior on scale { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: list.currentIndex = slotItem.index
                            }

                            Rectangle {
                                anchors.fill: parent
                                radius: 14
                                color: Qt.alpha(slotItem.active ? btMenu.colSecondary : btMenu.colBg,
                                                slotItem.isCurrent ? 0.9 : 0.4)

                                Behavior on color { ColorAnimation { duration: 150 } }
                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 16
                                    spacing: 10

                                    RowLayout {
                                        Layout.fillWidth: true

                                        Rectangle {
                                            Layout.preferredWidth: 52
                                            Layout.preferredHeight: 52
                                            radius: 6
                                            color: slotItem.active ? btMenu.colAccent : btMenu.colSecondary

                                            Behavior on color { ColorAnimation { duration: 200 } }

                                            Icon {
                                                anchors.centerIn: parent
                                                name: btMenu.iconFor(slotItem.modelData)
                                                size: 26
                                                color: slotItem.active ? btMenu.colBg : btMenu.colAccent
                                                dim: slotItem.active ? 1.0 : 1.3

                                                Behavior on color { ColorAnimation { duration: 200 } }
                                            }
                                        }

                                        Item { Layout.fillWidth: true }

                                        Item {
                                            visible: btMenu.isPaired(slotItem.modelData)
                                            Layout.preferredWidth: 20
                                            Layout.preferredHeight: 20
                                            Layout.alignment: Qt.AlignTop

                                            Icon {
                                                anchors.centerIn: parent
                                                name: "close"
                                                size: 14
                                                color: forgetArea.containsMouse ? btMenu.colAccent : btMenu.colText
                                                opacity: forgetArea.containsMouse ? 1.0 : 0.55

                                                Behavior on color { ColorAnimation { duration: 150 } }
                                                Behavior on opacity { NumberAnimation { duration: 150 } }
                                            }

                                            MouseArea {
                                                id: forgetArea
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: slotItem.modelData.forget()
                                            }
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: slotItem.modelData.name || slotItem.modelData.address
                                        color: btMenu.colText
                                        font.bold: true
                                        font.pixelSize: 14
                                        font.family: btMenu.fontFamily
                                        wrapMode: Text.WordWrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: btMenu.statusText(slotItem.modelData)
                                        color: slotItem.active ? btMenu.colAccent : btMenu.colText
                                        opacity: slotItem.active ? 1.0 : 0.55
                                        font.pixelSize: 11
                                        font.family: btMenu.fontFamily
                                    }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        visible: slotItem.battery >= 0
                                        spacing: 8

                                        Rectangle {
                                            Layout.fillWidth: true
                                            Layout.preferredHeight: 6
                                            radius: 3
                                            color: Qt.alpha(btMenu.colText, 0.14)

                                            Rectangle {
                                                width: parent.width * Math.max(0, Math.min(100, slotItem.battery)) / 100
                                                height: parent.height
                                                radius: 3
                                                color: btMenu.colAccent

                                                Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                                            }
                                        }

                                        Text {
                                            text: slotItem.battery + "%"
                                            color: btMenu.colText
                                            font.pixelSize: 10
                                            font.bold: true
                                            font.family: btMenu.fontFamily
                                        }
                                    }
                                    Item { Layout.fillHeight: true }

                                    Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: 32
                                        radius: 6
                                        opacity: btMenu.isBusy(slotItem.modelData) ? 0.6 : 1.0
                                        color: slotItem.active
                                               ? (actionArea.containsMouse ? btMenu.colSecondary : btMenu.colBg)
                                               : (actionArea.containsMouse ? Qt.lighter(btMenu.colAccent, 1.15) : btMenu.colAccent)

                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        Behavior on opacity { NumberAnimation { duration: 150 } }

                                        Text {
                                            anchors.centerIn: parent
                                            text: btMenu.actionText(slotItem.modelData)
                                            color: slotItem.active ? btMenu.colText : btMenu.colBg
                                            font.pixelSize: 12
                                            font.bold: true
                                            font.family: btMenu.fontFamily
                                        }

                                        MouseArea {
                                            id: actionArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                list.currentIndex = slotItem.index;
                                                btMenu.activate(slotItem.modelData);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Keys.onLeftPressed: if (currentIndex > 0) currentIndex--
                    Keys.onRightPressed: if (currentIndex < count - 1) currentIndex++
                    Keys.onReturnPressed: {
                        const it = list.itemAtIndex(list.currentIndex);
                        if (it) btMenu.activate(it.modelData);
                    }
                    Keys.onEscapePressed: btMenu.toggleMenu()

                    WheelHandler {
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        onWheel: (event) => {
                            let delta = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x;
                            if (delta > 0 && list.currentIndex > 0) {
                                list.currentIndex--;
                            } else if (delta < 0 && list.currentIndex < list.count - 1) {
                                list.currentIndex++;
                            }
                            event.accepted = true;
                        }
                    }
                }
            }
        }
    }
}
