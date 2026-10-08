import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../bar"
import "../notifications"
import "../settings"
import "../common"
import "../lang"
import "../icons"

// окошко сработавшего будильника: стеклянная карточка с блюром (тот же BarBlur
// и LiveBackdrop что у календаря), без рамки.
// создаётся из Calendar.qml, сам ничего не хранит: Calendar зовёт show(),
// а «Отложить» возвращается сигналом snoozeRequested.
PanelWindow {
    id: cw

    required property string colBg
    required property string colAccent
    required property string colText
    required property color colGlass

    property string wallpaper: ""
    property bool blurEnabled: true
    property real blurRadius: 16
    property color blurTint: Qt.rgba(0.05, 0.05, 0.07, 0.25)

    property string fontFamily: "JetBrainsMono Nerd Font, Monospace"
    property real cr: 6

    property int snoozeMin: 5
    property string sound: ""
    property int soundRepeats: 1     // сколько раз играть звук (1 = один раз)
    property int ringActive: 0       // сколько карточек ещё не закрыто

    signal snoozeRequested(string label)

    function t(key, fb) {
        const v = Tr.tr(key)
        return (v && v !== key) ? v : fb
    }

    // окно
    readonly property int topGap: 22
    readonly property real winX: screen ? (screen.width - implicitWidth) / 2 : 0
    readonly property real winY: topGap

    visible: ringModel.count > 0
    anchors { top: true }
    margins { top: cw.topGap }
    implicitWidth: 380
    implicitHeight: Math.max(1, ringCol.implicitHeight + 20)
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "calendar-alarm"

    // карточки
    ListModel { id: ringModel }

    function show(aid, timeText, label, note) {
        ringModel.append({
            aid: aid,
            timeText: timeText,
            label: label,
            note: note,
            closing: false
        })
        ringActive++
        if (sound !== "" && soundRepeats > 0 && !soundProc.running)
            soundProc.running = true
    }

    function closeRing(id) {
        for (let i = 0; i < ringModel.count; i++) {
            const r = ringModel.get(i)
            if (r.aid === id && !r.closing) {
                ringModel.setProperty(i, "closing", true)
                ringActive = Math.max(0, ringActive - 1)
                break
            }
        }
        if (ringActive === 0) soundProc.running = false
    }

    function purgeRing(id) {
        for (let i = 0; i < ringModel.count; i++) {
            if (ringModel.get(i).aid === id) {
                ringModel.remove(i)
                break
            }
        }
    }

    function snooze(id, label) {
        snoozeRequested(label)
        closeRing(id)
    }

    // звук
    Process {
        id: soundProc
        command: ["sh", "-c",
            'n=$2; i=0; while [ "$i" -lt "$n" ]; do pw-play "$1" 2>/dev/null || paplay "$1" 2>/dev/null || break; i=$((i+1)); [ "$i" -lt "$n" ] && sleep 0.6; done',
            "sh", cw.sound, String(cw.soundRepeats)]
    }

    // картинка за стеклом, живёт только пока окно открыто
    Loader {
        id: bd
        active: cw.blurEnabled && ringModel.count > 0

        sourceComponent: LiveBackdrop {
            screenObj: cw.screen
            wallpaper: cw.wallpaper
            autoDetect: false
            active: true
            roi: Qt.rect(cw.winX, cw.winY, cw.implicitWidth, cw.implicitHeight)
            pollInterval: 700
            texScale: 0.5
            x: -width - 64
            y: -height - 64
        }
    }
    readonly property Item bdItem: bd.item

    Column {
        id: ringCol
        x: 10
        y: 10
        width: parent.width - 20
        spacing: 0

        Repeater {
            model: ringModel

            Item {
                id: rc
                required property string aid
                required property string timeText
                required property string label
                required property string note
                required property bool closing

                property real e: 0
                width: ringCol.width
                height: card.implicitHeight + 10
                clip: true


                NumberAnimation on e { from: 0; to: 1; duration: 420; easing.type: Easing.OutBack }

                onClosingChanged: if (closing) outAnim.start()


                ParallelAnimation {
                    id: outAnim
                    NumberAnimation { target: rc; property: "e"; to: 0; duration: 220; easing.type: Easing.InCubic }
                    NumberAnimation { target: rc; property: "height"; to: 0; duration: 260; easing.type: Easing.OutCubic }
                    onFinished: cw.purgeRing(rc.aid)
                }

                BarBlur {
                    source: (cw.blurEnabled && cw.bdItem && cw.bdItem.width > 0) ? cw.bdItem.texture : null
                    srcSize: cw.bdItem ? Qt.size(cw.bdItem.width, cw.bdItem.height) : Qt.size(0, 0)
                    originX: cw.winX + ringCol.x + rc.x
                    originY: cw.winY + ringCol.y + rc.y
                    rect: ({ x: card.x, y: card.y, w: card.width, h: card.height })
                    corners: Qt.vector4d(card.radius, card.radius, card.radius, card.radius)
                    blurRadius: cw.blurRadius
                    tint: cw.blurTint
                    strength: card.opacity
                }

                Rectangle {
                    id: card
                    width: parent.width
                    implicitHeight: content.implicitHeight + 28
                    y: (1 - rc.e) * -18
                    opacity: Math.max(0, Math.min(1, rc.e))
                    radius: cw.cr
                    // без блюра стекло лежит на тёмной подложке, иначе текст не читается
                    color: cw.blurEnabled ? cw.colGlass
                                          : Qt.tint(Qt.rgba(0.06, 0.06, 0.08, 0.92), cw.colGlass)

                    Column {
                        id: content
                        x: 14
                        y: 14
                        width: parent.width - 28
                        spacing: 10

                        Row {
                            spacing: 12

                            Item {
                                width: 38
                                height: 38

                                Rectangle {
                                    anchors.fill: parent
                                    radius: width / 2
                                    color: Qt.alpha(cw.colAccent, 0.18)
                                }
                                Text {
                                    anchors.centerIn: parent
                                    text: "\uf0f3"
                                    color: cw.colAccent
                                    font.pixelSize: 18
                                    font.family: cw.fontFamily
                                    transformOrigin: Item.Top

                                    SequentialAnimation on rotation {
                                        loops: Animation.Infinite
                                        running: !rc.closing
                                        NumberAnimation { to: 16; duration: 80 }
                                        NumberAnimation { to: -16; duration: 160 }
                                        NumberAnimation { to: 12; duration: 130 }
                                        NumberAnimation { to: -8; duration: 120 }
                                        NumberAnimation { to: 0; duration: 80 }
                                        PauseAnimation { duration: 900 }
                                    }
                                }
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1

                                Text {
                                    text: rc.timeText
                                    color: cw.colText
                                    font.pixelSize: 22
                                    font.bold: true
                                    font.family: cw.fontFamily
                                }
                                Text {
                                    text: cw.t("cal.alarmRing", "Будильник")
                                    color: Qt.alpha(cw.colText, 0.55)
                                    font.pixelSize: 10
                                    font.bold: true
                                    font.family: cw.fontFamily
                                }
                            }
                        }

                        Text {
                            visible: rc.label !== ""
                            width: parent.width
                            wrapMode: Text.Wrap
                            text: rc.label
                            color: cw.colText
                            font.pixelSize: 13
                            font.bold: true
                            font.family: cw.fontFamily
                        }

                        Text {
                            visible: rc.note !== ""
                            width: parent.width
                            wrapMode: Text.Wrap
                            maximumLineCount: 3
                            elide: Text.ElideRight
                            text: rc.note
                            color: Qt.alpha(cw.colText, 0.65)
                            font.pixelSize: 11
                            font.family: cw.fontFamily
                        }

                        Row {
                            width: parent.width
                            spacing: 8

                            Rectangle {
                                width: (parent.width - parent.spacing) / 2
                                height: 32
                                radius: cw.cr
                                color: snMa.containsMouse ? Qt.alpha(cw.colText, 0.16) : Qt.alpha(cw.colText, 0.08)

                                Behavior on color { ColorAnimation { duration: 150 } }

                                Text {
                                    anchors.centerIn: parent
                                    text: cw.t("cal.snooze", "Отложить") + " " + cw.snoozeMin + cw.t("cal.min", " мин")
                                    color: cw.colText
                                    font.pixelSize: 11
                                    font.bold: true
                                    font.family: cw.fontFamily
                                }

                                MouseArea {
                                    id: snMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: cw.snooze(rc.aid, rc.label)
                                }
                            }

                            Rectangle {
                                width: (parent.width - parent.spacing) / 2
                                height: 32
                                radius: cw.cr
                                color: okMa.containsMouse ? Qt.lighter(cw.colAccent, 1.15) : cw.colAccent

                                Behavior on color { ColorAnimation { duration: 150 } }

                                Text {
                                    anchors.centerIn: parent
                                    text: cw.t("cal.dismiss", "Выключить")
                                    color: cw.colBg
                                    font.pixelSize: 11
                                    font.bold: true
                                    font.family: cw.fontFamily
                                }

                                MouseArea {
                                    id: okMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: cw.closeRing(rc.aid)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
