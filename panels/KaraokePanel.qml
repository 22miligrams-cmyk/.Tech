import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import "../bar"
import "../notifications"
import "../settings"
import "../common"
import "../lang"
import "../icons"

// караоке на весь экран: текст крупно, настройки сбоку.
// открывается иконкой микрофона в LyricsPanel (через LazyLoader), настройки лежат в cfg (QtObject в LyricsPanel).
PanelWindow {
    id: vp

    function t(key, fallback) {
        const v = Tr.tr(key)
        return (!v || v === key) ? fallback : v
    }

    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary
    required property color colGlass
    required property var cfg

    property var lyr: null
    signal closed()

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"
    readonly property real cr: 6

    readonly property var player: lyr ? lyr.player : null
    readonly property string status: lyr ? lyr.status : "idle"
    readonly property bool playing: player !== null && player !== undefined
        && player.playbackState === MprisPlaybackState.Playing
    readonly property real len: player && player.lengthSupported && player.length > 0 ? player.length : 0
    readonly property bool canSeekNow: !!player && player.canSeek && len > 0

    property real pos: 0
    property bool seeking: false
    property real seekFrac: 0
    readonly property real frac: len > 0 ? Math.max(0, Math.min(1, seeking ? seekFrac : pos / len)) : 0

    readonly property var fontSizes: [30, 40, 52, 66]
    readonly property real basePx: fontSizes[cfg ? cfg.fontIdx : 1]

    function fmt(sec) {
        const s = Math.floor(Math.max(0, sec || 0))
        return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0")
    }

    function syncPos() {
        if (!player || seeking) return
        player.positionChanged()
        pos = player.position
    }


    function seekTo(sec) {
        const pl = vp.player
        if (!pl || !pl.canSeek || !pl.positionSupported) return
        pl.position = Math.max(0, sec - (lyr ? lyr.offset : 0))
        if (lyr) lyr.pos = pl.position
        syncPos()
    }

    function seekBy(d) {
        const pl = vp.player
        if (!pl || !pl.canSeek || !pl.positionSupported) return
        pl.position = Math.max(0, pl.position + d)
        syncPos()
    }
    // прячем курсор и интерфейс, если мышь не двигается
    property bool uiShown: true
    function poke() { uiShown = true; idleTimer.restart() }

    Timer {
        id: idleTimer
        interval: 3500
        onTriggered: if (!sideHover.hovered) vp.uiShown = false
    }

    // открытие / закрытие
    property bool isClosing: false
    property bool done: false
    property real p: 0

    function close() {
        if (isClosing) return
        isClosing = true
        openAnim.stop()
        closeAnim.start()
    }

    function finish() {
        if (done) return
        done = true
        vp.closed()
    }

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    visible: false

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "karaoke-panel"

    Component.onCompleted: {
        visible = true
        openAnim.restart()
        keys.forceActiveFocus()
        idleTimer.restart()
        syncPos()
    }
    NumberAnimation { id: openAnim; target: vp; property: "p"; to: 1; duration: 320; easing.type: Easing.OutCubic }
    NumberAnimation {
        id: closeAnim
        target: vp
        property: "p"
        to: 0
        duration: 220
        easing.type: Easing.InCubic
        onFinished: {
            audioProc.running = false
            vp.finish()
        }
    }

    Timer {
        interval: 250
        repeat: true
        running: vp.visible && vp.playing && !vp.seeking
        triggeredOnStart: true
        onTriggered: vp.syncPos()
    }

    // когда панель выгружается — гасим процесс визуализации
    Component.onDestruction: audioProc.running = false

    // уровни звука для фоновой визуализации (audio_levels.py лежит рядом)
    readonly property string audioScript: decodeURIComponent(Qt.resolvedUrl("audio_levels.py").toString().replace(/^file:\/\//, ""))
    property var audioLv: []
    readonly property bool wantAudio: visible && playing && !isClosing && !!cfg && cfg.viz

    onWantAudioChanged: {
        audioProc.running = wantAudio
        if (!wantAudio) audioLv = []
    }

    Process {
        id: audioProc
        command: ["python3", "-u", vp.audioScript]
        stdout: SplitParser {
            onRead: (line) => {
                const q = line.trim().split(" ")
                const a = new Array(q.length)
                for (let i = 0; i < q.length; i++) a[i] = parseFloat(q[i]) || 0
                vp.audioLv = a
            }
        }
        onExited: if (vp.wantAudio) audioRetry.restart()
    }

    Timer { id: audioRetry; interval: 2000; onTriggered: if (vp.wantAudio) audioProc.running = true }

    // мелкие компоненты (inline-компоненты не видят id снаружи, поэтому тема идёт через th)
    component IconBtn: Rectangle {
        id: ib
        property var th: null
        property string glyph: ""
        property bool on: false
        property real size: 36
        property real glyphSize: 15
        signal clicked()

        width: size
        height: size
        radius: th ? th.cr : 6
        color: on ? th.colAccent : Qt.alpha(th.colText, ibMa.containsMouse ? 0.16 : 0.08)

        Behavior on color { ColorAnimation { duration: 150 } }

        Text {
            anchors.centerIn: parent
            text: ib.glyph
            color: ib.on ? ib.th.colBg : ib.th.colText
            font.pixelSize: ib.glyphSize
            font.family: ib.th.fontFamily
        }
        MouseArea {
            id: ibMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: ib.clicked()
        }
    }

    component Seg: Item {
        id: sg
        property var th: null
        property var options: []
        property int current: 0
        signal picked(int i)

        height: 28

        Row {
            spacing: 4

            Repeater {
                model: sg.options

                Rectangle {
                    id: sb
                    required property int index
                    required property var modelData

                    width: (sg.width - (sg.options.length - 1) * 4) / sg.options.length
                    height: sg.height
                    radius: sg.th.cr
                    color: sg.current === index ? sg.th.colAccent : Qt.alpha(sg.th.colText, sMa.containsMouse ? 0.14 : 0.07)

                    Behavior on color { ColorAnimation { duration: 150 } }
                    Text {
                        anchors.centerIn: parent
                        text: sb.modelData
                        color: sg.current === sb.index ? sg.th.colBg : Qt.alpha(sg.th.colText, 0.8)
                        font.pixelSize: 11
                        font.bold: true
                        font.family: sg.th.fontFamily
                    }

                    MouseArea {
                        id: sMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: sg.picked(sb.index)
                    }
                }
            }
        }
    }

    component ToggleRow: Item {
        id: tg
        property var th: null
        property string label: ""
        property bool checked: false
        signal toggled()

        height: 28

        Text {
            anchors.left: parent.left
            anchors.right: sw.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: tg.label
            color: tg.th.colText
            font.pixelSize: 12
            font.family: tg.th.fontFamily
            elide: Text.ElideRight
        }

        Rectangle {
            id: sw
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 36
            height: 20
            radius: 10
            color: tg.checked ? tg.th.colAccent : Qt.alpha(tg.th.colText, 0.16)

            Behavior on color { ColorAnimation { duration: 150 } }

            Rectangle {
                width: 14
                height: 14
                radius: 7
                y: 3
                x: tg.checked ? parent.width - width - 3 : 3
                color: tg.checked ? tg.th.colBg : tg.th.colText

                Behavior on x { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: tg.toggled()
        }
    }

    component Label: Text {
        property var th: null
        color: Qt.alpha(th.colText, 0.5)
        font.pixelSize: 10
        font.bold: true
        font.letterSpacing: 0.8
        font.family: th.fontFamily
    }

    // UI
    Item {
        id: keys
        anchors.fill: parent
        focus: true
        opacity: Math.min(1, vp.p * 1.6)
        scale: 0.985 + 0.015 * vp.p

        HoverHandler {
            cursorShape: vp.uiShown ? Qt.ArrowCursor : Qt.BlankCursor
            onPointChanged: vp.poke()
        }

        Keys.onPressed: (e) => {
            vp.poke()
            if (e.key === Qt.Key_Escape) vp.close()
            else if (e.key === Qt.Key_Space) { if (vp.player && vp.player.canTogglePlaying) vp.player.togglePlaying() }
            else if (e.key === Qt.Key_S) vp.cfg.sideOpen = !vp.cfg.sideOpen
            else if (e.key === Qt.Key_Left) vp.seekBy(-5)
            else if (e.key === Qt.Key_Right) vp.seekBy(5)
            else if (e.key === Qt.Key_Up) vp.cfg.fontIdx = Math.min(3, vp.cfg.fontIdx + 1)
            else if (e.key === Qt.Key_Down) vp.cfg.fontIdx = Math.max(0, vp.cfg.fontIdx - 1)
            else return
            e.accepted = true
        }

        // фон: цвет -> размытая обложка -> затемнение
        Rectangle { anchors.fill: parent; color: vp.colBg }

        Image {
            id: art
            anchors.fill: parent
            source: vp.player && vp.player.trackArtUrl ? vp.player.trackArtUrl : ""
            fillMode: Image.PreserveAspectCrop
            sourceSize: Qt.size(160, 160)
            smooth: true
            opacity: (vp.cfg.cover && status === Image.Ready) ? 1 : 0

            Behavior on opacity { NumberAnimation { duration: 400 } }

            layer.enabled: opacity > 0
            layer.effect: MultiEffect {
                blurEnabled: true
                blur: 0.7
                blurMax: 48
                saturation: 0.2
            }
        }

        Rectangle {
            anchors.fill: parent
            color: Qt.alpha(vp.colBg, [0.45, 0.62, 0.8][vp.cfg.dim])

            Behavior on color { ColorAnimation { duration: 200 } }
        }

        // визуализация внизу, на фоне
        Row {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            height: parent.height * 0.4
            spacing: 6
            visible: vp.cfg.viz

            Repeater {
                model: 20

                Item {
                    id: vb
                    required property int index
                    width: (parent.width - 19 * 6) / 20
                    height: parent.height

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: Math.max(3, (vp.audioLv[vb.index] || 0) * parent.height)
                        radius: 4
                        color: Qt.alpha(vp.colAccent, 0.16)

                        Behavior on height { NumberAnimation { duration: 70 } }
                    }
                }
            }
        }

        // верхняя панель
        Item {
            id: topBar
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 28
            height: 40
            opacity: vp.uiShown ? 1 : 0

            Behavior on opacity { NumberAnimation { duration: 300 } }

            Rectangle {
                id: badge
                width: 40
                height: 40
                radius: vp.cr
                color: vp.colSecondary

                Text {
                    anchors.centerIn: parent
                    text: "\uf130"
                    color: vp.colAccent
                    font.pixelSize: 18
                    font.family: vp.fontFamily
                }
            }

            Column {
                anchors.left: badge.right
                anchors.leftMargin: 12
                anchors.right: topBtns.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                    width: parent.width
                    text: vp.lyr ? vp.lyr.rawTitle : ""
                    color: vp.colText
                    font.pixelSize: 15
                    font.bold: true
                    font.family: vp.fontFamily
                    elide: Text.ElideRight
                }

                Text {
                    width: parent.width
                    text: vp.lyr ? vp.lyr.rawArtist : ""
                    color: Qt.alpha(vp.colText, 0.6)
                    font.pixelSize: 11
                    font.family: vp.fontFamily
                    elide: Text.ElideRight
                }
            }

            Row {
                id: topBtns
                anchors.right: parent.right
                spacing: 8

                IconBtn {
                    th: vp
                    glyph: "\uf013"
                    on: vp.cfg.sideOpen
                    onClicked: vp.cfg.sideOpen = !vp.cfg.sideOpen
                }

                IconBtn {
                    th: vp
                    glyph: "\uf00d"
                    onClicked: vp.close()
                }
            }
        }

        // текст
        Item {
            id: stage
            anchors.top: topBar.bottom
            anchors.topMargin: 12
            anchors.bottom: bottomBar.top
            anchors.bottomMargin: 12
            anchors.horizontalCenter: parent.horizontalCenter
            width: vp.cfg.sideOpen ? Math.max(480, Math.min(parent.width * 0.64, parent.width - 680))
                                   : parent.width * 0.72

            ListView {
                id: list
                anchors.fill: parent
                visible: vp.status === "found"
                clip: true
                interactive: false
                spacing: 0
                model: vp.lyr ? vp.lyr.lines : []

                highlightRangeMode: ListView.StrictlyEnforceRange
                preferredHighlightBegin: height / 2 - (currentItem ? currentItem.height / 2 : 0)
                preferredHighlightEnd: height / 2 + (currentItem ? currentItem.height / 2 : 0)
                highlightMoveDuration: 480
                highlightMoveVelocity: -1

                function sync() {
                    const i = vp.lyr ? vp.lyr.currentIndex : -1
                    if (i >= 0 && i < count) currentIndex = i
                }

                Timer { id: syncT; interval: 0; onTriggered: list.sync() }

                Connections {
                    target: vp.lyr
                    ignoreUnknownSignals: true
                    function onCurrentIndexChanged() { list.sync() }
                    function onLinesChanged() { syncT.restart() }
                }
                Component.onCompleted: syncT.restart()

                delegate: Item {
                    id: row
                    required property int index
                    required property var modelData

                    readonly property int cur: vp.lyr ? vp.lyr.currentIndex : -1
                    readonly property bool active: index === cur
                    readonly property int dist: Math.abs(index - cur)

                    width: list.width
                    height: lineText.implicitHeight + 28

                    KaraokeLine {
                        id: lineText
                        anchors.centerIn: parent
                        width: parent.width - 40
                        text: row.modelData.text !== "" ? row.modelData.text : "\u00a0"
                        words: row.active && vp.lyr ? vp.lyr.curWords : []
                        wordIndex: row.active && vp.lyr ? vp.lyr.wordIndex : -1
                        wrap: true
                        jumpEnabled: vp.lyr ? vp.lyr.wordJump : true
                        color: row.active ? vp.colAccent : vp.colText
                        dotColor: (vp.lyr && !vp.lyr.wordHighlight) || !vp.cfg.wordHL ? "transparent" : vp.colAccent
                        pixelSize: vp.basePx
                        bold: row.active
                        family: vp.fontFamily
                        opacity: row.active ? 1.0 : Math.max(0.14, 0.55 - row.dist * 0.12)
                        scale: row.active ? 1.0 : 0.7

                        Behavior on opacity { NumberAnimation { duration: 280 } }
                        Behavior on scale { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
                    }

                    Text {
                        visible: row.modelData.text === ""
                        anchors.centerIn: parent
                        text: "\u266a"
                        color: vp.colAccent
                        font.pixelSize: vp.basePx
                        font.family: vp.fontFamily
                        opacity: row.active ? 1.0 : 0.2
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: vp.seekTo(row.modelData.t)
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: vp.status !== "found"
                horizontalAlignment: Text.AlignHCenter
                text: vp.status === "searching" ? vp.t("lyrics.searching", "Searching for lyrics…")
                    : vp.status === "recognizing" ? vp.t("lyrics.listening", "Listening to the track…")
                    : vp.status === "ad" ? vp.t("lyrics.ad", "Advertisement")
                    : vp.status === "notfound" ? vp.t("lyrics.notfound", "Lyrics not found")
                    : vp.status === "hidden" ? vp.t("lyrics.hidden", "Lyrics hidden for this song")
                    : vp.t("lyrics.idle", "Nothing is playing")
                color: Qt.alpha(vp.colText, 0.6)
                font.pixelSize: 22
                font.bold: true
                font.family: vp.fontFamily
            }
        }

        // нижняя панель: управление + прогресс
        Item {
            id: bottomBar
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 28
            height: 76
            opacity: vp.uiShown ? 1 : 0

            Behavior on opacity { NumberAnimation { duration: 300 } }


            Row {
                id: ctl
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                spacing: 12

                IconBtn {
                    th: vp
                    size: 38
                    glyph: "\uf048"
                    enabled: !!vp.player && vp.player.canGoPrevious
                    opacity: enabled ? 1 : 0.4
                    onClicked: vp.player.previous()
                }

                IconBtn {
                    th: vp
                    size: 38
                    glyphSize: 16
                    glyph: vp.playing ? "\uf04c" : "\uf04b"
                    on: true
                    enabled: !!vp.player && vp.player.canTogglePlaying
                    onClicked: vp.player.togglePlaying()
                }

                IconBtn {
                    th: vp
                    size: 38
                    glyph: "\uf051"
                    enabled: !!vp.player && vp.player.canGoNext
                    opacity: enabled ? 1 : 0.4
                    onClicked: vp.player.next()
                }
            }

            Item {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 20

                Text {
                    id: tCur
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: vp.fmt(vp.seeking ? vp.seekFrac * vp.len : vp.pos)
                    color: Qt.alpha(vp.colText, 0.7)
                    font.pixelSize: 11
                    font.family: vp.fontFamily
                }

                Text {
                    id: tLen
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: vp.fmt(vp.len)
                    color: Qt.alpha(vp.colText, 0.7)
                    font.pixelSize: 11
                    font.family: vp.fontFamily
                }

                Rectangle {
                    id: track
                    anchors.left: tCur.right
                    anchors.leftMargin: 12
                    anchors.right: tLen.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    height: seekMa.containsMouse || vp.seeking ? 6 : 4
                    radius: height / 2
                    color: Qt.alpha(vp.colText, 0.16)

                    Behavior on height { NumberAnimation { duration: 120 } }

                    Rectangle {
                        width: parent.width * vp.frac
                        height: parent.height
                        radius: parent.radius
                        color: vp.colAccent
                    }

                    MouseArea {
                        id: seekMa
                        anchors.fill: parent
                        anchors.topMargin: -8
                        anchors.bottomMargin: -8
                        hoverEnabled: true
                        enabled: vp.canSeekNow
                        cursorShape: Qt.PointingHandCursor

                        function upd(x) { vp.seekFrac = Math.max(0, Math.min(1, x / width)) }


                        onPressed: (m) => { vp.seeking = true; upd(m.x) }
                        onPositionChanged: (m) => { if (pressed) upd(m.x) }
                        onReleased: {
                            vp.seeking = false
                            if (vp.player) { vp.player.position = vp.seekFrac * vp.len; vp.syncPos() }
                        }
                    }
                }
            }
        }

        // настройки сбоку
        Rectangle {
            id: side
            width: 292
            height: sideCol.implicitHeight + 32
            anchors.verticalCenter: parent.verticalCenter
            x: parent.width - width - 24 + (vp.cfg.sideOpen ? 0 : width + 40)
            visible: x < parent.width
            radius: vp.cr + 4
            color: Qt.alpha(vp.colBg, 0.78)
            border.width: 1
            border.color: Qt.alpha(vp.colText, 0.08)
            opacity: vp.uiShown || sideHover.hovered ? 1 : 0

            Behavior on x { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 300 } }
            HoverHandler {
                id: sideHover
                onHoveredChanged: if (!hovered) idleTimer.restart()
            }

            MouseArea {
                anchors.fill: parent
                onClicked: (m) => m.accepted = true
            }

            Column {
                id: sideCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 16
                spacing: 8

                Label { th: vp; text: vp.t("karaoke.size", "TEXT SIZE").toUpperCase() }

                Seg {
                    th: vp
                    width: parent.width
                    options: ["S", "M", "L", "XL"]
                    current: vp.cfg.fontIdx
                    onPicked: (i) => vp.cfg.fontIdx = i
                }

                Item { width: 1; height: 6 }

                Label { th: vp; text: vp.t("karaoke.bg", "BACKGROUND").toUpperCase() }

                Seg {
                    th: vp
                    width: parent.width
                    options: [vp.t("karaoke.dim.1", "Lighter"), vp.t("karaoke.dim.2", "Normal"), vp.t("karaoke.dim.3", "Darker")]
                    current: vp.cfg.dim
                    onPicked: (i) => vp.cfg.dim = i
                }

                ToggleRow {
                    th: vp
                    width: parent.width
                    label: vp.t("karaoke.cover", "Cover as background")
                    checked: vp.cfg.cover
                    onToggled: vp.cfg.cover = !vp.cfg.cover
                }

                ToggleRow {
                    th: vp
                    width: parent.width
                    label: vp.t("karaoke.viz", "Visualizer")
                    checked: vp.cfg.viz
                    onToggled: vp.cfg.viz = !vp.cfg.viz
                }

                ToggleRow {
                    th: vp
                    width: parent.width
                    label: vp.t("karaoke.words", "Word highlight")
                    checked: vp.cfg.wordHL
                    onToggled: vp.cfg.wordHL = !vp.cfg.wordHL
                }

                Item { width: 1; height: 6 }

                Label { th: vp; text: vp.t("karaoke.sync", "LYRICS OFFSET").toUpperCase() }

                Item {
                    width: parent.width
                    height: 30

                    IconBtn {
                        id: offMinus
                        th: vp
                        size: 30
                        glyph: "\u2212"
                        anchors.left: parent.left
                        onClicked: if (vp.lyr) vp.lyr.offset = Math.round((vp.lyr.offset - 0.25) * 100) / 100
                    }
                    Text {
                        anchors.left: offMinus.right
                        anchors.right: offPlus.left
                        anchors.verticalCenter: parent.verticalCenter
                        horizontalAlignment: Text.AlignHCenter
                        text: (vp.lyr && vp.lyr.offset > 0 ? "+" : "") + (vp.lyr ? vp.lyr.offset : 0).toFixed(2) + " " + vp.t("ui.sec", "s")
                        color: vp.colText
                        font.pixelSize: 12
                        font.family: vp.fontFamily

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onDoubleClicked: if (vp.lyr) vp.lyr.offset = 0
                        }
                    }

                    IconBtn {
                        id: offPlus
                        th: vp
                        size: 30
                        glyph: "+"
                        anchors.right: parent.right
                        onClicked: if (vp.lyr) vp.lyr.offset = Math.round((vp.lyr.offset + 0.25) * 100) / 100
                    }
                }

                Item { width: 1; height: 4 }

                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: vp.t("karaoke.keys", "Space · ← → · ↑ ↓ · S · Esc")
                    color: Qt.alpha(vp.colText, 0.35)
                    font.pixelSize: 10
                    font.family: vp.fontFamily
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }
    }
}
