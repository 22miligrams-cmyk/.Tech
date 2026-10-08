import QtQuick
import Quickshell
import Quickshell.Wayland
import "../bar"
import "../notifications"
import "../settings"
import "../common"
import "../lang"
import "../icons"

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

    property var lyr: null
    property string side: "bottom"
    property var anchorRect: ({ x: 0, y: 0, w: 0, h: 0, lo: 0, hi: 0 })

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"
    readonly property string status: lyr ? lyr.status : "idle"
    readonly property bool canHide: status === "found" || status === "notfound" || status === "confirm"
        || status === "searching" || status === "recognizing"
    property bool manual: false
    property bool showTimes: true
    readonly property bool timesVisible: showTimes
    readonly property real timeW: timesVisible ? 40 : 0

    property real textShift: 7
    property real timeMargin: 18
    property real textShiftX: 6

    function fmtTime(sec) {
        const s = Math.max(0, Math.floor(sec))
        const m = Math.floor(s / 60), r = s % 60
        return (m < 10 ? "0" : "") + m + ":" + (r < 10 ? "0" : "") + r
    }

    readonly property bool horiz: side === "top" || side === "bottom"
    readonly property real pad: 14
    readonly property real cr: 6
    readonly property real pw: horiz ? Math.max(380, anchorRect.w) : 360
    readonly property real ph: 430

    function clamp(v, lo, hi) { return Math.max(lo, Math.min(v, hi)) }
    // караоке (полный экран)
    // настройки лежат тут, поэтому запоминаются между открытиями (пока шелл жив)
    QtObject {
        id: kcfg
        property int fontIdx: 1        // S / M / L / XL
        property int dim: 1            // затемнение фона
        property bool cover: true
        property bool viz: true
        property bool wordHL: true
        property bool sideOpen: true
    }

    LazyLoader {
        id: karaokeLoader
        active: false

        KaraokePanel {
            screen: vp.screen
            lyr: vp.lyr
            cfg: kcfg
            colBg: vp.colBg
            colAccent: vp.colAccent
            colText: vp.colText
            colSecondary: vp.colSecondary
            colGlass: vp.colGlass
            onClosed: karaokeLoader.active = false
        }
    }
    function openKaraoke() {
        if (status !== "found" || karaokeLoader.active) return
        // lyrics-панель закрываем сразу, без анимации, чтобы не делили фокус клавиатуры
        openAnim.stop()
        closeAnim.stop()
        isClosing = false
        visible = false
        p = 0
        karaokeLoader.active = true
    }

    // как в MprisPanel: панель прирастает к бару только если плашка-якорь не уже самой панели,
    // а если это одиночный блок — отдельная панель с отступом и скруглёнными углами
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
        if (!fused) return false
        const sp = anchorRect.spans
        if (sp) {
            for (let i = 0; i < sp.length; i++)
                if (v >= sp[i][0] - 0.5 && v <= sp[i][1] + 0.5) return true
            return false
        }
        return v >= anchorRect.lo - 0.5 && v <= anchorRect.hi + 0.5
    }


    readonly property bool covers: fused && (horiz
        ? (px <= anchorRect.x + 0.5 && px + pw >= anchorRect.x + anchorRect.w - 0.5)
        : (py <= anchorRect.y + 0.5 && py + ph >= anchorRect.y + anchorRect.h - 0.5))

    property bool isClosing: false
    property real p: 0

    function toggleMenu() {
        if (isClosing) return

        if (visible) {
            isClosing = true
            openAnim.stop()
            closeAnim.start()
        } else {
            p = 0
            manual = false
            visible = true
            openAnim.restart()
            keys.forceActiveFocus()
            list.userHold = false
            followT.restart()
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
    WlrLayershell.namespace: "lyrics-panel"
    visible: false

    function seekTo(sec) {
        const pl = lyr ? lyr.player : null
        if (!pl || !pl.canSeek || !pl.positionSupported) return
        pl.position = Math.max(0, sec - lyr.offset)
        lyr.pos = pl.position
    }

    function fmt(sec) {
        const s = Math.round(sec || 0)
        return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0")
    }

    function openManual() {
        manual = true
        if (lyr) {
            searchInput.text = lyr.manualPrefill()
            lyr.searchManual(searchInput.text)
        }
        searchInput.forceActiveFocus()
        searchInput.selectAll()
    }

    function closeManual() {
        manual = false
        keys.forceActiveFocus()
    }

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

        Keys.onEscapePressed: vp.manual ? vp.closeManual() : vp.toggleMenu()

        MouseArea {
            anchors.fill: parent
            onClicked: if (!vp.manual) vp.toggleMenu()
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
                Item {
                    id: content
                    anchors.fill: parent
                    anchors.margins: vp.pad

                    Item {
                        id: head
                        width: parent.width
                        height: 28

                        Rectangle {
                            id: badge
                            width: 28
                            height: 28
                            radius: vp.cr
                            color: vp.colSecondary

                            Icon {
                                anchors.centerIn: parent
                                name: "lyrics"
                                size: 15
                                color: vp.colAccent
                                dim: 1.3
                            }
                        }

                        Column {
                            anchors.left: badge.right
                            anchors.leftMargin: 10
                            anchors.right: karaBtn.left
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1

                            Text {
                                width: parent.width
                                text: vp.t("lyrics.title", "Текст песни")
                                color: vp.colText
                                font.pixelSize: 13
                                font.bold: true
                                font.family: vp.fontFamily
                                elide: Text.ElideRight
                            }

                            Text {
                                width: parent.width
                                text: vp.lyr ? (vp.lyr.rawArtist !== "" ? vp.lyr.rawArtist + " — " + vp.lyr.rawTitle : vp.lyr.rawTitle) : ""
                                color: Qt.alpha(vp.colText, 0.55)
                                font.pixelSize: 10
                                font.family: vp.fontFamily
                                elide: Text.ElideRight
                            }
                        }

                        Rectangle {
                            id: karaBtn
                            anchors.right: searchBtn.left
                            anchors.rightMargin: 6
                            width: 28
                            height: 28
                            radius: vp.cr
                            opacity: vp.status === "found" ? 1.0 : 0.35
                            color: Qt.alpha(vp.colText, karaMa.containsMouse && vp.status === "found" ? 0.12 : 0.06)

                            Behavior on color { ColorAnimation { duration: 150 } }
                            Behavior on opacity { NumberAnimation { duration: 150 } }
                            // глиф микрофона из Nerd Font; если добавишь иконку "karaoke" в ../icons — можно заменить на Icon { name: "karaoke" }
                            Text {
                                anchors.centerIn: parent
                                text: "\uf130"
                                color: vp.colAccent
                                font.pixelSize: 14
                                font.family: vp.fontFamily
                            }

                            MouseArea {
                                id: karaMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: vp.status === "found" ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: vp.openKaraoke()
                            }
                        }

                        Rectangle {
                            id: searchBtn
                            anchors.right: parent.right
                            width: 28
                            height: 28
                            radius: vp.cr
                            color: vp.manual ? vp.colAccent
                                 : Qt.alpha(vp.colText, searchMa.containsMouse ? 0.12 : 0.06)

                            Behavior on color { ColorAnimation { duration: 150 } }

                            Icon {
                                anchors.centerIn: parent
                                name: "search"
                                size: 14
                                color: vp.manual ? vp.colBg : vp.colAccent
                                dim: vp.manual ? 1.0 : 1.3
                            }

                            MouseArea {
                                id: searchMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: vp.manual ? vp.closeManual() : vp.openManual()
                            }
                        }
                    }


                    Item {
                        id: footer
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        visible: !vp.manual
                        height: !vp.manual && (vp.canHide || vp.status === "hidden") ? 34 : 0

                        Row {
                            id: footerRow
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            spacing: 8

                            Repeater {
                                model: [
                                    { act: "wrong", show: vp.status === "found",    label: vp.t("lyrics.wrong", "Не та песня?") },
                                    { act: "hide",  show: vp.canHide,               label: vp.t("lyrics.hide", "Закрыть для этой песни") },
                                    { act: "show",  show: vp.status === "hidden",   label: vp.t("lyrics.unhide", "Показать текст") }
                                ]

                                Rectangle {
                                    id: fBtn
                                    required property var modelData
                                    visible: modelData.show
                                    width: fText.implicitWidth + 24
                                    height: 26
                                    radius: vp.cr
                                    color: fMa.containsMouse ? vp.colAccent : Qt.alpha(vp.colText, 0.07)

                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    Text {
                                        id: fText
                                        anchors.centerIn: parent
                                        text: fBtn.modelData.label
                                        color: fMa.containsMouse ? vp.colBg : Qt.alpha(vp.colText, 0.75)
                                        font.pixelSize: 10
                                        font.bold: true
                                        font.family: vp.fontFamily
                                    }

                                    MouseArea {
                                        id: fMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (!vp.lyr) return
                                            if (fBtn.modelData.act === "wrong") { vp.lyr.wrongSong(); vp.openManual() }
                                            else if (fBtn.modelData.act === "hide") { vp.lyr.hideForTrack(); if (!vp.isClosing) vp.toggleMenu() }
                                            else vp.lyr.unhide()
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Item {
                        id: stage
                        anchors.top: head.bottom
                        anchors.topMargin: 12
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: footer.top

                        ListView {
                            id: list
                            anchors.fill: parent
                            visible: !vp.manual && vp.status === "found"
                            clip: true
                            spacing: 0
                            model: vp.lyr ? vp.lyr.lines : []
                            boundsBehavior: Flickable.StopAtBounds
                            topMargin: height / 2 - 14
                            bottomMargin: height / 2 - 14

                            property bool userHold: false
                            property bool programmatic: false

                            Timer { id: holdTimer; interval: 4000; onTriggered: list.userHold = false }

                            onContentYChanged: {
                                if (!programmatic && !scrollAnim.running && visible) {
                                    userHold = true
                                    holdTimer.restart()
                                }
                            }

                            NumberAnimation {
                                id: scrollAnim
                                target: list
                                property: "contentY"
                                duration: 380
                                easing.type: Easing.OutCubic
                            }

                            // list прыгнул на delta пикселей -> строки стартуют со старого места и едут волной
                            signal shifted(real delta, int cur)

                            property real wheelTo: 0
                            readonly property real minY: originY - topMargin
                            readonly property real maxY: Math.max(minY, originY + contentHeight + bottomMargin - height)

                            NumberAnimation {
                                id: wheelAnim
                                target: list
                                property: "contentY"
                                duration: 260
                                easing.type: Easing.OutCubic
                            }

                            WheelHandler {
                                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                                onWheel: (event) => {
                                    const d = event.pixelDelta.y !== 0 ? event.pixelDelta.y * 1.2 : event.angleDelta.y * 0.7
                                    const base = wheelAnim.running ? list.wheelTo : list.contentY
                                    list.wheelTo = Math.max(list.minY, Math.min(base - d, list.maxY))
                                    list.userHold = true
                                    holdTimer.restart()
                                    scrollAnim.stop()
                                    wheelAnim.stop()
                                    wheelAnim.from = list.contentY
                                    wheelAnim.to = list.wheelTo
                                    wheelAnim.start()
                                }
                            }


                            function follow(animated) {
                                const idx = vp.lyr ? vp.lyr.currentIndex : -1
                                if (idx < 0 || userHold || !visible) return
                                programmatic = true
                                const from = contentY
                                positionViewAtIndex(idx, ListView.Center)
                                const to = contentY
                                contentY = from
                                programmatic = false
                                scrollAnim.stop()
                                wheelAnim.stop()
                                programmatic = true
                                contentY = to
                                programmatic = false
                                if (animated && Math.abs(to - from) > 0.5) shifted(to - from, idx)
                            }


                            Timer { id: followT; interval: 0; onTriggered: list.follow(false) }

                            Connections {
                                target: vp.lyr
                                function onCurrentIndexChanged() { list.follow(true) }
                                function onLinesChanged() { list.userHold = false; followT.restart() }
                            }

                            delegate: Item {
                                id: row
                                required property int index
                                required property var modelData

                                readonly property int cur: vp.lyr ? vp.lyr.currentIndex : -1
                                readonly property bool active: index === cur
                                readonly property int dist: Math.abs(index - cur)

                                width: list.width
                                height: lineText.implicitHeight + 16

                                // --- волна: строка стартует со старого места (shiftD) и едет на своё, чем дальше от текущей — тем позже ---
                                property real shiftD: 0
                                property int shiftDelay: 0
                                transform: Translate { id: tr }

                                SequentialAnimation {
                                    id: waveAnim
                                    PropertyAction { target: tr; property: "y"; value: row.shiftD }
                                    PauseAnimation { duration: row.shiftDelay }
                                    NumberAnimation {
                                        target: tr
                                        property: "y"
                                        to: 0
                                        duration: 620
                                        easing.type: Easing.OutBack
                                        easing.overshoot: 0.7
                                    }
                                }


                                Connections {
                                    target: list
                                    function onShifted(delta, cur) {
                                        // за экраном строку не анимируем
                                        if (row.y + row.height - list.contentY < -200 || row.y - list.contentY > list.height + 200) { waveAnim.stop(); tr.y = 0; return }
                                        const carry = waveAnim.running ? tr.y : 0     // новая строка пришла, пока старая волна не доехала
                                        waveAnim.stop()
                                        row.shiftD = carry + delta
                                        const lag = delta > 0 ? row.index - cur : cur - row.index    // читаем вниз — отстают нижние, назад — верхние
                                        row.shiftDelay = Math.max(0, Math.min(lag, 6)) * 55
                                        waveAnim.start()
                                    }
                                }

                                readonly property real edge: {
                                    const c = row.y + tr.y + row.height / 2 - list.contentY
                                    return Math.max(0, Math.min(1, Math.min(c, list.height - c) / 56))
                                }
                                opacity: 0.15 + 0.85 * edge

                                Rectangle {
                                    anchors.fill: parent
                                    anchors.leftMargin: 4
                                    anchors.rightMargin: 4
                                    anchors.topMargin: 1
                                    anchors.bottomMargin: 1
                                    radius: vp.cr + 2
                                    color: Qt.alpha(vp.colAccent, 0.10)
                                    opacity: row.active ? 1.0 : 0.0

                                    Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

                                    Rectangle {
                                        width: 3
                                        height: parent.height - 14
                                        radius: 1.5
                                        anchors.left: parent.left
                                        anchors.leftMargin: 3
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: vp.colAccent
                                    }
                                }

                                KaraokeLine {
                                    id: lineText
                                    anchors.centerIn: parent
                                    anchors.horizontalCenterOffset: vp.textShiftX
                                    anchors.verticalCenterOffset: -vp.textShift
                                    width: parent.width - 28 - 2 * vp.timeW
                                    text: row.modelData.text !== "" ? row.modelData.text : "\u00a0"
                                    words: row.active && vp.lyr ? vp.lyr.curWords : []
                                    wordIndex: row.active && vp.lyr ? vp.lyr.wordIndex : -1
                                    wrap: true
                                    jumpEnabled: vp.lyr ? vp.lyr.wordJump : true
                                    color: row.active ? vp.colAccent : vp.colText
                                    dotColor: vp.lyr && !vp.lyr.wordHighlight ? "transparent" : vp.colAccent
                                    pixelSize: 14
                                    bold: row.active
                                    family: vp.fontFamily
                                    opacity: row.active ? 1.0 : Math.max(0.16, 0.62 - row.dist * 0.12)
                                    scale: row.active ? 1.12 : 0.97

                                    Behavior on opacity { NumberAnimation { duration: 250 } }
                                    Behavior on scale { NumberAnimation { duration: 420; easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
                                }

                                Icon {
                                    visible: row.modelData.text === ""
                                    name: "player"
                                    size: 16
                                    color: "white"
                                    anchors.centerIn: parent
                                    opacity: row.active ? 1.0 : Math.max(0.16, 0.62 - row.dist * 0.12)
                                }

                                Text {
                                    visible: vp.timesVisible
                                    anchors.left: parent.left
                                    anchors.leftMargin: vp.timeMargin
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: vp.fmtTime(row.modelData.t)
                                    color: row.active ? vp.colAccent : vp.colText
                                    font.pixelSize: 10
                                    font.bold: row.active
                                    font.letterSpacing: 0.6
                                    font.family: vp.fontFamily
                                    opacity: row.active ? 0.95 : 0.32

                                    Behavior on opacity { NumberAnimation { duration: 250 } }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: vp.seekTo(row.modelData.t)
                                }
                            }
                        }

                        Column {
                            anchors.centerIn: parent
                            spacing: 12
                            visible: !vp.manual && vp.status !== "found"

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: vp.status === "searching" ? vp.t("lyrics.searching", "Ищу текст…")
                                    : vp.status === "recognizing" ? vp.t("lyrics.listening", "Слушаю трек…")
                                    : vp.status === "ad" ? vp.t("lyrics.ad", "Реклама")
                                    : vp.status === "video" ? vp.t("lyrics.video", "Похоже, это не музыка")
                                    : vp.status === "confirm" ? vp.t("lyrics.confirm", "Это") + " «" + (vp.lyr && vp.lyr.suggestion ? vp.lyr.suggestion.title : "") + "»?"
                                    : vp.status === "notfound" ? vp.t("lyrics.notfound", "Текст не найден")
                                    : vp.status === "hidden" ? vp.t("lyrics.hidden", "Текст скрыт для этой песни")
                                    : vp.t("lyrics.idle", "Ничего не играет")
                                color: vp.colText
                                font.pixelSize: 13
                                font.bold: true
                                font.family: vp.fontFamily
                            }
                            Rectangle {
                                anchors.horizontalCenter: parent.horizontalCenter
                                visible: vp.status === "video"
                                width: musicText.implicitWidth + 24
                                height: 28
                                radius: vp.cr
                                color: musicMa.containsMouse ? vp.colAccent : vp.colSecondary

                                Behavior on color { ColorAnimation { duration: 150 } }

                                Text {
                                    id: musicText
                                    anchors.centerIn: parent
                                    text: vp.t("lyrics.markmusic", "Это музыка")
                                    color: musicMa.containsMouse ? vp.colBg : vp.colText
                                    font.pixelSize: 11
                                    font.bold: true
                                    font.family: vp.fontFamily
                                }

                                MouseArea {
                                    id: musicMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: if (vp.lyr) vp.lyr.markMusic()
                                }
                            }

                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                visible: vp.status === "confirm"
                                spacing: 10

                                Repeater {
                                    model: [
                                        { yes: true,  label: vp.t("lyrics.yes", "Да") },
                                        { yes: false, label: vp.t("lyrics.no", "Нет") }
                                    ]

                                    Rectangle {
                                        id: ynBtn
                                        required property var modelData
                                        width: 72
                                        height: 28
                                        radius: vp.cr
                                        color: ynMa.containsMouse ? vp.colAccent : vp.colSecondary

                                        Behavior on color { ColorAnimation { duration: 150 } }

                                        Text {
                                            anchors.centerIn: parent
                                            text: ynBtn.modelData.label
                                            color: ynMa.containsMouse ? vp.colBg : vp.colText
                                            font.pixelSize: 11
                                            font.bold: true
                                            font.family: vp.fontFamily
                                        }

                                        MouseArea {
                                            id: ynMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: if (vp.lyr) { ynBtn.modelData.yes ? vp.lyr.confirmYes() : vp.lyr.confirmNo() }
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                anchors.horizontalCenter: parent.horizontalCenter
                                visible: vp.status === "notfound"
                                width: findText.implicitWidth + 24
                                height: 28
                                radius: vp.cr
                                color: findMa.containsMouse ? vp.colAccent : vp.colSecondary

                                Behavior on color { ColorAnimation { duration: 150 } }

                                Text {
                                    id: findText
                                    anchors.centerIn: parent
                                    text: vp.t("lyrics.find", "Найти вручную")
                                    color: findMa.containsMouse ? vp.colBg : vp.colText
                                    font.pixelSize: 11
                                    font.bold: true
                                    font.family: vp.fontFamily
                                }

                                MouseArea {
                                    id: findMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: vp.openManual()
                                }
                            }
                        }

                        Item {
                            anchors.fill: parent
                            visible: vp.manual

                            Rectangle {
                                id: searchBox
                                width: parent.width
                                height: 32
                                radius: vp.cr
                                color: Qt.alpha(vp.colText, 0.06)
                                border.width: 1
                                border.color: searchInput.activeFocus ? Qt.alpha(vp.colAccent, 0.6) : "transparent"

                                Text {
                                    id: clearBtn
                                    visible: searchInput.text !== ""
                                    anchors.right: parent.right
                                    anchors.rightMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "✕"
                                    color: Qt.alpha(vp.colText, clearMa.containsMouse ? 0.9 : 0.45)
                                    font.pixelSize: 12
                                    font.family: vp.fontFamily

                                    MouseArea {
                                        id: clearMa
                                        anchors.fill: parent
                                        anchors.margins: -6
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            searchInput.text = ""
                                            if (vp.lyr) vp.lyr.searchManual("")
                                            searchInput.forceActiveFocus()
                                        }
                                    }
                                }

                                TextInput {
                                    id: searchInput
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 30
                                    verticalAlignment: TextInput.AlignVCenter
                                    color: vp.colText
                                    selectionColor: vp.colAccent
                                    selectedTextColor: vp.colBg
                                    font.pixelSize: 12
                                    font.family: vp.fontFamily
                                    clip: true

                                    // ищем по мере набора (пауза 350 мс), Enter — сразу
                                    onTextEdited: searchDebounce.restart()
                                    onAccepted: { searchDebounce.stop(); if (vp.lyr) vp.lyr.searchManual(text) }
                                    Keys.onEscapePressed: vp.closeManual()

                                    Timer {
                                        id: searchDebounce
                                        interval: 350
                                        onTriggered: if (vp.lyr) vp.lyr.searchManual(searchInput.text)
                                    }

                                    Text {
                                        visible: searchInput.text === ""
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: vp.t("lyrics.search.hint", "Артист и название, Enter — найти")
                                        color: Qt.alpha(vp.colText, 0.4)
                                        font.pixelSize: 12
                                        font.family: vp.fontFamily
                                    }
                                }
                            }

                            Text {
                                anchors.top: searchBox.bottom
                                anchors.topMargin: 24
                                anchors.horizontalCenter: parent.horizontalCenter
                                visible: !!vp.lyr && vp.lyr.candidates.length === 0 && vp.lyr.manualState !== "idle"
                                text: !vp.lyr ? "" : vp.lyr.manualState === "busy" ? vp.t("lyrics.search.busy", "Ищу…")
                                    : vp.lyr.manualState === "error" ? vp.t("lyrics.search.error", "Нет связи с LRCLIB, попробуйте ещё раз")
                                    : vp.lyr.manualState === "empty" ? vp.t("lyrics.search.empty", "Ничего не найдено") : ""
                                color: Qt.alpha(vp.colText, 0.55)
                                font.pixelSize: 12
                                font.family: vp.fontFamily
                            }

                            ListView {
                                anchors.top: searchBox.bottom
                                anchors.topMargin: 8
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                clip: true
                                spacing: 4
                                model: vp.lyr ? vp.lyr.candidates : []
                                boundsBehavior: Flickable.StopAtBounds

                                delegate: Rectangle {
                                    id: cand
                                    required property var modelData

                                    width: ListView.view.width
                                    height: 40
                                    radius: vp.cr
                                    color: candMa.containsMouse ? Qt.alpha(vp.colAccent, 0.18) : Qt.alpha(vp.colText, 0.05)

                                    Behavior on color { ColorAnimation { duration: 120 } }

                                    Column {
                                        anchors.left: parent.left
                                        anchors.leftMargin: 10
                                        anchors.right: parent.right
                                        anchors.rightMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 1

                                        Text {
                                            width: parent.width
                                            text: cand.modelData.title
                                            color: vp.colText
                                            font.pixelSize: 12
                                            font.bold: true
                                            font.family: vp.fontFamily
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            width: parent.width
                                            text: cand.modelData.artist + "  ·  " + vp.fmt(cand.modelData.duration)
                                            color: cand.modelData.near ? vp.colAccent : Qt.alpha(vp.colText, 0.55)
                                            font.pixelSize: 10
                                            font.family: vp.fontFamily
                                            elide: Text.ElideRight
                                        }
                                    }

                                    MouseArea {
                                        id: candMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (vp.lyr) vp.lyr.pick(cand.modelData)
                                            vp.closeManual()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
