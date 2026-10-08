// Одна карточка в карусели настроек. В зависимости от типа показывает тумблер, слайдер,
// значение-цикл, клавиши бинда или кнопку «добавить». У некоторых карточек раскрывается
// подменю снизу. Положение, поворот и прозрачность зависят от расстояния до текущей карточки.
import QtQuick
import QtQuick.Layouts
import "../icons"

Item {
    id: root
    required property var menu
    required property var grid
    readonly property string colBg: menu.colBg
    readonly property string colAccent: menu.colAccent
    readonly property string colText: menu.colText
    readonly property string colSecondary: menu.colSecondary

    required property var modelData
    required property int index

    width: 200
    height: 260
    z: index === grid.currentIndex ? 100 : 50 - Math.abs(index - grid.currentIndex)

    property bool removing: false

    Item {
        id: cardContainer
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: depthX
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: baseOffset + extra * 0.56
        width: 200
        height: 240 + extra

        property bool settle: menu.removeSettling
        Connections {
            target: menu
            // когда закончилось удаление, карточка перестаёт «доживать» старые индексы
            function onRemoveSettlingChanged() { if (!menu.removeSettling) cardContainer.settle = false }
        }
        property int effIndex: (settle && index >= menu.removedAt) ? index + 1 : index
        property int effCur: settle ? menu.removedAt : grid.currentIndex

        property bool isCurrent: effIndex === effCur

        property int dist: Math.abs(effIndex - effCur)
        property bool isActive: modelData.get() || kind === "keybind" || kind === "add"

        readonly property string kind: modelData.kind ? modelData.kind
            : ((modelData.id === "pos" || modelData.id === "alpha" || modelData.id === "blurpx") ? "special" : "toggle")

        readonly property bool isSlider: modelData.id === "alpha" || modelData.id === "blurpx" || kind === "slider"
        readonly property string sliderLabel: modelData.id === "alpha" ? Math.round(menu.barLayout.glassAlpha * 100) + "%"
            : modelData.id === "blurpx" ? Math.round(menu.blurStrength * 100) + "%"
            : (kind === "slider" ? modelData.text() : "")
        readonly property real sliderValue: modelData.id === "alpha" ? menu.barLayout.glassAlpha
            : modelData.id === "blurpx" ? menu.blurStrength
            : (kind === "slider" ? modelData.value() : 0)

        // передаёт новое значение слайдера туда, куда оно относится (прозрачность бара, блюр или свой setValue)
        function sliderSet(v) {
            if (modelData.id === "alpha") menu.barLayout.setGlassAlpha(v)
            else if (modelData.id === "blurpx") menu.blurCtl.setBlurStrength(v)
            else if (kind === "slider") modelData.setValue(v)
        }

        property bool ready: menu.cardsInstant

        readonly property var bs: modelData.bs ? modelData.bs() : null
        readonly property bool subShown: isCurrent && bs !== null && bs.subOpenId === modelData.id
        readonly property real subExtra: modelData.sub ? modelData.sub.length * 36 + 20 : 0
        property real extra: subShown ? subExtra : 0
        Behavior on extra { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

        Component.onCompleted: {
            settle = menu.removeSettling
            if (menu.cardsInstant) { ready = true; return }
            let centerIdx = grid.currentIndex >= 0 ? grid.currentIndex : Math.floor(grid.count / 2);
            let distance = Math.abs(index - centerIdx);
            startTimer.interval = 50 + (Math.min(distance, 6) * 35);
            startTimer.start();
        }

        Timer {
            id: startTimer
            onTriggered: cardContainer.ready = true
        }

        readonly property int moveMs: 360
        readonly property int fadeMs: 260

        visible: opacity > 0.01

        property real depthX: {
            if (!ready) return 0;
            const realCur = grid.currentIndex
            const layoutOff = (index - realCur) * 200
            const visOff = isCurrent ? 0
                : (effIndex > effCur ? 1 : -1) * (menu.setDepthNear + (dist - 1) * menu.setDepthStep - 15)
            return visOff - layoutOff
        }
        Behavior on depthX { enabled: !menu.cardsInstant; NumberAnimation { duration: cardContainer.moveMs; easing.type: Easing.OutCubic } }

        property real rotAngle: {
            if (!ready) return 90;
            if (isCurrent) return 0;
            return effIndex - effCur > 0 ? -35 : 35;
        }

        opacity: {
            if (removing) return 0.0;
            if (!ready) return 0.0;
            return isCurrent ? 1.0 : Math.max(0.0, 0.5 - (dist - 1) * 0.1);
        }

        scale: {
            if (removing) return 0.5;
            if (!ready) return 0.7;
            return isCurrent ? 1.12 : Math.max(0.6, 0.85 - (dist - 1) * 0.06);
        }

        property real baseOffset: removing ? 70 : !ready ? 30 : (isCurrent ? -10 : Math.min(dist, 4) * 8)
        Behavior on baseOffset { enabled: !menu.cardsInstant; NumberAnimation { duration: cardContainer.moveMs; easing.type: Easing.OutCubic } }

        transform: Rotation {
            origin.x: cardContainer.width / 2
            origin.y: cardContainer.height / 2
            axis { x: 0; y: 1; z: 0 }
            angle: cardContainer.rotAngle
        }

        Behavior on rotAngle { enabled: !menu.cardsInstant; NumberAnimation { duration: cardContainer.moveMs; easing.type: Easing.OutCubic } }
        Behavior on opacity { enabled: !menu.cardsInstant; NumberAnimation { duration: cardContainer.fadeMs; easing.type: Easing.OutCubic } }
        Behavior on scale { enabled: !menu.cardsInstant; NumberAnimation { duration: cardContainer.moveMs; easing.type: Easing.OutCubic } }

        Rectangle {
            anchors.fill: parent
            radius: 14
            z: 1

            scale: cardMouse.pressed ? 0.97 : 1.0
            Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

            color: Qt.alpha(cardContainer.isActive ? colSecondary : colBg,
                            cardContainer.isCurrent ? 0.9 : (cardMouse.containsMouse ? 0.6 : 0.4))
            Behavior on color { ColorAnimation { duration: 150 } }

            ColumnLayout {
                anchors.centerIn: parent
                anchors.verticalCenterOffset: -cardContainer.extra / 2
                width: parent.width - 30
                spacing: 18

                Icon {
                    visible: !!modelData.svg
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: 42
                    Layout.preferredHeight: 42
                    name: modelData.svg ? modelData.svg : ""
                    size: 42
                    color: cardContainer.isActive ? colAccent : colText
                }

                Text {
                    visible: modelData.id !== "pos" && !modelData.svg
                    Layout.alignment: Qt.AlignHCenter
                    text: modelData.icon ? modelData.icon : ""
                    color: cardContainer.isActive ? colAccent : colText
                    font.pixelSize: 38
                }

                Loader {
                    active: cardContainer.kind === "keybind"
                    visible: active
                    Layout.fillWidth: true
                    Layout.preferredHeight: 24
                    sourceComponent: SmKeyChips {
                        keys: modelData.keys()
                        colBg: root.colBg
                        colAccent: root.colAccent
                        colText: root.colText
                    }
                }

                Loader {
                    active: modelData.id === "pos"
                    visible: active
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: 160
                    Layout.preferredHeight: 112
                    sourceComponent: SmPosPicker {
                        pos: menu.barLayout.position
                        colBg: root.colBg
                        colAccent: root.colAccent
                        colText: root.colText
                        colSecondary: root.colSecondary
                        onPicked: (side) => { grid.currentIndex = index; menu.barLayout.setPosition(side) }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: modelData.label ? modelData.label : menu.tr("item." + modelData.id)
                    color: colText
                    font.pixelSize: 13
                    font.bold: true
                    font.family: "JetBrainsMono Nerd Font, Monospace"
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                }

                Text {
                    visible: modelData.id === "pos"
                    Layout.alignment: Qt.AlignHCenter
                    text: menu.tr("pos." + menu.barLayout.position)
                    color: colAccent
                    font.pixelSize: 12
                    font.bold: true
                    font.family: "JetBrainsMono Nerd Font, Monospace"
                }

                Loader {
                    active: cardContainer.isSlider
                    visible: active
                    Layout.alignment: Qt.AlignHCenter
                    sourceComponent: SmSlider {
                        colBg: root.colBg
                        colAccent: root.colAccent
                        colText: root.colText
                        label: cardContainer.sliderLabel
                        labelOpacity: (modelData.id === "blurpx" && !menu.blurEnabled) ? 0.45 : 1.0
                        value: cardContainer.sliderValue
                        onActivated: grid.currentIndex = index
                        onValueRequested: (v) => cardContainer.sliderSet(v)
                    }
                }

                Text {
                    visible: modelData.id === "alpha" || modelData.id === "blurpx" || cardContainer.kind === "slider"
                    Layout.alignment: Qt.AlignHCenter
                    text: menu.tr("ui.slider")
                    color: colText
                    opacity: 0.55
                    font.pixelSize: 9
                    font.family: "JetBrainsMono Nerd Font, Monospace"
                }

                Text {
                    visible: cardContainer.kind === "cycle"
                    Layout.alignment: Qt.AlignHCenter
                    text: cardContainer.kind === "cycle" ? modelData.valueText() : ""
                    color: colAccent
                    font.pixelSize: 16
                    font.bold: true
                    font.family: "JetBrainsMono Nerd Font, Monospace"
                }

                Text {
                    visible: cardContainer.kind === "cycle"
                    Layout.alignment: Qt.AlignHCenter
                    text: modelData.hint ? modelData.hint : menu.tr("ui.next")
                    color: colText
                    opacity: 0.55
                    font.pixelSize: 9
                    font.family: "JetBrainsMono Nerd Font, Monospace"
                }

                SmToggle {
                    visible: cardContainer.kind === "toggle"
                    Layout.alignment: Qt.AlignHCenter
                    active: cardContainer.isActive
                    colBg: root.colBg
                    colAccent: root.colAccent
                    colSecondary: root.colSecondary
                }
            }

            Text {
                visible: cardContainer.isCurrent && cardContainer.bs !== null && !cardContainer.subShown
                anchors.top: parent.top
                anchors.topMargin: 6
                anchors.horizontalCenter: parent.horizontalCenter
                text: "⌃"
                color: colAccent
                opacity: 0.7
                font.pixelSize: 14
                font.bold: true
            }

            Item {
                id: subArea
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: cardContainer.extra
                clip: true
                visible: cardContainer.extra > 1 && subLoader.status === Loader.Ready
                opacity: cardContainer.subExtra > 0
                    ? Math.max(0, Math.min(1, (cardContainer.extra / cardContainer.subExtra - 0.3) / 0.7)) : 0

                Loader {
                    id: subLoader
                    anchors.fill: parent
                    active: !!modelData.sub && (cardContainer.subShown || cardContainer.extra > 1)
                    sourceComponent: Component {
                        Column {
                            id: subCol
                            anchors.fill: parent
                            anchors.topMargin: 12
                            anchors.bottomMargin: 8
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 0

                            Repeater {
                                model: modelData.sub ? modelData.sub : []

                                delegate: Rectangle {
                                    id: subRow
                                    required property var modelData
                                    required property int index
                                    readonly property var s: modelData
                                    readonly property bool sel: cardContainer.subShown && cardContainer.bs.subIndex === index

                                    width: subCol.width
                                    height: 36
                                    radius: 10
                                    color: sel ? Qt.rgba(0, 0, 0, 0.28) : "transparent"
                                    Behavior on color { ColorAnimation { duration: 100 } }

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 6
                                        anchors.rightMargin: 8
                                        spacing: 8

                                        Rectangle {
                                            Layout.preferredWidth: 22
                                            Layout.preferredHeight: 22
                                            radius: 6
                                            color: subRow.sel ? root.colAccent : Qt.rgba(1, 1, 1, 0.12)

                                            Text {
                                                anchors.centerIn: parent
                                                text: (subRow.index + 1).toString()
                                                color: subRow.sel ? root.colBg : root.colText
                                                font.pixelSize: 12
                                                font.bold: true
                                                font.family: "JetBrainsMono Nerd Font, Monospace"
                                            }
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            text: subRow.s.label ? subRow.s.label : menu.tr("item." + subRow.s.id)
                                            color: root.colText
                                            font.pixelSize: 12
                                            font.bold: true
                                            font.family: "JetBrainsMono Nerd Font, Monospace"
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            visible: !!subRow.s.valueText
                                            text: subRow.s.valueText
                                                ? ((subRow.sel ? "‹ " : "") + subRow.s.valueText() + (subRow.sel ? " ›" : ""))
                                                : ""
                                            color: root.colAccent
                                            font.pixelSize: 12
                                            font.bold: true
                                            font.family: "JetBrainsMono Nerd Font, Monospace"
                                        }

                                        Rectangle {
                                            visible: !subRow.s.valueText
                                            Layout.preferredWidth: 10
                                            Layout.preferredHeight: 10
                                            radius: 5
                                            color: subRow.s.get() ? root.colAccent : Qt.alpha(root.colText, 0.3)
                                        }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onEntered: if (cardContainer.subShown) cardContainer.bs.subIndex = subRow.index
                                        onClicked: (mouse) => {
                                            cardContainer.bs.subIndex = subRow.index
                                            if (subRow.s.kind === "step") subRow.s.step(mouse.x < width / 2 ? -1 : 1)
                                            else cardContainer.bs.applySub()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        MouseArea {
            id: cardMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (cardContainer.subShown) { cardContainer.bs.closeSub(); return }
                grid.currentIndex = index;
                if (cardContainer.kind === "toggle" || cardContainer.kind === "cycle" || cardContainer.kind === "keybind" || cardContainer.kind === "add")
                    modelData.set(!modelData.get());
            }
        }
    }
}
