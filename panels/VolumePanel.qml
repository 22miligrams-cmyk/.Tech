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
    readonly property real pw: horiz ? Math.max(300, anchorRect.w) : 300
    readonly property real ph: body.implicitHeight + pad * 2

    function clamp(v, lo, hi) {
        return Math.max(lo, Math.min(v, hi))
    }

    readonly property real floatGap: 8
    readonly property bool fused: horiz ? anchorRect.w >= pw - 0.5 : anchorRect.h >= ph - 0.5
    readonly property real gapNow: fused ? 0 : floatGap

    readonly property real px: side === "left" ? anchorRect.x + anchorRect.w + gapNow
        : side === "right" ? anchorRect.x - pw - gapNow
        : clamp(anchorRect.x + anchorRect.w / 2 - pw / 2, 8, width - 8 - pw)

    readonly property real py: side === "bottom" ? anchorRect.y - ph - gapNow
        : side === "top" ? anchorRect.y + anchorRect.h + gapNow
        : clamp(anchorRect.y + anchorRect.h / 2 - ph / 2, 8, height - 8 - ph)

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

                topLeftRadius: ((vp.side === "top" && vp.sq(vp.px)) || (vp.side === "left" && vp.sq(vp.py))) ? 0 : vp.cr
                topRightRadius: ((vp.side === "top" && vp.sq(vp.px + vp.pw)) || (vp.side === "right" && vp.sq(vp.py))) ? 0 : vp.cr
                bottomLeftRadius: ((vp.side === "bottom" && vp.sq(vp.px)) || (vp.side === "left" && vp.sq(vp.py + vp.ph))) ? 0 : vp.cr
                bottomRightRadius: ((vp.side === "bottom" && vp.sq(vp.px + vp.pw)) || (vp.side === "right" && vp.sq(vp.py + vp.ph))) ? 0 : vp.cr

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
                    x: vp.pad
                    y: vp.pad
                    width: parent.width - vp.pad * 2
                    spacing: 12

                    Row {
                        spacing: 10
                        height: 28

                        Rectangle {
                            width: 28
                            height: 28
                            radius: vp.cr
                            color: vp.colSecondary

                            Icon {
                                anchors.centerIn: parent
                                name: vp.volIcon(vp.sinkAudio)
                                size: 15
                                color: vp.colAccent
                                dim: 1.3
                            }
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: tr("vol.title")
                            color: vp.colText
                            font.bold: true
                            font.pixelSize: 15
                            font.family: vp.fontFamily
                        }
                    }

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
                            icon: vp.volIcon(vp.sinkAudio)
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
                            icon: vp.sourceAudio && !vp.sourceAudio.muted ? "mic" : "micOff"
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
                                    }

                                    Text {
                                        width: parent.width - 14
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: vp.nodeName(devRow.modelData)
                                        color: devRow.current ? vp.colAccent : vp.colText
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
        property string icon: ""
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

            Icon {
                anchors.centerIn: parent
                name: row.icon
                size: 15
                color: row.muted ? Qt.alpha(row.textColor, 0.55) : row.fillColor
                dim: row.muted ? 1.0 : 1.3
            }

            MouseArea {
                id: muteMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: row.toggleMute()
            }
        }

        Item {
            id: slider
            anchors.left: muteBtn.right
            anchors.leftMargin: 10
            anchors.right: pct.left
            anchors.rightMargin: 10
            height: parent.height


            Rectangle {
                id: track
                width: parent.width
                height: 8
                radius: 4
                anchors.verticalCenter: parent.verticalCenter
                color: row.trackColor

                Rectangle {
                    width: Math.max(0, Math.min(1, row.value)) * parent.width
                    height: parent.height
                    radius: 4
                    color: row.fillColor
                    opacity: row.muted ? 0.35 : 1.0

                    Behavior on opacity { NumberAnimation { duration: 150 } }
                }
            }

            Rectangle {
                width: 14
                height: 14
                radius: 7
                anchors.verticalCenter: parent.verticalCenter
                x: Math.max(0, Math.min(1, row.value)) * (parent.width - width)
                color: row.muted ? Qt.alpha(row.textColor, 0.55) : row.fillColor
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                function apply(mx) {
                    row.setVolume(Math.max(0, Math.min(1, (mx - 7) / (width - 14))))
                }
                onPressed: (m) => apply(m.x)
                onPositionChanged: (m) => { if (pressed) apply(m.x) }
            }
        }
        Text {
            id: pct
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 38
            horizontalAlignment: Text.AlignRight
            text: Math.round(row.value * 100) + "%"
            color: row.muted ? Qt.alpha(row.textColor, 0.55) : row.textColor
            font.pixelSize: 11
            font.bold: true
            font.family: row.fontFamily
        }
    }
}
