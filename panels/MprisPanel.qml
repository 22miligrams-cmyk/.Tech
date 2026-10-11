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
import "../icons"
import "../lang"


PanelWindow {
    id: mp

    function tr(key) { return Tr.tr(key) }

    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary
    required property color colGlass

    property string side: "bottom"

    property var anchorRect: ({ x: 0, y: 0, w: 0, h: 0, lo: 0, hi: 0 })

    property var player: null

    required property var eq
    property bool eqOpen: false

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"

    readonly property bool hasPlayer: player !== null && player !== undefined
    readonly property bool playing: hasPlayer && player.playbackState === MprisPlaybackState.Playing

    // Firefox иногда не выставляет lengthSupported/length через обычные свойства Quickshell
    // (сам по себе mpris:length на шине приходит нормально, int64, проверено busctl),
    // поэтому длину читаем напрямую из сырого metadata как основной источник,
    // а на player.length опираемся только как на запасной вариант для остальных плееров.
    readonly property var meta: hasPlayer && player.metadata ? player.metadata : ({})
    readonly property real metaLenRaw: {
        const v = meta && meta["mpris:length"] !== undefined ? Number(meta["mpris:length"]) : 0
        return isFinite(v) && v > 0 ? v : 0
    }
    readonly property real metaLen: metaLenRaw > 0 ? metaLenRaw / 1000000 : 0
    readonly property real fallbackLen: hasPlayer && player.lengthSupported && player.length > 0 ? player.length : 0
    readonly property real rawLen: metaLen > 0 ? metaLen : fallbackLen

    // во время сика (и вообще при сменах позиции) Firefox на миг отдаёт пустой metadata,
    // rawLen на этот момент падает в 0 — не даём len дёргаться на --:--, держим последнее
    // валидное значение, пока трек реально не сменится
    property real stickyLen: 0
    onRawLenChanged: if (rawLen > 0) stickyLen = rawLen

    readonly property real len: stickyLen
    readonly property bool canSeekNow: hasPlayer && player.canSeek && len > 0

    property real pos: 0
    property bool seeking: false
    property real seekFrac: 0
    readonly property real frac: len > 0 ? Math.max(0, Math.min(1, seeking ? seekFrac : pos / len)) : 0

    function fmt(sec) {
        let s = Math.floor(Math.max(0, sec || 0))
        const h = Math.floor(s / 3600)
        const m = Math.floor((s % 3600) / 60)
        s = s % 60
        const ss = (s < 10 ? "0" : "") + s
        if (h > 0) return h + ":" + (m < 10 ? "0" : "") + m + ":" + ss
        return m + ":" + ss
    }

    function syncPos() {
        if (hasPlayer && !seeking) pos = player.position
    }

    function seekTo(fr) {
        if (!canSeekNow) return
        const v = Math.max(0, Math.min(1, fr)) * len
        player.position = v
        pos = v
    }

    function seekBy(delta) {
        if (!canSeekNow) return
        const v = Math.max(0, Math.min(len, pos + delta))
        player.position = v
        pos = v
    }

    function cycleLoop() {
        if (!hasPlayer || !player.loopSupported) return
        const s = player.loopState
        player.loopState = s === MprisLoopState.None ? MprisLoopState.Playlist
                         : (s === MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None)
    }

    // громкость плеера (MPRIS volume 0..1)
    readonly property bool volUsable: hasPlayer && player.volumeSupported
    property real volFrac: 0
    property real volBefore: 0.5
    property bool volDrag: false

    function syncVol() {
        if (volUsable && !volDrag) volFrac = Math.max(0, Math.min(1, player.volume))
    }

    function setVolume(v) {
        if (!volUsable) return
        v = Math.max(0, Math.min(1, v))
        volFrac = v
        player.volume = v
    }

    function volStep(d) {
        setVolume(Math.round((volFrac + d) * 100) / 100)
    }

    function toggleMute() {
        if (!volUsable) return
        if (volFrac > 0.001) { volBefore = volFrac; setVolume(0) }
        else setVolume(volBefore > 0.001 ? volBefore : 0.5)
    }

    function volGlyph() {
        if (volFrac <= 0.001) return "\udb81\udf5f"
        if (volFrac < 0.34) return "\udb81\udd7f"
        if (volFrac < 0.67) return "\udb81\udd80"
        return "\udb81\udd7e"
    }

    function loopIcon() {
        if (!hasPlayer) return "repeatOff"
        const s = player.loopState
        if (s === MprisLoopState.Track) return "repeatOnce"
        if (s === MprisLoopState.Playlist) return "repeat"
        return "repeatOff"
    }

    // прогресс раскрытия эквалайзера: короткий, без волны — сначала растёт панель, потом проявляется содержимое
    property real eqP: eqOpen ? 1 : 0
    Behavior on eqP { NumberAnimation { duration: 190; easing.type: Easing.OutCubic } }

    readonly property var presetKeys: ({
        "Плоский": "mp.pr.flat", "Flat": "mp.pr.flat",
        "Бас": "mp.pr.bass", "Bass": "mp.pr.bass",
        "Высокие": "mp.pr.treble", "Treble": "mp.pr.treble",
        "Голос": "mp.pr.vocal", "Vocal": "mp.pr.vocal", "Voice": "mp.pr.vocal",
        "Рок": "mp.pr.rock", "Rock": "mp.pr.rock",
        "Клуб": "mp.pr.club", "Club": "mp.pr.club"
    })

    function presetName(n) {
        const k = presetKeys[n]
        return k ? Tr.tr(k) : n
    }

    property int eqHover: -1

    // свои моды эквалайзера: до maxCustom штук, лежат в eq_custom.json рядом с этим файлом
    readonly property int maxCustom: 4
    readonly property int maxNameWords: 6
    readonly property int maxNameLen: 20
    property bool naming: false
    property bool presetAnim: false

    readonly property string customPath: Paths.home + "/.cache/quickshell/eq_custom.json"

    ListModel { id: customModel }

    FileView {
        id: customStore
        path: mp.customPath
        printErrors: false
        atomicWrites: true
        onLoaded: mp.loadCustoms(customStore.text())
    }

    Timer {
        id: presetAnimTimer
        interval: 1000
        onTriggered: mp.presetAnim = false
    }

    function trf(key, fb) {
        const v = Tr.tr(key)
        return (v && v !== key) ? v : fb
    }

    function parseGains(s) {
        return String(s).split(",").map(Number)
    }

    function sameGains(a, b) {
        if (!a || !b || a.length !== b.length) return false
        for (let i = 0; i < a.length; i++)
            if (Math.abs(a[i] - b[i]) > 0.01) return false
        return true
    }

    function applyPreset(gains) {
        if (naming) cancelNaming()
        presetAnim = true
        presetAnimTimer.restart()
        eq.setPreset(gains)
    }

    function loadCustoms(txt) {
        try {
            const arr = JSON.parse(txt)
            customModel.clear()
            for (let i = 0; i < arr.length && customModel.count < maxCustom; i++) {
                const c = arr[i]
                if (!c || typeof c.name !== "string" || !Array.isArray(c.gains) || c.gains.length !== 10) continue
                customModel.append({ name: c.name.slice(0, maxNameLen), gs: c.gains.map(Number).join(",") })
            }
        } catch (e) {}
    }

    function saveCustoms() {
        const out = []
        for (let i = 0; i < customModel.count; i++) {
            const c = customModel.get(i)
            out.push({ name: c.name, gains: parseGains(c.gs) })
        }
        customStore.setText(JSON.stringify(out))
    }

    function startNaming() {
        if (customModel.count >= maxCustom) return
        naming = true
        Qt.callLater(() => { nameInput.text = ""; nameInput.okText = ""; nameInput.forceActiveFocus() })
    }

    function cancelNaming() {
        naming = false
        keys.forceActiveFocus()
    }

    function commitName(raw) {
        const n = String(raw).trim().replace(/\s+/g, " ")
        naming = false
        keys.forceActiveFocus()
        if (n === "") return

        const gs = Array.from(eq.eqGains, v => Math.round(v * 100) / 100).join(",")

        // имя то же — просто перезаписываем настройки
        for (let i = 0; i < customModel.count; i++) {
            if (customModel.get(i).name.toLowerCase() === n.toLowerCase()) {
                customModel.setProperty(i, "gs", gs)
                saveCustoms()
                return
            }
        }
        if (customModel.count >= maxCustom) return
        customModel.append({ name: n, gs: gs })
        saveCustoms()
    }

    function hoverText() {
        const i = eqHover
        if (i < 0) return curPresetName()
        const g = eq.eqGains[i]
        const t = (g > 0 ? "+" : "") + (g % 1 === 0 ? g.toFixed(0) : g.toFixed(1))
        return eq.eqFreqs[i] + "  ·  " + t + " dB"
    }

    function curPresetName() {
        const ps = eq.eqPresets, g = eq.eqGains
        if (ps && g) {
            for (let i = 0; i < ps.length; i++)
                if (sameGains(g, ps[i].gains)) return presetName(ps[i].name)
            for (let i = 0; i < customModel.count; i++)
                if (sameGains(g, parseGains(customModel.get(i).gs))) return customModel.get(i).name
        }
        return Tr.tr("mp.eq.custom")
    }

    onPlayerChanged: { stickyLen = 0; syncPos(); syncVol() }
    onVisibleChanged: {
        if (visible) { syncPos(); syncVol() }
        else naming = false
    }

    Connections {
        target: mp.player
        ignoreUnknownSignals: true
        function onPlaybackStateChanged() { mp.syncPos() }
        function onTrackTitleChanged() { mp.stickyLen = 0; mp.syncPos() }
        function onVolumeChanged() { mp.syncVol() }
    }

    Timer {
        interval: 250
        repeat: true
        running: mp.visible && mp.playing
        triggeredOnStart: true
        onTriggered: mp.syncPos()
    }

    // реальный звук: audio_levels.py лежит рядом с MprisPanel.qml
    readonly property string audioScript: decodeURIComponent(Qt.resolvedUrl("audio_levels.py").toString().replace(/^file:\/\//, ""))
    property var audioLv: []
    property double audioStamp: 0
    readonly property bool wantAudio: visible && playing

    onWantAudioChanged: {
        audioProc.running = wantAudio
        if (!wantAudio) audioLv = []
    }

    Process {
        id: audioProc
        command: ["python3", "-u", mp.audioScript]
        stdout: SplitParser {
            onRead: (line) => {
                const p = line.trim().split(" ")
                const a = new Array(p.length)
                for (let i = 0; i < p.length; i++) a[i] = parseFloat(p[i]) || 0
                mp.audioLv = a
                mp.audioStamp = Date.now()
            }
        }
        onExited: if (mp.wantAudio) audioRetry.restart()
    }

    Timer {
        id: audioRetry
        interval: 2000
        onTriggered: if (mp.wantAudio) audioProc.running = true
    }

    readonly property bool horiz: side === "top" || side === "bottom"
    readonly property real pad: 16
    readonly property real cr: 6
    readonly property real edge: 16
    readonly property real pw: Math.min(horiz ? Math.max(340, anchorRect.w) : 340, width - 16)
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

    // ── параллакс / 3D-глубина ──────────────────────────────────────────
    // parallax: false — выключает всё; parallaxAmt — общая сила (1 = по умолчанию)
    property bool parallax: true
    property real parallaxAmt: 1.0
    readonly property real tiltMax: 0.26          // макс. наклон обложки, рад (~15°)
    property bool idleSway: true                  // плавное «дыхание», пока курсор не над панелью
    readonly property real perspective: 420       // «расстояние до камеры», px

    // цель: положение курсора относительно обложки (по всему экрану), диапазон -1..1
    property real idlePhase: 0
    NumberAnimation on idlePhase {
        from: 0; to: Math.PI * 2; duration: 7000; loops: Animation.Infinite
        running: mp.visible && mp.parallax && mp.idleSway && mp.playing && !hov.hovered
    }
    readonly property bool idleOn: parallax && idleSway && playing && !hov.hovered

    // расстояние (px) от центра обложки, на котором наклон достигает максимума
    readonly property real parallaxRange: 450
    readonly property real coverCX: px + pad + 52
    readonly property real coverCY: py + pad + 52

    readonly property real lookTX: parallax && hov.hovered
        ? clamp((hov.point.position.x - coverCX) / parallaxRange, -1, 1) * parallaxAmt
        : (idleOn ? Math.sin(idlePhase) * 0.35 * parallaxAmt : 0)
    readonly property real lookTY: parallax && hov.hovered
        ? clamp((hov.point.position.y - coverCY) / parallaxRange, -1, 1) * parallaxAmt
        : (idleOn ? Math.cos(idlePhase * 0.8) * 0.25 * parallaxAmt : 0)

    // пружинка: лёгкая инерция и мягкий возврат в центр
    property real lookX: lookTX
    property real lookY: lookTY
    Behavior on lookX { SpringAnimation { spring: 2.6; damping: 0.32; epsilon: 0.002 } }
    Behavior on lookY { SpringAnimation { spring: 2.6; damping: 0.32; epsilon: 0.002 } }

    // поворот вокруг X и Y + перспективное деление (w = 1 - z/d)
    function tiltMatrix(ax, ay, d) {
        const ca = Math.cos(ax), sa = Math.sin(ax)
        const cb = Math.cos(ay), sb = Math.sin(ay)
        const r00 = cb,      r01 = 0,  r02 = sb
        const r10 = sa * sb, r11 = ca, r12 = -sa * cb
        const r20 = -ca * sb, r21 = sa, r22 = ca * cb
        // ВАЖНО: z-строка = identity. Если отдать в z настоящий повёрнутый z, часть обложки
        // уходит за near/far-плоскость Qt Quick и «обрезается» (угол как будто под текстуру).
        // Глубина идёт только в w (перспектива), z остаётся плоским.
        return Qt.matrix4x4(r00, r01, r02, 0,
                            r10, r11, r12, 0,
                            0,   0,   1,   0,
                            -r20 / d, -r21 / d, 0, 1)
    }

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
    WlrLayershell.namespace: "mpris-menu"
    visible: false

    property string wallpaper: ""
    property bool blurEnabled: true
    property real blurRadius: 16
    property color blurTint: Qt.rgba(0.05, 0.05, 0.07, 0.25)

    LiveBackdrop {
        id: backdrop
        screenObj: mp.screen
        wallpaper: mp.wallpaper
        autoDetect: false
        active: mp.visible && mp.blurEnabled
        roi: Qt.rect(mp.px, mp.py, mp.pw, mp.ph)
        pollInterval: 700
        texScale: 0.5
        x: -width - 64
        y: -height - 64
    }

    component CtlBtn: Rectangle {
        id: btn
        property string icon: ""
        property real size: 34
        property real iconSize: 16
        property bool active: false
        property bool solid: false
        property bool usable: true
        signal clicked()

        width: size
        height: size
        radius: solid ? size / 2 : mp.cr
        opacity: usable ? 1.0 : 0.35
        color: solid ? Qt.alpha(mp.colAccent, bma.containsMouse && usable ? 1.0 : 0.9)
                     : Qt.alpha(mp.colText, bma.containsMouse && usable ? 0.14 : (active ? 0.08 : 0.0))

        Behavior on color { ColorAnimation { duration: 150 } }


        Icon {
            anchors.centerIn: parent
            name: btn.icon
            size: btn.iconSize + 3
            color: btn.solid ? mp.colBg : (btn.active ? mp.colAccent : mp.colText)
        }
        MouseArea {
            id: bma
            anchors.fill: parent
            hoverEnabled: true
            enabled: btn.usable
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }
    Item {
        id: keys
        anchors.fill: parent
        focus: true

        // курсор для параллакса по всему экрану (пассивный — клики и hover детей не трогает)
        HoverHandler { id: hov }

        Keys.onEscapePressed: mp.toggleMenu()
        Keys.onLeftPressed: if (!mp.naming) mp.seekBy(-5)
        Keys.onRightPressed: if (!mp.naming) mp.seekBy(5)
        Keys.onUpPressed: if (!mp.naming) mp.volStep(0.05)
        Keys.onDownPressed: if (!mp.naming) mp.volStep(-0.05)
        Keys.onPressed: (e) => {
            if (mp.naming) return
            if (e.key === Qt.Key_Space) {
                if (mp.hasPlayer && mp.player.canTogglePlaying) mp.player.togglePlaying()
            } else if (e.key === Qt.Key_N) {
                if (mp.hasPlayer && mp.player.canGoNext) mp.player.next()
            } else if (e.key === Qt.Key_P) {
                if (mp.hasPlayer && mp.player.canGoPrevious) mp.player.previous()
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: mp.toggleMenu()
        }

        NumberAnimation {
            id: openAnim
            target: mp
            property: "p"
            to: 1
            duration: 280
            easing.type: Easing.OutCubic
        }

        NumberAnimation {
            id: closeAnim
            target: mp
            property: "p"
            to: 0
            duration: 200
            easing.type: Easing.InCubic
            onFinished: {
                mp.visible = false
                mp.isClosing = false
            }
        }

        Item {
            id: holder
            x: mp.px
            y: mp.py
            width: mp.pw
            height: mp.ph
            clip: true

            BarBlur {
                source: (mp.blurEnabled && backdrop.width > 0) ? backdrop.texture : null
                srcSize: Qt.size(backdrop.width, backdrop.height)
                originX: holder.x
                originY: holder.y
                rect: ({ x: panel.x, y: panel.y, w: panel.width, h: panel.height })
                corners: Qt.vector4d(panel.topLeftRadius, panel.topRightRadius,
                                     panel.bottomRightRadius, panel.bottomLeftRadius)
                blurRadius: mp.blurRadius
                tint: mp.blurTint
                strength: panel.opacity
            }

            Rectangle {
                id: panel
                width: holder.width
                height: holder.height

                x: mp.side === "left" ? -(1 - mp.p) * width
                 : mp.side === "right" ? (1 - mp.p) * width : 0
                y: mp.side === "bottom" ? (1 - mp.p) * height
                 : mp.side === "top" ? -(1 - mp.p) * height : 0
                opacity: Math.min(1, mp.p * 2.5)

                color: mp.colGlass

                topLeftRadius: ((mp.side === "top" && mp.sq(mp.px)) || (mp.side === "left" && mp.sq(mp.py))) ? 0 : mp.cr
                topRightRadius: ((mp.side === "top" && mp.sq(mp.px + mp.pw)) || (mp.side === "right" && mp.sq(mp.py))) ? 0 : mp.cr
                bottomLeftRadius: ((mp.side === "bottom" && mp.sq(mp.px)) || (mp.side === "left" && mp.sq(mp.py + mp.ph))) ? 0 : mp.cr
                bottomRightRadius: ((mp.side === "bottom" && mp.sq(mp.px + mp.pw)) || (mp.side === "right" && mp.sq(mp.py + mp.ph))) ? 0 : mp.cr

                MouseArea {
                    anchors.fill: parent
                    onClicked: (mouse) => { mouse.accepted = true; if (mp.naming) mp.cancelNaming() }
                }

                // слой 0 (самый дальний): размытая обложка, смещается ПО курсору
                Item {
                    anchors.fill: parent
                    clip: true
                    opacity: coverImg.status === Image.Ready ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity { NumberAnimation { duration: 300 } }

                    Image {
                        width: parent.width + 80
                        height: parent.height + 80
                        x: -40 + mp.lookX * 22
                        y: -40 + mp.lookY * 22
                        scale: 1.0 + Math.hypot(mp.lookX, mp.lookY) * 0.03
                        source: coverBox.artUrl
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize.width: 128
                        sourceSize.height: 128
                        opacity: 0.30
                        layer.enabled: true
                        layer.effect: MultiEffect {
                            blurEnabled: true
                            blur: 1.0
                            blurMax: 48
                            saturation: 0.25
                        }
                    }
                }

                // слой 1: мягкая тень под обложкой, уезжает ПРОТИВ наклона и пульсирует от басов
                Item {
                    id: coverShadow
                    width: 104 + 56
                    height: 104 + 56
                    x: mp.pad - 28 + mp.lookX * 11
                    y: mp.pad - 28 + 9 + mp.lookY * 11
                    scale: 1.0 + Math.hypot(mp.lookX, mp.lookY) * 0.05
                    opacity: (coverImg.status === Image.Ready ? 0.55 : 0.3) * mp.p
                    layer.enabled: true
                    layer.effect: MultiEffect {
                        blurEnabled: true
                        blur: 1.0
                        blurMax: 32
                    }

                    Rectangle {
                        anchors.centerIn: parent
                        width: 100
                        height: 100
                        radius: mp.cr
                        color: Qt.darker(coverBox.ringColor, 3.2)
                    }
                }

                Column {
                    id: body
                    x: mp.pad
                    y: mp.pad
                    width: parent.width - mp.pad * 2
                    spacing: 12

                    Row {
                        width: parent.width
                        spacing: 30     // было 16: палочки кольца-визуализатора выступают за обложку на ~15px и липли к тексту

                        Item {
                            id: coverBox
                            width: 104
                            height: 104

                            // слой 2 (ближний): 3D-наклон к курсору с перспективой
                            transform: [
                                Translate { x: -coverBox.width / 2; y: -coverBox.height / 2 },
                                Matrix4x4 {
                                    matrix: mp.tiltMatrix(-mp.lookY * mp.tiltMax,
                                                          mp.lookX * mp.tiltMax,
                                                          mp.perspective)
                                },
                                Translate { x: coverBox.width / 2; y: coverBox.height / 2 },
                                Translate { x: -mp.lookX * 7; y: -mp.lookY * 6 }
                            ]

                            readonly property string artUrl: mp.hasPlayer && mp.player.trackArtUrl ? mp.player.trackArtUrl : ""

                            // цвет кольца берём из обложки (если нет — общий акцент)
                            property color ringColor: mp.colAccent
                            Behavior on ringColor { ColorAnimation { duration: 450; easing.type: Easing.OutCubic } }

                            // маленький Canvas: при смене обложки один раз сжимает её до 24×24 и считает яркий цвет
                            Canvas {
                                id: colorProbe
                                width: 24
                                height: 24
                                z: -1
                                opacity: 0.01
                                renderTarget: Canvas.Image

                                property string src: coverBox.artUrl

                                onSrcChanged: {
                                    if (src !== "") loadImage(src)
                                    else coverBox.ringColor = mp.colAccent
                                }
                                Component.onCompleted: if (src !== "") loadImage(src)
                                onImageLoaded: requestPaint()

                                onPaint: {
                                    const u = coverBox.artUrl
                                    if (u === "" || !isImageLoaded(u)) return
                                    const ctx = getContext("2d")
                                    ctx.clearRect(0, 0, 24, 24)
                                    ctx.drawImage(u, 0, 0, 24, 24)
                                    const d = ctx.getImageData(0, 0, 24, 24).data

                                    let R = 0, G = 0, B = 0, W = 0
                                    for (let i = 0; i < d.length; i += 4) {
                                        if (d[i + 3] < 128) continue
                                        const mx = Math.max(d[i], d[i + 1], d[i + 2])
                                        const mn = Math.min(d[i], d[i + 1], d[i + 2])
                                        const s = mx > 0 ? (mn === mx ? 0 : (mx - mn) / mx) : 0
                                        // насыщенные и не слишком тёмные пиксели важнее
                                        const w = 0.02 + s * s * (mx / 255)
                                        R += d[i] * w; G += d[i + 1] * w; B += d[i + 2] * w; W += w
                                    }
                                    if (W <= 0) { coverBox.ringColor = mp.colAccent; return }

                                    const c = Qt.rgba(R / W / 255, G / W / 255, B / W / 255, 1)
                                    if (c.hslSaturation < 0.12) {
                                        // почти ч/б обложка — светло-серый
                                        coverBox.ringColor = Qt.hsla(0, 0, 0.82, 1)
                                    } else {
                                        const h = c.hslHue < 0 ? 0 : c.hslHue
                                        const s2 = Math.max(0.5, Math.min(1, c.hslSaturation * 1.15))
                                        const l2 = Math.max(0.55, Math.min(0.72, c.hslLightness + 0.12))
                                        coverBox.ringColor = Qt.hsla(h, s2, l2, 1)
                                    }
                                }
                            }

                            // кольцо волн вокруг обложки (реальный звук, без Canvas)
                            Item {
                                id: ring
                                anchors.fill: parent
                                visible: level > 0.01
                                transform: Translate { x: mp.lookX * 3.5; y: mp.lookY * 3.5 }

                                readonly property int bars: 84
                                readonly property int nBands: 20
                                readonly property real gap: 3
                                readonly property real maxLen: 9
                                readonly property real minLen: 1.5

                                property real level: mp.playing ? 1.0 : 0.0
                                Behavior on level { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }

                                property var vals: new Array(20).fill(0)
                                property var peaks: new Array(20).fill(0)
                                property real bass: 0
                                property double lastT: 0

                                // точки и нормали по контуру скруглённого квадрата (вместе с углами)
                                readonly property var geo: buildGeo(coverBox.width, mp.cr)


                                function buildGeo(S, r) {
                                    const L = S - 2 * r
                                    const A = Math.PI * r / 2
                                    const P = 4 * L + 4 * A
                                    const out = []
                                    for (let i = 0; i < bars; i++) {
                                        let s = (i * P / bars + L / 2) % P
                                        let seg = 0
                                        while (seg < 7 && s >= (seg % 2 === 0 ? L : A)) {
                                            s -= (seg % 2 === 0 ? L : A)
                                            seg++
                                        }
                                        let px = 0, py = 0, nx = 0, ny = 0
                                        if (seg % 2 === 0) {
                                            const f = Math.min(s, L)
                                            if (seg === 0)      { px = r + f;     py = 0;         nx = 0;  ny = -1 }
                                            else if (seg === 2) { px = S;         py = r + f;     nx = 1;  ny = 0 }
                                            else if (seg === 4) { px = S - r - f; py = S;         nx = 0;  ny = 1 }
                                            else                { px = 0;         py = S - r - f; nx = -1; ny = 0 }
                                        } else {
                                            const a0 = (seg - 1) / 2 * Math.PI / 2 - Math.PI / 2
                                            const a = a0 + Math.min(s / A, 1) * Math.PI / 2
                                            const cx = (seg === 1 || seg === 3) ? S - r : r
                                            const cy = (seg === 1 || seg === 7) ? r : S - r
                                            nx = Math.cos(a)
                                            ny = Math.sin(a)
                                            px = cx + r * nx
                                            py = cy + r * ny
                                        }
                                        out.push({
                                            px: px + nx * gap,
                                            py: py + ny * gap,
                                            rot: Math.atan2(nx, -ny) * 180 / Math.PI,
                                            u: i / bars
                                        })
                                    }
                                    return out
                                }

                                // уровень для палочки: зеркально по вертикали, низ = басы, верх = высокие
                                function valAt(u, vs) {
                                    const d = Math.min(u, 1 - u) * 2
                                    const f = (1 - d) * (nBands - 1)
                                    const i0 = Math.floor(f)
                                    const i1 = Math.min(nBands - 1, i0 + 1)
                                    const a = vs[i0] || 0
                                    const b = vs[i1] || 0
                                    const t = f - i0
                                    const s = t * t * (3 - 2 * t)
                                    return a + (b - a) * s
                                }

                                function step() {
                                    const now = Date.now()
                                    let dt = (now - lastT) / 1000
                                    lastT = now
                                    if (!(dt > 0)) dt = 0.016
                                    dt = Math.min(dt, 0.05)

                                    const fresh = (now - mp.audioStamp) < 400
                                    const lv = mp.audioLv
                                    const nv = new Array(nBands)
                                    const np = new Array(nBands)
                                    for (let i = 0; i < nBands; i++) {
                                        const cur = vals[i] || 0
                                        const tg = (fresh && lv && lv.length > i) ? (lv[i] || 0) : 0
                                        // быстрая атака, плавный спад
                                        const k = tg > cur ? 38 : 7
                                        const v = cur + (tg - cur) * Math.min(1, dt * k)
                                        nv[i] = v
                                        // пик: сразу вверх, потом плавно падает
                                        const pk = peaks[i] || 0
                                        np[i] = v >= pk ? v : Math.max(v, pk - dt * 0.55)
                                    }
                                    vals = nv
                                    peaks = np

                                    // уровень басов (первые полосы) — для подсветки обложки
                                    const bt = (nv[0] + nv[1] + nv[2]) / 3
                                    bass = bass + (bt - bass) * Math.min(1, dt * (bt > bass ? 25 : 6))
                                }

                                FrameAnimation {
                                    running: mp.visible && (mp.playing || ring.level > 0.01)
                                    onTriggered: ring.step()
                                }

                                // подсветка контура обложки пульсирует от басов
                                Rectangle {
                                    anchors.fill: parent
                                    anchors.margins: -1
                                    radius: mp.cr + 1
                                    color: "transparent"
                                    border.width: 1.5
                                    border.color: coverBox.ringColor
                                    opacity: ring.bass * 0.7 * ring.level
                                    scale: 1 + ring.bass * 0.03
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    anchors.margins: -5
                                    radius: mp.cr + 5
                                    color: "transparent"
                                    border.width: 1
                                    border.color: coverBox.ringColor
                                    opacity: ring.bass * 0.3 * ring.level
                                    scale: 1 + ring.bass * 0.05
                                }

                                Repeater {
                                    model: ring.geo

                                    Item {
                                        id: bar
                                        required property var modelData
                                        readonly property real v: ring.valAt(modelData.u, ring.vals)
                                        readonly property real pv: ring.valAt(modelData.u, ring.peaks)

                                        x: modelData.px
                                        y: modelData.py
                                        rotation: modelData.rot

                                        Rectangle {
                                            width: 2.4
                                            height: ring.minLen + bar.v * ring.maxLen
                                            radius: width / 2
                                            x: -width / 2
                                            y: -height
                                            // тихие палочки — акцентным цветом, громкие светлеют к кончику
                                            color: Qt.lighter(coverBox.ringColor, 1 + bar.v * 0.35)
                                            opacity: (0.3 + 0.7 * bar.v) * ring.level
                                        }

                                        // удерживаемый пик
                                        Rectangle {
                                            width: 2.4
                                            height: 1.6
                                            radius: 0.8
                                            x: -width / 2
                                            y: -(ring.minLen + bar.pv * ring.maxLen) - 3.5
                                            color: mp.colText
                                            visible: bar.pv > bar.v + 0.05
                                            opacity: Math.min(0.6, (bar.pv - bar.v) * 3) * ring.level
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                anchors.fill: parent
                                radius: mp.cr
                                antialiasing: true
                                color: mp.colSecondary
                                opacity: coverImg.status === Image.Ready ? 0.0 : 1.0

                                Behavior on opacity { NumberAnimation { duration: 200 } }

                                Icon {
                                    anchors.centerIn: parent
                                    name: "player"
                                    size: 36
                                    color: mp.colAccent
                                }
                            }

                            Image {
                                id: coverImg
                                anchors.fill: parent
                                source: coverBox.artUrl
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                                smooth: true
                                mipmap: true
                                sourceSize.width: 256
                                sourceSize.height: 256
                                opacity: status === Image.Ready ? 1.0 : 0.0

                                Behavior on opacity { NumberAnimation { duration: 200 } }

                                layer.enabled: true
                                layer.smooth: true
                                layer.mipmap: true
                                layer.textureSize: Qt.size(width * 2, height * 2)
                                layer.effect: MultiEffect {
                                    maskEnabled: true
                                    maskSource: coverMask
                                    maskThresholdMin: 0.5
                                    maskSpreadAtMin: 1.0
                                }

                                // стеклянный блик: скользит за курсором, обрезается маской обложки
                                Rectangle {
                                    width: 46
                                    height: parent.height * 1.8
                                    y: -parent.height * 0.4
                                    x: parent.width / 2 + mp.lookX * parent.width * 0.7 - width / 2
                                    rotation: 22
                                    opacity: Math.min(1, Math.hypot(mp.lookX, mp.lookY) * 1.2) * 0.9
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: "#00ffffff" }
                                        GradientStop { position: 0.5; color: "#2effffff" }
                                        GradientStop { position: 1.0; color: "#00ffffff" }
                                    }
                                }
                            }

                            Item {
                                id: coverMask
                                anchors.fill: parent
                                visible: false
                                layer.enabled: true

                                Rectangle {
                                    anchors.fill: parent
                                    radius: mp.cr
                                }
                            }
                        }

                        Column {
                            width: parent.width - coverBox.width - parent.spacing
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3


                            Text {
                                width: parent.width
                                visible: text !== ""
                                text: mp.hasPlayer ? (mp.player.identity || "") : ""
                                color: mp.colAccent
                                opacity: 0.8
                                font.pixelSize: 9
                                font.bold: true
                                font.letterSpacing: 1.2
                                font.capitalization: Font.AllUppercase
                                font.family: mp.fontFamily
                                elide: Text.ElideRight
                            }

                            Text {
                                width: parent.width
                                text: mp.hasPlayer ? (mp.player.trackTitle || tr("mp.untitled")) : tr("mp.noplayer")
                                color: mp.colText
                                font.pixelSize: 15
                                font.bold: true
                                font.family: mp.fontFamily
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }

                            Text {
                                width: parent.width
                                visible: text !== ""
                                text: mp.hasPlayer ? (mp.player.trackArtist || "") : tr("mp.hint")
                                color: Qt.alpha(mp.colText, 0.8)
                                font.pixelSize: 12
                                font.family: mp.fontFamily
                                elide: Text.ElideRight
                            }

                            Text {
                                width: parent.width
                                visible: text !== ""
                                text: mp.hasPlayer ? (mp.player.trackAlbum || "") : ""
                                color: Qt.alpha(mp.colText, 0.42)
                                font.pixelSize: 10
                                font.family: mp.fontFamily
                                elide: Text.ElideRight
                            }
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: 4
                        opacity: mp.hasPlayer ? 1.0 : 0.4

                        Item {
                            id: prog
                            width: parent.width
                            height: 32

                            readonly property bool hot: mp.canSeekNow && (seekBar.hovered || mp.seeking)
                            readonly property real hoverFrac: Math.max(0, Math.min(1, seekBar.hoverX / Math.max(1, width)))

                            FatSlider {
                                id: seekBar
                                anchors.fill: parent
                                value: mp.frac
                                usable: mp.canSeekNow
                                colAccent: mp.colAccent
                                colText: mp.colText
                                colBg: mp.colBg
                                fontFamily: mp.fontFamily
                                radius: mp.cr
                                onMoved: (v) => { mp.seekFrac = v }
                                onDraggingChanged: {
                                    if (dragging) mp.seeking = true
                                    else if (mp.seeking) { mp.seekTo(mp.seekFrac); mp.seeking = false }
                                }
                            }

                            Rectangle {
                                id: seekTip
                                width: tipText.implicitWidth + 12
                                height: 18
                                radius: 5
                                x: Math.max(0, Math.min(prog.width - width, seekBar.hoverX - width / 2))
                                y: -height - 2
                                color: Qt.alpha(mp.colBg, 0.92)
                                opacity: prog.hot ? 1.0 : 0.0
                                visible: opacity > 0

                                Behavior on opacity { NumberAnimation { duration: 120 } }

                                Text {
                                    id: tipText
                                    anchors.centerIn: parent
                                    text: mp.fmt((mp.seeking ? mp.seekFrac : prog.hoverFrac) * mp.len)
                                    color: mp.colText
                                    font.pixelSize: 10
                                    font.bold: true
                                    font.family: mp.fontFamily
                                }
                            }
                        }

                        Item {
                            width: parent.width
                            height: 12

                            Text {
                                anchors.left: parent.left
                                text: mp.fmt(mp.seeking ? mp.seekFrac * mp.len : mp.pos)
                                color: Qt.alpha(mp.colText, 0.6)
                                font.pixelSize: 10
                                font.bold: true
                                font.family: mp.fontFamily
                            }


                            Text {
                                anchors.right: parent.right
                                text: mp.len > 0 ? mp.fmt(mp.len) : "--:--"
                                color: Qt.alpha(mp.colText, 0.6)
                                font.pixelSize: 10
                                font.bold: true
                                font.family: mp.fontFamily
                            }
                        }
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 8

                        CtlBtn {
                            anchors.verticalCenter: parent.verticalCenter
                            icon: "shuffle"
                            iconSize: 15
                            active: mp.hasPlayer && mp.player.shuffleSupported && mp.player.shuffle
                            usable: mp.hasPlayer && mp.player.shuffleSupported
                            onClicked: mp.player.shuffle = !mp.player.shuffle
                        }

                        CtlBtn {
                            anchors.verticalCenter: parent.verticalCenter
                            icon: "skipPrev"
                            iconSize: 18
                            usable: mp.hasPlayer && mp.player.canGoPrevious
                            onClicked: mp.player.previous()
                        }

                        CtlBtn {
                            anchors.verticalCenter: parent.verticalCenter
                            size: 46
                            iconSize: 20
                            solid: true
                            icon: mp.playing ? "mediaPause" : "mediaPlay"
                            usable: mp.hasPlayer && mp.player.canTogglePlaying
                            onClicked: mp.player.togglePlaying()
                        }

                        CtlBtn {
                            anchors.verticalCenter: parent.verticalCenter
                            icon: "skipNext"
                            iconSize: 18
                            usable: mp.hasPlayer && mp.player.canGoNext
                            onClicked: mp.player.next()
                        }

                        CtlBtn {
                            anchors.verticalCenter: parent.verticalCenter
                            icon: mp.loopIcon()
                            iconSize: 15
                            active: mp.hasPlayer && mp.player.loopSupported && mp.player.loopState !== MprisLoopState.None
                            usable: mp.hasPlayer && mp.player.loopSupported
                            onClicked: mp.cycleLoop()
                        }
                    }

                    // регулятор громкости
                    FatSlider {
                        id: volRow
                        width: parent.width
                        glyph: mp.volGlyph()
                        value: mp.volFrac
                        usable: mp.volUsable
                        colAccent: mp.colAccent
                        colText: mp.colText
                        colBg: mp.colBg
                        fontFamily: mp.fontFamily
                        radius: mp.cr
                        onMoved: (v) => mp.setVolume(v)
                        onDraggingChanged: mp.volDrag = dragging
                        onGlyphClicked: mp.toggleMute()
                        onWheeled: (dir) => mp.volStep(dir * 0.05)
                    }

                    Rectangle {
                        id: eqBox
                        width: parent.width
                        color: "transparent"
                        height: eqHead.height + (eqContent.height > 0.5 ? eqContent.height + 4 : 0)

                        Rectangle {
                            id: eqHead
                            width: parent.width
                            height: 28
                            radius: mp.cr
                            color: Qt.alpha(mp.colText, eqHeadMa.containsMouse ? 0.06 : 0.0)

                            Behavior on color { ColorAnimation { duration: 150 } }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                text: tr("mp.eq")
                                color: Qt.alpha(mp.colText, 0.8)
                                font.pixelSize: 10
                                font.letterSpacing: 1.0
                                font.capitalization: Font.AllUppercase
                                font.bold: true
                                font.family: mp.fontFamily
                            }
                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.right: parent.right
                                anchors.rightMargin: 10
                                spacing: 6

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: mp.hoverText()
                                    color: mp.colAccent
                                    opacity: 0.85
                                    font.pixelSize: 10
                                    font.bold: true
                                    font.family: mp.fontFamily
                                }

                                Icon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: "chevronDown"
                                    size: 16
                                    color: Qt.alpha(mp.colText, 0.6)
                                    rotation: 180 * mp.eqP
                                }
                            }
                            MouseArea {
                                id: eqHeadMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: mp.eqOpen = !mp.eqOpen
                            }
                        }

                        Column {
                            id: eqContent
                            x: 0
                            y: eqHead.height + 2
                            width: parent.width
                            spacing: 8
                            clip: true
                            visible: height > 0.5
                            height: implicitHeight * mp.eqP
                            opacity: Math.max(0, Math.min(1, (mp.eqP - 0.55) / 0.45))

                            Flow {
                                width: parent.width
                                spacing: 2

                                // встроенные моды
                                Repeater {
                                    model: mp.eq.eqPresets

                                    Rectangle {
                                        id: chip
                                        required property var modelData
                                        readonly property bool active: mp.sameGains(mp.eq.eqGains, modelData.gains)
                                        width: plabel.implicitWidth + 16
                                        height: 22
                                        radius: mp.cr
                                        color: active ? Qt.alpha(mp.colAccent, 0.16)
                                                      : Qt.alpha(mp.colText, pma.containsMouse ? 0.08 : 0.0)

                                        Behavior on color { ColorAnimation { duration: 150 } }

                                        // нажатие: чип чуть сжимается и пружинит обратно
                                        SequentialAnimation {
                                            id: pulse
                                            NumberAnimation { target: chip; property: "scale"; to: 0.9; duration: 70; easing.type: Easing.OutQuad }
                                            NumberAnimation { target: chip; property: "scale"; to: 1; duration: 200; easing.type: Easing.OutBack; easing.overshoot: 2.5 }
                                        }

                                        Text {
                                            id: plabel
                                            anchors.centerIn: parent
                                            text: mp.presetName(modelData.name)
                                            color: parent.active ? mp.colAccent : Qt.alpha(mp.colText, 0.6)
                                            font.pixelSize: 10
                                            font.bold: true
                                            font.family: mp.fontFamily
                                        }

                                        MouseArea {
                                            id: pma
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                pulse.restart()
                                                mp.applyPreset(modelData.gains)
                                            }
                                        }
                                    }
                                }

                                // свои моды (до mp.maxCustom), у каждого есть крестик для удаления
                                Repeater {
                                    model: customModel

                                    Rectangle {
                                        id: cchip
                                        required property int index
                                        required property string name
                                        required property string gs

                                        property bool dying: false
                                        readonly property var gains: mp.parseGains(gs)
                                        readonly property bool active: mp.sameGains(mp.eq.eqGains, gains)

                                        width: clabel.implicitWidth + 30
                                        height: 22
                                        radius: mp.cr
                                        clip: true
                                        scale: 0.6
                                        opacity: 0
                                        color: active ? Qt.alpha(mp.colAccent, 0.16)
                                                      : Qt.alpha(mp.colText, cma.containsMouse ? 0.08 : 0.0)

                                        Behavior on color { ColorAnimation { duration: 150 } }

                                        Component.onCompleted: appear.start()

                                        // появление: вырастает с пружинкой
                                        ParallelAnimation {
                                            id: appear
                                            NumberAnimation { target: cchip; property: "scale"; to: 1; duration: 240; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
                                            NumberAnimation { target: cchip; property: "opacity"; to: 1; duration: 160 }
                                        }
                                        // удаление: тает, потом соседи плавно сдвигаются на его место
                                        SequentialAnimation {
                                            id: delAnim
                                            ParallelAnimation {
                                                NumberAnimation { target: cchip; property: "scale"; to: 0.7; duration: 120; easing.type: Easing.InQuad }
                                                NumberAnimation { target: cchip; property: "opacity"; to: 0; duration: 120 }
                                            }
                                            NumberAnimation { target: cchip; property: "width"; to: 0; duration: 150; easing.type: Easing.OutCubic }
                                            ScriptAction {
                                                script: {
                                                    customModel.remove(cchip.index)
                                                    mp.saveCustoms()
                                                }
                                            }
                                        }

                                        SequentialAnimation {
                                            id: cpulse
                                            NumberAnimation { target: cchip; property: "scale"; to: 0.9; duration: 70; easing.type: Easing.OutQuad }
                                            NumberAnimation { target: cchip; property: "scale"; to: 1; duration: 200; easing.type: Easing.OutBack; easing.overshoot: 2.5 }
                                        }

                                        Text {
                                            id: clabel
                                            anchors.left: parent.left
                                            anchors.leftMargin: 8
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: cchip.name
                                            color: cchip.active ? mp.colAccent : Qt.alpha(mp.colText, 0.6)
                                            font.pixelSize: 10
                                            font.bold: true
                                            font.family: mp.fontFamily
                                        }

                                        MouseArea {
                                            id: cma
                                            anchors.fill: parent
                                            enabled: !cchip.dying
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                cpulse.restart()
                                                mp.applyPreset(cchip.gains)
                                            }
                                        }

                                        // крестик «удалить» (поверх основной MouseArea)
                                        Rectangle {
                                            width: 14
                                            height: 14
                                            radius: 7
                                            anchors.right: parent.right
                                            anchors.rightMargin: 4
                                            anchors.verticalCenter: parent.verticalCenter
                                            color: Qt.alpha(mp.colText, xma.containsMouse ? 0.18 : 0.0)


                                            Behavior on color { ColorAnimation { duration: 120 } }

                                            Text {
                                                anchors.centerIn: parent
                                                anchors.verticalCenterOffset: -1
                                                text: "×"
                                                color: Qt.alpha(mp.colText, xma.containsMouse ? 0.95 : 0.45)
                                                font.pixelSize: 12
                                                font.bold: true
                                                font.family: mp.fontFamily
                                            }

                                            MouseArea {
                                                id: xma
                                                anchors.fill: parent
                                                enabled: !cchip.dying
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    cchip.dying = true
                                                    delAnim.start()
                                                }
                                            }
                                        }
                                    }
                                }

                                // «+ свой мод»: по клику плашка превращается в поле для названия
                                Rectangle {
                                    id: addChip
                                    visible: customModel.count < mp.maxCustom
                                    height: 22
                                    width: mp.naming ? 124 : 24
                                    radius: mp.cr
                                    clip: true
                                    color: Qt.alpha(mp.colAccent, mp.naming ? 0.12 : (addMa.containsMouse ? 0.1 : 0.0))
                                    border.width: 1
                                    border.color: mp.naming ? Qt.alpha(mp.colAccent, 0.6)
                                                            : Qt.alpha(mp.colText, addMa.containsMouse ? 0.3 : 0.16)

                                    Behavior on width { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    Behavior on border.color { ColorAnimation { duration: 150 } }

                                    Text {
                                        anchors.centerIn: parent
                                        text: "+"
                                        color: addMa.containsMouse ? mp.colAccent : Qt.alpha(mp.colText, 0.6)
                                        font.pixelSize: 13
                                        font.bold: true
                                        font.family: mp.fontFamily
                                        opacity: mp.naming ? 0 : 1
                                        visible: opacity > 0

                                        Behavior on opacity { NumberAnimation { duration: 120 } }
                                    }

                                    MouseArea {
                                        id: addMa
                                        anchors.fill: parent
                                        enabled: !mp.naming
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: mp.startNaming()
                                    }

                                    TextInput {
                                        id: nameInput
                                        anchors.left: parent.left
                                        anchors.leftMargin: 8
                                        anchors.right: parent.right
                                        anchors.rightMargin: 8
                                        anchors.verticalCenter: parent.verticalCenter
                                        enabled: mp.naming
                                        opacity: mp.naming ? 1 : 0
                                        visible: opacity > 0
                                        clip: true
                                        maximumLength: mp.maxNameLen
                                        color: mp.colText
                                        selectionColor: mp.colAccent
                                        selectedTextColor: mp.colBg
                                        font.pixelSize: 10
                                        font.bold: true
                                        font.family: mp.fontFamily

                                        property string okText: ""

                                        Behavior on opacity { NumberAnimation { duration: 140 } }

                                        // не больше mp.maxNameWords слов
                                        onTextEdited: {
                                            const w = text.trim().split(/\s+/).filter(x => x.length > 0)
                                            if (w.length > mp.maxNameWords) text = okText
                                            else okText = text
                                        }

                                        Keys.onReturnPressed: mp.commitName(text)
                                        Keys.onEnterPressed: mp.commitName(text)
                                        Keys.onEscapePressed: mp.cancelNaming()
                                        onActiveFocusChanged: if (!activeFocus && mp.naming) mp.cancelNaming()

                                        Text {
                                            visible: parent.text === "" && mp.naming
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: mp.trf("mp.eq.name", "Название")
                                            color: Qt.alpha(mp.colText, 0.35)
                                            font.pixelSize: 10
                                            font.bold: true
                                            font.family: mp.fontFamily
                                        }
                                    }
                                }
                            }
                            Row {
                                id: bands
                                width: parent.width
                                height: 96
                                opacity: mp.eq.eqOn ? 1.0 : 0.55

                                Behavior on opacity { NumberAnimation { duration: 150 } }

                                Repeater {
                                    model: 10

                                    Item {
                                        id: band
                                        required property int index
                                        readonly property real g: mp.eq.eqGains[index]
                                        // отображаемое значение плавно бежит к g;
                                        // при выборе мода — волной слева направо (по 22 мс на полосу)
                                        property real shown: g
                                        readonly property real frac: (shown + mp.eq.eqRange) / (2 * mp.eq.eqRange)
                                        readonly property string dbText: Math.abs(shown) < 0.05 ? "0"
                                            : (shown > 0 ? "+" : "") + (Math.round(shown * 10) / 10)

                                        Behavior on shown {
                                            enabled: !slot.dragging
                                            SequentialAnimation {
                                                PauseAnimation { duration: mp.presetAnim ? band.index * 22 : 0 }
                                                NumberAnimation {
                                                    duration: mp.presetAnim ? 380 : 110
                                                    easing.type: Easing.OutCubic
                                                }
                                            }
                                        }


                                        width: bands.width / 10
                                        height: bands.height

                                        // вертикальная полоска с водой: низ = -eqRange, верх = +eqRange, dB по центру
                                        FatSlider {
                                            id: slot
                                            vertical: true
                                            anchors.top: parent.top
                                            anchors.topMargin: 2
                                            anchors.bottom: fLabel.top
                                            anchors.bottomMargin: 4
                                            anchors.left: parent.left
                                            anchors.leftMargin: 2
                                            anchors.right: parent.right
                                            anchors.rightMargin: 2

                                            value: band.frac
                                            label: band.dbText
                                            textPx: 9
                                            colAccent: mp.colAccent
                                            colText: mp.colText
                                            colBg: mp.colBg
                                            fontFamily: mp.fontFamily
                                            radius: mp.cr

                                            onMoved: (v) => mp.eq.setGain(band.index, (v * 2 - 1) * mp.eq.eqRange)
                                            onWheeled: (dir) => mp.eq.setGain(band.index, band.g + dir * 0.5)
                                            onDoubleClicked: mp.eq.setGain(band.index, 0)
                                            onHoveredChanged: {
                                                if (hovered) mp.eqHover = band.index
                                                else if (mp.eqHover === band.index) mp.eqHover = -1
                                            }

                                            // метка 0 dB: две короткие чёрточки по краям, текст по центру не перекрывают
                                            Rectangle {
                                                x: 0
                                                y: (parent.height - height) / 2
                                                width: 4
                                                height: 1.5
                                                color: Qt.alpha(mp.colText, 0.5)
                                            }
                                            Rectangle {
                                                x: parent.width - width
                                                y: (parent.height - height) / 2
                                                width: 4
                                                height: 1.5
                                                color: Qt.alpha(mp.colText, 0.5)
                                            }
                                        }

                                        Text {
                                            id: fLabel
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            anchors.bottom: parent.bottom
                                            text: mp.eq.eqFreqs[band.index]
                                            color: mp.eqHover === band.index ? mp.colAccent : Qt.alpha(mp.colText, 0.4)
                                            font.pixelSize: 9
                                            font.bold: true
                                            font.family: mp.fontFamily
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
