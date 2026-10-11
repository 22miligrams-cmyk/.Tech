import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import "../bar"
import "../notifications"
import "../settings"
import "../common"
import "../lang"
import "../icons"

PanelWindow {
    id: vp

    function tr(key) { return Tr.tr(key) }

    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary
    required property color colGlass

    property string side: "bottom"

    property var anchorRect: ({ x: 0, y: 0, w: 0, h: 0, lo: 0, hi: 0 })

    // эффект глубины: содержимое панели наклоняется и сдвигается за курсором (Visual.qml: parallaxAllowed).
    // стекло панели не двигается: оно приросло к бару и обрезается по его краю, поэтому крутится только контент
    property bool parallaxAllowed: true
    property real camShiftX: 5
    property real camShiftY: 4
    property real camTilt: 3.0
    readonly property real camTargetX: (parallaxAllowed && camHover.hovered && panel.width > 0)
        ? Math.max(0, Math.min(1, camHover.point.position.x / panel.width)) * 2 - 1 : 0
    readonly property real camTargetY: (parallaxAllowed && camHover.hovered && panel.height > 0)
        ? Math.max(0, Math.min(1, camHover.point.position.y / panel.height)) * 2 - 1 : 0
    property real camX: camTargetX
    property real camY: camTargetY
    Behavior on camX { SmoothedAnimation { velocity: 2.2; maximumEasingTime: 300 } }
    Behavior on camY { SmoothedAnimation { velocity: 2.2; maximumEasingTime: 300 } }

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource
    readonly property var sinkAudio: sink && sink.audio ? sink.audio : null
    readonly property var sourceAudio: source && source.audio ? source.audio : null

    readonly property var sinks: {
        const out = []
        const all = Pipewire.nodes.values
        for (let i = 0; i < all.length; i++) {
            const n = all[i]
            if (n.isSink && !n.isStream) out.push(n)
        }
        return out
    }

    property var eq: null
    readonly property bool eqOn: eq ? eq.eqOn : false
    readonly property string eqTarget: eq ? eq.eqTarget : ""
    readonly property var realSinks: eq ? eq.realSinks : sinks
    readonly property var realSink: eq ? eq.realSink : sink

    function selectDevice(node) {
        if (eq) eq.selectDevice(node)
        else Pipewire.preferredDefaultAudioSink = node
    }

    PwObjectTracker {
        objects: vp.visible ? [vp.sink, vp.source].concat(vp.sinks) : []
    }

    function glyph(cp) {
        return String.fromCodePoint(cp)
    }

    // сколько волн рисовать у динамика (SlashIcon.waves), без учёта mute: mute рисуется перечёркиванием.
    // Когда число волн падает, лишняя стирается сверху вниз
    function volWaves(audio) {
        if (!audio || audio.volume <= 0.001) return 0
        return audio.volume < 0.34 ? 1 : 2
    }

    function volIcon(audio) {
        if (!audio || audio.muted || audio.volume <= 0) return "volumeMute"
        if (audio.volume < 0.34) return "volumeLow"
        if (audio.volume < 0.67) return "volumeMid"
        return "volume"
    }

    function nodeName(n) {
        if (!n) return ""
        return n.description || n.nickname || n.name || ""
    }

    function clamp01(v) {
        return Math.max(0, Math.min(1, v))
    }

    function setVol(audio, v) {
        if (!audio) return
        audio.volume = clamp01(v)
        if (audio.muted && v > 0) audio.muted = false
    }

    function toggleMute(audio) {
        if (audio) audio.muted = !audio.muted
    }

    readonly property bool horiz: side === "top" || side === "bottom"
    readonly property real pad: 14
    readonly property real cr: 6
    readonly property real edge: 16
    readonly property real pw: Math.min(horiz ? Math.max(300, anchorRect.w) : 300, width - 16)
    // на боковом баре высота считается по длине блока, как ширина на нижнем (но не меньше содержимого)
    readonly property real ph: Math.min(horiz ? body.implicitHeight + pad * 2 : Math.max(body.implicitHeight + pad * 2, anchorRect.h), height - 16)
    // отступ от края экрана: 16, а если панель на всю длину бара - 8, чтобы совпасть с его краями
    readonly property real edgeX: pw >= width - 16.5 ? 8 : edge
    readonly property real edgeY: ph >= height - 16.5 ? 8 : edge

    function clamp(v, lo, hi) {
        return Math.max(lo, Math.min(v, hi))
    }

    readonly property real floatGap: 8
    readonly property bool fused: horiz ? anchorRect.w >= pw - 0.5 : anchorRect.h >= ph - 0.5
    readonly property real gapNow: fused ? 0 : floatGap

    readonly property real px: side === "left" ? anchorRect.x + anchorRect.w + gapNow
        : side === "right" ? anchorRect.x - pw - gapNow
        : clamp(anchorRect.x + anchorRect.w / 2 - pw / 2, edgeX, width - edgeX - pw)

    readonly property real py: side === "bottom" ? anchorRect.y - ph - gapNow
        : side === "top" ? anchorRect.y + anchorRect.h + gapNow
        : clamp(anchorRect.y + anchorRect.h / 2 - ph / 2, edgeY, height - edgeY - ph)

    function sq(v) {
        return fused && v >= anchorRect.lo - 0.5 && v <= anchorRect.hi + 0.5
    }

    readonly property bool covers: fused && (horiz
        ? (px <= anchorRect.x + 0.5 && px + pw >= anchorRect.x + anchorRect.w - 0.5)
        : (py <= anchorRect.y + 0.5 && py + ph >= anchorRect.y + anchorRect.h - 0.5))

    property bool isClosing: false
    property real p: 0

    function toggleMenu() {
        if (isClosing)
            return

        if (visible) {
            isClosing = true
            openAnim.stop()
            closeAnim.start()
        } else {
            p = 0
            visible = true
            openAnim.restart()
            keys.forceActiveFocus()
        }
    }

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
    WlrLayershell.namespace: "volume-menu"
    visible: false

    property string wallpaper: ""
    property bool blurEnabled: true
    property real blurRadius: 16
    property color blurTint: Qt.rgba(0.05, 0.05, 0.07, 0.25)

    LiveBackdrop {
        id: backdrop
        screenObj: vp.screen
        wallpaper: vp.wallpaper
        autoDetect: false
        active: vp.visible && vp.blurEnabled
        roi: Qt.rect(vp.px, vp.py, vp.pw, vp.ph)
        pollInterval: 700
        texScale: 0.5
        x: -width - 64
        y: -height - 64
    }

    Item {
        id: keys
        anchors.fill: parent
        focus: true

        Keys.onEscapePressed: vp.toggleMenu()
        Keys.onUpPressed: vp.setVol(vp.sinkAudio, (vp.sinkAudio ? vp.sinkAudio.volume : 0) + 0.05)
        Keys.onRightPressed: vp.setVol(vp.sinkAudio, (vp.sinkAudio ? vp.sinkAudio.volume : 0) + 0.05)
        Keys.onDownPressed: vp.setVol(vp.sinkAudio, (vp.sinkAudio ? vp.sinkAudio.volume : 0) - 0.05)
        Keys.onLeftPressed: vp.setVol(vp.sinkAudio, (vp.sinkAudio ? vp.sinkAudio.volume : 0) - 0.05)
        Keys.onPressed: (e) => {
            if (e.key === Qt.Key_M) vp.toggleMute(vp.sinkAudio)
        }

        MouseArea {
            anchors.fill: parent
            onClicked: vp.toggleMenu()
        }

        NumberAnimation {
            id: openAnim
            target: vp
            property: "p"
            to: 1
            duration: 280
            easing.type: Easing.OutCubic
        }


        NumberAnimation {
            id: closeAnim
            target: vp
            property: "p"
            to: 0
            duration: 200
            easing.type: Easing.InCubic
            onFinished: {
                vp.visible = false
                vp.isClosing = false
            }
        }

        Item {
            id: holder
            x: vp.px
            y: vp.py
            width: vp.pw
            height: vp.ph
            clip: true

            BarBlur {
                source: (vp.blurEnabled && backdrop.width > 0) ? backdrop.texture : null
                srcSize: Qt.size(backdrop.width, backdrop.height)
                originX: holder.x
                originY: holder.y
                rect: ({ x: panel.x, y: panel.y, w: panel.width, h: panel.height })
                corners: Qt.vector4d(panel.topLeftRadius, panel.topRightRadius,
                                     panel.bottomRightRadius, panel.bottomLeftRadius)
                blurRadius: vp.blurRadius
                tint: vp.blurTint
                strength: panel.opacity
            }

            Rectangle {
                id: panel
                width: holder.width
                height: holder.height

                x: vp.side === "left" ? -(1 - vp.p) * width
                 : vp.side === "right" ? (1 - vp.p) * width : 0
                y: vp.side === "bottom" ? (1 - vp.p) * height
                 : vp.side === "top" ? -(1 - vp.p) * height : 0
                opacity: Math.min(1, vp.p * 2.5)

                color: vp.colGlass

                Behavior on color { ColorAnimation { duration: 400 } }

                topLeftRadius: ((vp.side === "top" && vp.sq(vp.px)) || (vp.side === "left" && vp.sq(vp.py))) ? 0 : vp.cr
                topRightRadius: ((vp.side === "top" && vp.sq(vp.px + vp.pw)) || (vp.side === "right" && vp.sq(vp.py))) ? 0 : vp.cr
                bottomLeftRadius: ((vp.side === "bottom" && vp.sq(vp.px)) || (vp.side === "left" && vp.sq(vp.py + vp.ph))) ? 0 : vp.cr
                bottomRightRadius: ((vp.side === "bottom" && vp.sq(vp.px + vp.pw)) || (vp.side === "right" && vp.sq(vp.py + vp.ph))) ? 0 : vp.cr

                HoverHandler { id: camHover }

                MouseArea {
                    anchors.fill: parent
                    onClicked: (mouse) => mouse.accepted = true
                }

                WheelHandler {
                    onWheel: (e) => vp.setVol(vp.sinkAudio,
                        (vp.sinkAudio ? vp.sinkAudio.volume : 0) + (e.angleDelta.y > 0 ? 0.05 : -0.05))
                }
                Column {
                    id: body
                    transform: [
                        Translate { x: -vp.camX * vp.camShiftX; y: -vp.camY * vp.camShiftY },
                        Rotation {
                            origin.x: body.width / 2
                            origin.y: body.height / 2
                            axis { x: 0; y: 1; z: 0 }
                            angle: vp.camX * vp.camTilt
                        },
                        Rotation {
                            origin.x: body.width / 2
                            origin.y: body.height / 2
                            axis { x: 1; y: 0; z: 0 }
                            angle: -vp.camY * vp.camTilt
                        }
                    ]
                    x: vp.pad
                    y: vp.pad
                    width: parent.width - vp.pad * 2
                    spacing: 12

                    Column {
                        width: parent.width
                        spacing: 6

                        Text {
                            width: parent.width
                            text: vp.eqOn ? tr("mp.eq") + " · " + vp.nodeName(vp.realSink)
                                : (vp.sink ? vp.nodeName(vp.sink) : tr("vol.nooutput"))
                            color: Qt.alpha(vp.colText, 0.55)
                            font.pixelSize: 10
                            font.bold: true
                            font.family: vp.fontFamily
                            elide: Text.ElideRight
                        }

                        VolRow {
                            width: parent.width
                            audio: vp.sinkAudio
                            iconKind: "speaker"
                            iconWaves: vp.volWaves(vp.sinkAudio)
                            slashed: !vp.sinkAudio || vp.sinkAudio.muted || vp.sinkAudio.volume <= 0
                            fillColor: vp.colAccent
                            textColor: vp.colText
                            trackColor: Qt.alpha(vp.colText, 0.14)
                            fontFamily: vp.fontFamily
                            onSetVolume: (v) => vp.setVol(vp.sinkAudio, v)
                            onToggleMute: vp.toggleMute(vp.sinkAudio)
                        }
                    }

                    Column {
                        visible: vp.source !== null && vp.source !== undefined && !vp.source.isSink
                        width: parent.width
                        spacing: 6

                        Text {
                            width: parent.width
                            text: tr("vol.mic") + " · " + vp.nodeName(vp.source)
                            color: Qt.alpha(vp.colText, 0.55)
                            font.pixelSize: 10
                            font.bold: true
                            font.family: vp.fontFamily
                            elide: Text.ElideRight
                        }
                        VolRow {
                            width: parent.width
                            audio: vp.sourceAudio
                            iconKind: "mic"
                            slashed: !vp.sourceAudio || vp.sourceAudio.muted
                            fillColor: vp.colAccent
                            textColor: vp.colText
                            trackColor: Qt.alpha(vp.colText, 0.14)
                            fontFamily: vp.fontFamily
                            onSetVolume: (v) => vp.setVol(vp.sourceAudio, v)
                            onToggleMute: vp.toggleMute(vp.sourceAudio)
                        }
                    }

                    Column {
                        visible: vp.realSinks.length > 1
                        width: parent.width
                        spacing: 4

                        Text {
                            text: tr("vol.outputs")
                            color: Qt.alpha(vp.colText, 0.55)
                            font.pixelSize: 10
                            font.bold: true
                            font.family: vp.fontFamily
                        }

                        Repeater {
                            model: vp.realSinks

                            Rectangle {
                                id: devRow
                                required property var modelData
                                readonly property bool current: vp.eqOn
                                    ? modelData.name === vp.eqTarget
                                    : (vp.sink !== null && modelData.id === vp.sink.id)

                                width: body.width
                                height: 30
                                radius: vp.cr
                                color: current ? Qt.alpha(vp.colAccent, 0.16)
                                     : (devMa.containsMouse ? Qt.alpha(vp.colText, 0.12) : Qt.alpha(vp.colText, 0.06))

                                Behavior on color { ColorAnimation { duration: 150 } }

                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.right: parent.right
                                    anchors.rightMargin: 10
                                    spacing: 8

                                    Rectangle {
                                        width: 6
                                        height: 6
                                        radius: 2
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: devRow.current ? vp.colAccent : Qt.alpha(vp.colText, 0.3)

                                        Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
                                    }

                                    Text {
                                        width: parent.width - 14
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: vp.nodeName(devRow.modelData)
                                        color: devRow.current ? vp.colAccent : vp.colText
                                        Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
                                        font.pixelSize: 11
                                        font.bold: devRow.current
                                        font.family: vp.fontFamily
                                        elide: Text.ElideRight
                                    }
                                }

                                MouseArea {
                                    id: devMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: vp.selectDevice(devRow.modelData)
                                }
                            }
                        }
                    }
                }
            }
        }
    }


    component VolRow: Item {
        id: row

        property var audio: null
        property string iconKind: "speaker" // что рисует SlashIcon: "mic" | "speaker"
        property int iconWaves: 99          // у динамика: сколько волн видно
        property bool slashed: false         // перечёркнуто (звук выключен / микрофон выключен)
        property color fillColor
        property color textColor
        property color trackColor
        property string fontFamily

        signal setVolume(real v)
        signal toggleMute()

        readonly property real value: audio ? audio.volume : 0
        readonly property bool muted: audio ? audio.muted : false

        height: 30


        Rectangle {
            id: muteBtn
            width: 30
            height: 30
            radius: 6
            color: muteMa.containsMouse ? Qt.alpha(row.textColor, 0.12) : Qt.alpha(row.textColor, 0.06)

            Behavior on color { ColorAnimation { duration: 150 } }

            readonly property color glyphColor: row.muted ? Qt.alpha(row.textColor, 0.55) : row.fillColor

            // иконка кодом: черта растёт по диагонали при выключении и стирается сверху вниз при включении
            SlashIcon {
                anchors.centerIn: parent
                kind: row.iconKind
                waves: row.iconWaves
                size: 16
                slashed: row.slashed
                color: muteBtn.glyphColor

                Behavior on color { ColorAnimation { duration: 300 } }
            }

            MouseArea {
                id: muteMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: row.toggleMute()
            }
        }

        // толстая полоска с водой (common/FatSlider.qml): без кругляшка, проценты по центру
        FatSlider {
            id: slider
            anchors.left: muteBtn.right
            anchors.leftMargin: 10
            anchors.right: parent.right
            height: parent.height

            value: row.value
            dimmed: row.muted
            usable: row.audio !== null
            colAccent: row.fillColor
            colText: row.textColor
            colBg: vp.colBg
            fontFamily: row.fontFamily
            radius: 6
            onMoved: (v) => row.setVolume(v)
            onWheeled: (dir) => row.setVolume(row.value + dir * 0.05)
        }
    }
}
