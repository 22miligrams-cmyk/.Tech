import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import "../bar"
import "../notifications"
import "../settings"
import "../common"
import "../lang"
import "../icons"

PanelWindow {
    id: panel

    function tr(key) { return Tr.tr(key) }


    required property var store
    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"

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
    WlrLayershell.namespace: "clipboard-panel"
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
            backdropOn = false;
            backdropTimer.restart();
            list.currentIndex = 0;
            openAnim.start();
            list.forceActiveFocus();
        }
    }

    function pickCurrent() {
        var it = list.itemAtIndex(list.currentIndex);
        if (!it)
            return;
        panel.store.copyEntry(it.kind, it.text, it.path, it.mime);
        panel.toggleMenu();
    }
    function dismissCurrent() {
        var it = list.itemAtIndex(list.currentIndex);
        if (it)
            it.dismiss(0);
    }

    function clearAll() {
        for (var i = 0; i < list.count; i++) {
            var it = list.itemAtIndex(i);
            if (it)
                it.dismiss(Math.min(i, 8) * 40);
        }
        clearTimer.restart();
    }

    Timer {
        id: clearTimer
        interval: 800
        onTriggered: panel.store.clear()
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
    Timer { id: backdropTimer; interval: panel.backdropDelay; onTriggered: panel.backdropOn = true }
    property real blurIn: backdropOn ? 1 : 0
    Behavior on blurIn { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

    LiveBackdrop {
        id: backdrop
        screenObj: panel.screen
        wallpaper: panel.wallpaper
        autoDetect: false
        active: panel.visible && panel.blurEnabled && panel.backdropOn
        pollInterval: 2000
        liveCapture: panel.blurLive
        parkOthers: panel.blurPreload
        texScale: 0.5
        wsDelay: 150
        baseColor: "#14141a"
        x: -width - 64
        y: -height - 64
    }

    BarBlur {
        source: (panel.blurEnabled && backdrop.width > 0 && panel.backdropOn) ? backdrop.texture : null
        srcSize: Qt.size(backdrop.width, backdrop.height)
        originX: 0
        originY: 0
        rect: ({ x: 0, y: 0, w: panel.width, h: panel.height })
        cornerRadius: 0
        blurRadius: panel.blurRadius
        tint: Qt.rgba(0, 0, 0, panel.blurDim)
        strength: menuContainer.opacity * panel.blurIn
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
                panel.backdropOn = false;
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
                iconName: "clipboard"
                iconDim: 1.3
                title: tr("clip.title")
                badge: panel.store.count > 0 ? String(panel.store.count) : ""

                Rectangle {
                    visible: panel.store.count > 0
                    Layout.preferredHeight: 60
                    Layout.preferredWidth: clearText.implicitWidth + 36
                    radius: 14
                    color: clearArea.containsMouse ? panel.colAccent : Qt.alpha(panel.colSecondary, 0.9)

                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        id: clearText
                        anchors.centerIn: parent
                        text: tr("clip.clear")
                        color: clearArea.containsMouse ? panel.colBg : panel.colText
                        font.pixelSize: 14
                        font.bold: true
                        font.family: panel.fontFamily

                        Behavior on color { ColorAnimation { duration: 150 } }
                    }

                    MouseArea {
                        id: clearArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panel.clearAll()
                    }
                }
            }
            }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 280

                Row {
                    anchors.centerIn: parent
                    spacing: 8
                    opacity: panel.store.count === 0 ? 1 : 0
                    visible: opacity > 0

                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    Icon {
                        name: "clipboard"
                        size: 15
                        color: panel.colAccent
                        dim: 1.3
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: tr("clip.empty")
                        color: panel.colText
                        font.pixelSize: 12
                        font.bold: true
                        font.family: panel.fontFamily
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

                    model: panel.store.history

                    displaced: Transition {
                        NumberAnimation { properties: "x,y"; duration: 250; easing.type: Easing.OutCubic }
                    }


                    delegate: Item {
                        id: slotItem

                        required property int index
                        required property int uid
                        required property string kind
                        required property string text
                        required property int chars
                        required property string path
                        required property string mime
                        required property int bytes
                        required property string timeText

                        readonly property bool isImage: kind === "image"
                        readonly property string sizeText: bytes >= 1048576
                            ? (bytes / 1048576).toFixed(1) + " " + tr("unit.mb")
                            : Math.max(1, Math.round(bytes / 1024)) + " " + tr("unit.kb")
                        readonly property string footText: isImage
                            ? mime.replace("image/", "").toUpperCase() + " · " + sizeText
                            : chars + " " + tr("clip.chars")

                        readonly property bool isCurrent: index === list.currentIndex

                        property real fold: 1
                        property bool hiding: false
                        property bool ready: false
                        property int hideDelay: 0
                        property real baseW: isCurrent ? 290 : 260

                        width: baseW * fold
                        height: 260

                        // текущая карточка всегда сверху, остальные по расстоянию от неё
                        z: isCurrent ? 100 : 100 - Math.abs(index - list.currentIndex)

                        Behavior on baseW { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

                        function dismiss(delay) {
                            if (hiding || animHide.running)
                                return;
                            hideDelay = delay || 0;
                            animHide.start();
                        }

                        Component.onCompleted: startTimer.start()

                        Timer {
                            id: startTimer
                            interval: 60 + Math.min(slotItem.index, 6) * 45
                            onTriggered: slotItem.ready = true
                        }

                        SequentialAnimation {
                            id: animHide
                            PauseAnimation { duration: slotItem.hideDelay }
                            ScriptAction { script: slotItem.hiding = true }
                            PauseAnimation { duration: 260 }
                            NumberAnimation { target: slotItem; property: "fold"; to: 0; duration: 220; easing.type: Easing.OutCubic }
                            onFinished: panel.store.remove(slotItem.uid)
                        }

                        Item {
                            id: cardContainer
                            anchors.centerIn: parent
                            width: 240
                            height: 240

                            property real rotAngle: {
                                if (!slotItem.ready) return 90;
                                if (slotItem.isCurrent) return 0;
                                return slotItem.index < list.currentIndex ? 35 : -35;
                            }

                            opacity: {
                                if (!slotItem.ready || slotItem.hiding) return 0.0;
                                return slotItem.isCurrent ? 1.0 : 0.5;
                            }


                            scale: {
                                if (!slotItem.ready || slotItem.hiding) return 0.7;
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
                                z: -1
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (slotItem.isCurrent)
                                        panel.pickCurrent();
                                    else
                                        list.currentIndex = slotItem.index;
                                }
                            }

                            Rectangle {
                                anchors.fill: parent
                                radius: 14
                                color: Qt.alpha(panel.colSecondary, slotItem.isCurrent ? 0.9 : 0.4)

                                Behavior on color { ColorAnimation { duration: 150 } }

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 16
                                    spacing: 8

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8

                                        Rectangle {
                                            Layout.preferredWidth: 6
                                            Layout.preferredHeight: 6
                                            radius: 2
                                            color: panel.colAccent
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            text: slotItem.timeText
                                            color: panel.colAccent
                                            font.bold: true
                                            font.pixelSize: 12
                                            font.family: panel.fontFamily
                                        }

                                        Item {
                                            Layout.preferredWidth: 16
                                            Layout.preferredHeight: 16

                                            Icon {
                                                anchors.centerIn: parent
                                                name: "close"
                                                size: 13
                                                color: closeArea.containsMouse ? panel.colAccent : panel.colText
                                                opacity: closeArea.containsMouse ? 1.0 : 0.55

                                                Behavior on color { ColorAnimation { duration: 150 } }
                                                Behavior on opacity { NumberAnimation { duration: 150 } }
                                            }

                                            MouseArea {
                                                id: closeArea
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: slotItem.dismiss(0)
                                            }
                                        }
                                    }

                                    Item {
                                        id: imgBox
                                        visible: slotItem.isImage

                                        // размер задан жёстко: карточка 240x240 минус отступы, шапка и подвал.
                                        // иначе Layout сам решал сколько места под картинку, а так не надо
                                        readonly property real boxW: 208
                                        readonly property real boxH: 160
                                        Layout.fillWidth: false
                                        Layout.fillHeight: false
                                        Layout.alignment: Qt.AlignHCenter
                                        Layout.preferredWidth: boxW
                                        Layout.minimumWidth: boxW
                                        Layout.maximumWidth: boxW
                                        Layout.preferredHeight: boxH
                                        Layout.minimumHeight: boxH
                                        Layout.maximumHeight: boxH
                                        implicitWidth: boxW
                                        implicitHeight: boxH
                                        width: boxW
                                        height: boxH
                                        clip: true

                                        Image {
                                            id: clipImg
                                            width: imgBox.boxW
                                            height: imgBox.boxH
                                            source: slotItem.isImage ? "file://" + slotItem.path : ""
                                            fillMode: Image.PreserveAspectFit
                                            asynchronous: true
                                            smooth: true
                                            mipmap: true
                                            sourceSize.width: 480
                                            sourceSize.height: 480
                                            opacity: status === Image.Ready ? 1.0 : 0.0

                                            Behavior on opacity { NumberAnimation { duration: 200 } }
                                        }

                                        Text {
                                            anchors.centerIn: parent
                                            visible: clipImg.status === Image.Error
                                            text: tr("clip.failed")
                                            color: panel.colText
                                            opacity: 0.6
                                            font.pixelSize: 10
                                            font.family: panel.fontFamily
                                        }
                                    }

                                    Text {
                                        visible: !slotItem.isImage
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        text: slotItem.text
                                        color: panel.colText
                                        font.pixelSize: 11
                                        font.family: panel.fontFamily
                                        wrapMode: Text.Wrap
                                        elide: Text.ElideRight
                                        maximumLineCount: 10
                                        verticalAlignment: Text.AlignTop
                                    }

                                    Text {
                                        Layout.alignment: Qt.AlignRight
                                        text: slotItem.footText
                                        color: panel.colText
                                        opacity: 0.55
                                        font.pixelSize: 10
                                        font.family: panel.fontFamily
                                    }
                                }
                            }
                        }
                    }

                    Keys.onLeftPressed: if (currentIndex > 0) currentIndex--
                    Keys.onRightPressed: if (currentIndex < count - 1) currentIndex++
                    Keys.onReturnPressed: panel.pickCurrent()
                    Keys.onDeletePressed: panel.dismissCurrent()
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
