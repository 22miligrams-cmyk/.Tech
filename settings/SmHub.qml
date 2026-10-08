// Главный экран настроек: карусель из трёх больших карточек разделов (бар, лаунчеры, бинды).
// Листается стрелками, колесом и мышью, Enter или клик по центральной карточке открывает раздел.
import QtQuick
import QtQuick.Layouts
import "../icons"

ListView {
    id: hubGrid
    required property var menu
    readonly property string colBg: menu.colBg
    readonly property string colAccent: menu.colAccent
    readonly property string colText: menu.colText
    readonly property string colSecondary: menu.colSecondary
    Layout.fillWidth: true
    Layout.preferredHeight: 340
    orientation: ListView.Horizontal
    spacing: 0
    clip: false

    cacheBuffer: Math.max(1600, count * 290)

    preferredHighlightBegin: width / 2 - 175
    preferredHighlightEnd: width / 2 + 175
    highlightRangeMode: ListView.StrictlyEnforceRange
    highlightMoveDuration: 100

    model: menu.view === "hub" ? menu.hubModel : []

    delegate: Item {
        id: hubItem
        required property var modelData
        required property int index

        width: index === hubGrid.currentIndex ? 340 : 280
        height: 340
        z: index === hubGrid.currentIndex ? 100 : 50 - Math.abs(index - hubGrid.currentIndex)

        Behavior on width { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

        Item {
            id: hubCard
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.horizontalCenterOffset: depthX
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: baseOffset
            width: 280
            height: 320

            property bool isCurrent: hubItem.index === hubGrid.currentIndex

            property int dist: Math.abs(hubItem.index - hubGrid.currentIndex)
            property bool ready: false

            Component.onCompleted: {
                let centerIdx = hubGrid.currentIndex >= 0 ? hubGrid.currentIndex : Math.floor(hubGrid.count / 2)
                let distance = Math.abs(hubItem.index - centerIdx)
                hubStart.interval = 50 + (Math.min(distance, 6) * 35)
                hubStart.start()
            }
            Timer { id: hubStart; onTriggered: hubCard.ready = true }

            visible: dist <= 5

            property real depthX: {
                if (!ready || isCurrent) return 0
                let side = hubItem.index > hubGrid.currentIndex ? -1 : 1
                let actual = dist * 280 + 30
                let target = menu.hubDepthNear + (dist - 1) * menu.hubDepthStep
                return side * Math.max(0, actual - target)
            }
            Behavior on depthX { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

            property real rotAngle: {
                if (!ready) return 90
                if (isCurrent) return 0
                return hubItem.index - hubGrid.currentIndex > 0 ? -35 : 35
            }

            opacity: !ready ? 0.0 : (isCurrent ? 1.0 : Math.max(0.12, 0.5 - (dist - 1) * 0.1))
            scale: !ready ? 0.7 : (isCurrent ? 1.12 : Math.max(0.6, 0.85 - (dist - 1) * 0.06))

            property real baseOffset: !ready ? 30 : (isCurrent ? -10 : Math.min(dist, 4) * 8)
            Behavior on baseOffset { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

            transform: Rotation {
                origin.x: hubCard.width / 2
                origin.y: hubCard.height / 2
                axis { x: 0; y: 1; z: 0 }
                angle: hubCard.rotAngle
            }

            Behavior on rotAngle { NumberAnimation { duration: 400; easing.type: Easing.OutBack } }
            Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

            Rectangle {
                anchors.fill: parent
                radius: 14
                color: Qt.alpha(colSecondary, hubCard.isCurrent ? 0.9 : 0.4)
                Behavior on color { ColorAnimation { duration: 150 } }

                ColumnLayout {
                    anchors.centerIn: parent
                    width: parent.width - 40
                    spacing: 16

                    Icon {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: 64
                        Layout.preferredHeight: 64
                        name: hubItem.modelData.icon
                        size: 64
                        color: colAccent
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: menu.tr("hub." + hubItem.modelData.id + ".label")
                        color: colText
                        font.pixelSize: 20
                        font.bold: true
                        font.family: "JetBrainsMono Nerd Font, Monospace"
                    }

                    Text {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: menu.tr("hub." + hubItem.modelData.id + ".desc")
                        color: colText
                        opacity: 0.6
                        font.pixelSize: 11
                        font.family: "JetBrainsMono Nerd Font, Monospace"
                    }
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (hubCard.isCurrent) menu.enterSection(hubItem.modelData.id)
                    else hubGrid.currentIndex = hubItem.index
                }
            }
        }
    }

    Keys.onLeftPressed: if (currentIndex > 0) currentIndex--
    Keys.onRightPressed: if (currentIndex < count - 1) currentIndex++
    Keys.onTabPressed: currentIndex = (currentIndex + 1) % count
    Keys.onReturnPressed: { const it = model[currentIndex]; if (it) menu.enterSection(it.id) }
    Keys.onEnterPressed: { const it = model[currentIndex]; if (it) menu.enterSection(it.id) }
    Keys.onEscapePressed: menu.toggleMenu()

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: (event) => {
            const delta = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x
            if (delta > 0 && hubGrid.currentIndex > 0) hubGrid.currentIndex--
            else if (delta < 0 && hubGrid.currentIndex < hubGrid.count - 1) hubGrid.currentIndex++
            event.accepted = true
        }
    }
}
