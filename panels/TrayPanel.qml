import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.SystemTray
import "../bar"
import "../notifications"
import "../settings"
import "../common"
import "../icons"
import "../lang"

PanelWindow {
    id: panel

    function tr(key) { return Tr.tr(key) }

    function ownIcon(it) {
        const s = ((it.id || "") + " " + (it.title || "") + " " + (it.tooltipTitle || "")).toLowerCase()
        if (s.indexOf("blue") >= 0) return "bluetooth"
        if (s.indexOf("network") >= 0 || s.indexOf("nm-") >= 0 || s.indexOf("wifi") >= 0 || s.indexOf("wi-fi") >= 0
            || s.indexOf("wlan") >= 0 || s.indexOf("сет") >= 0) return "wifi"
        if (s.indexOf("volume") >= 0 || s.indexOf("audio") >= 0 || s.indexOf("звук") >= 0) return "volume"
        return ""
    }

    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"
    readonly property int trayCount: SystemTray.items.values.length

    property bool isClosing: false


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
    WlrLayershell.namespace: "tray-panel"
    visible: false

    function toggleMenu() {
        if (isClosing)
            return;

        if (visible) {
            isClosing = true;
            openAnim.stop();
            closeAnim.start();
        } else {
            visible = true;
            list.currentIndex = 0;
            openAnim.start();
            list.forceActiveFocus();
        }
    }

    function activateItem(it) {
        if (!it || !it.modelData)
            return;
        if (it.modelData.onlyMenu && it.modelData.hasMenu) {
            it.openMenu();
            return;
        }
        it.modelData.activate();
        panel.toggleMenu();
    }

    function currentSlot() {
        return list.itemAtIndex(list.currentIndex);
    }

    property string wallpaper: ""
    property bool blurEnabled: true
    property real blurRadius: 30
    property real blurDim: 0.12

    // эффект камеры: панель чуть двигается и наклоняется за мышкой (как в BtMenu)
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

    LiveBackdrop {
        id: backdrop
        screenObj: panel.screen
        wallpaper: panel.wallpaper
        autoDetect: false
        active: panel.visible && panel.blurEnabled
        pollInterval: 500
        liveCapture: false
        parkOthers: false
        texScale: 0.5
        baseColor: "#14141a"
        x: -width - 64
        y: -height - 64
    }

    BarBlur {
        source: (panel.blurEnabled && backdrop.width > 0) ? backdrop.texture : null
        srcSize: Qt.size(backdrop.width, backdrop.height)
        originX: 0
        originY: 0
        rect: ({ x: 0, y: 0, w: panel.width, h: panel.height })
        cornerRadius: 0
        blurRadius: panel.blurRadius
        tint: Qt.rgba(0, 0, 0, panel.blurDim)
        strength: menuContainer.opacity
    }
    Rectangle {
        anchors.fill: parent
        color: "black"
        visible: !panel.blurEnabled
        opacity: menuContainer.opacity * 0.5
    }

    Item {
        id: camSurface
        anchors.fill: parent
        HoverHandler { id: camHover }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: panel.toggleMenu()
    }

    Item {
        id: menuContainer
        anchors.centerIn: parent
        width: parent.width
        height: 400

        scale: 0.0
        opacity: 0.0

        transform: [
            Translate {
                x: -panel.camX * panel.camMoveX * panel.camStrength
                y: -panel.camY * panel.camMoveY * panel.camStrength
            },
            Rotation {
                origin.x: menuContainer.width / 2
                origin.y: menuContainer.height / 2
                axis { x: 0; y: 1; z: 0 }
                angle: panel.camX * panel.camTilt * panel.camStrength
            },
            Rotation {
                origin.x: menuContainer.width / 2
                origin.y: menuContainer.height / 2
                axis { x: 1; y: 0; z: 0 }
                angle: -panel.camY * panel.camTilt * panel.camStrength
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
                panel.visible = false;
                panel.isClosing = false;
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
                    colBg: panel.colBg
                    colAccent: panel.colAccent
                    colText: panel.colText
                    colSecondary: panel.colSecondary
                    fontFamily: panel.fontFamily
                    iconName: "tray"
                    title: tr("tray.title")
                    badge: panel.trayCount > 0 ? String(panel.trayCount) : ""
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 280

                Text {
                    anchors.centerIn: parent
                    text: tr("tray.empty")
                    color: panel.colText
                    font.pixelSize: 12
                    font.bold: true
                    font.family: panel.fontFamily
                    opacity: panel.trayCount === 0 ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 200 } }
                }

                ListView {
                    id: list
                    anchors.fill: parent
                    orientation: ListView.Horizontal
                    spacing: 0
                    clip: false
                    focus: true

                    preferredHighlightBegin: width / 2 - 110
                    preferredHighlightEnd: width / 2 + 110
                    highlightRangeMode: ListView.StrictlyEnforceRange
                    highlightMoveDuration: 150

                    model: SystemTray.items


                    delegate: Item {
                        id: slotItem


                        required property var modelData
                        required property int index

                        readonly property bool isCurrent: index === list.currentIndex
                        readonly property string title: {
                            const t = modelData.tooltipTitle || modelData.title || modelData.id || "";
                            return t;
                        }
                        readonly property bool attention: modelData.status === Status.NeedsAttention

                        property bool ready: false
                        property real baseW: isCurrent ? 230 : 200

                        width: baseW
                        height: 260

                        Behavior on baseW { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

                        function openMenu() {
                            if (!modelData.hasMenu) {
                                modelData.secondaryActivate();
                                return;
                            }
                            const p = cardContainer.mapToItem(null, cardContainer.width / 2, cardContainer.height);
                            modelData.display(panel, Math.round(p.x), Math.round(p.y));
                        }

                        Component.onCompleted: startTimer.start()

                        Timer {
                            id: startTimer
                            interval: 60 + Math.min(slotItem.index, 6) * 45
                            onTriggered: slotItem.ready = true
                        }

                        Item {
                            id: cardContainer
                            anchors.centerIn: parent
                            width: 200
                            height: 240

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

                            Rectangle {
                                anchors.fill: parent
                                radius: 14
                                color: Qt.alpha(panel.colSecondary, slotItem.isCurrent ? 0.9 : 0.4)


                                Behavior on color { ColorAnimation { duration: 150 } }
                                ColumnLayout {
                                    anchors.centerIn: parent
                                    width: parent.width - 30
                                    spacing: 16

                                    Item {
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.preferredWidth: 56
                                        Layout.preferredHeight: 56

                                        Image {
                                            id: trayImg
                                            anchors.fill: parent
                                            visible: panel.ownIcon(slotItem.modelData) === ""
                                            source: slotItem.modelData.icon
                                            sourceSize.width: 112
                                            sourceSize.height: 112
                                            fillMode: Image.PreserveAspectFit
                                            smooth: true
                                            asynchronous: true
                                        }

                                        Icon {
                                            anchors.centerIn: parent
                                            readonly property string own: panel.ownIcon(slotItem.modelData)
                                            visible: own !== "" || trayImg.status === Image.Error || trayImg.status === Image.Null
                                            name: own !== "" ? own : "tray"
                                            size: 48
                                            color: panel.colAccent
                                        }

                                        Rectangle {
                                            visible: slotItem.attention
                                            width: 10
                                            height: 10
                                            radius: 3
                                            color: panel.colAccent
                                            anchors.top: parent.top
                                            anchors.right: parent.right
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: slotItem.title
                                        color: panel.colText
                                        font.pixelSize: 13
                                        font.bold: true
                                        font.family: panel.fontFamily
                                        horizontalAlignment: Text.AlignHCenter
                                        wrapMode: Text.Wrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        visible: text !== ""
                                        text: slotItem.modelData.tooltipDescription || ""
                                        color: panel.colText
                                        opacity: 0.65
                                        font.pixelSize: 10
                                        font.family: panel.fontFamily
                                        horizontalAlignment: Text.AlignHCenter
                                        wrapMode: Text.Wrap
                                        maximumLineCount: 3
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        visible: slotItem.isCurrent
                                        text: slotItem.modelData.hasMenu ? tr("tray.hintMenu") : tr("tray.hint")
                                        color: panel.colAccent
                                        opacity: 0.8
                                        font.pixelSize: 9
                                        font.family: panel.fontFamily
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                z: -1
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                                onClicked: (mouse) => {
                                    if (!slotItem.isCurrent) {
                                        list.currentIndex = slotItem.index;
                                        return;
                                    }
                                    if (mouse.button === Qt.RightButton)
                                        slotItem.openMenu();
                                    else if (mouse.button === Qt.MiddleButton)
                                        slotItem.modelData.secondaryActivate();
                                    else
                                        panel.activateItem(slotItem);
                                }
                            }
                        }
                    }

                    Keys.onLeftPressed: if (currentIndex > 0) currentIndex--
                    Keys.onRightPressed: if (currentIndex < count - 1) currentIndex++
                    Keys.onReturnPressed: panel.activateItem(panel.currentSlot())
                    Keys.onMenuPressed: { let s = panel.currentSlot(); if (s) s.openMenu() }
                    Keys.onPressed: (event) => {
                        if (event.key === Qt.Key_M) {
                            let s = panel.currentSlot();
                            if (s) s.openMenu();
                            event.accepted = true;
                        }
                    }
                    Keys.onEscapePressed: panel.toggleMenu()

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
