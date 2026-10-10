// Bar.qml — само окно бара (PanelWindow).
// Тут рисуется панель с блоками (часы, трей, громкость, mpris и т.д.), её положение на экране
// (остров или во всю ширину, любая сторона), фон с блюром и подсветка при наведении.
// Данные берёт из Logic.qml, а панели, настройки и раскладка приходят снаружи через required property.

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.SystemTray
import Quickshell.Services.Mpris
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower

import "notifications"
import "bar"
import "panels"
import "settings"
import "common"
import "icons"
import "assets"
import "lang"

PanelWindow {
    id: bar

    required property var visualRoot
    required property var logic
    required property var barLayout
    required property var clipStore
    required property var ipcShell
    required property var settingsMenuComp
    required property var calendarComp
    required property var sysMenuComp
    required property var volMenuComp
    required property var mprisPanelComp
    required property var lyricsPanelComp
    required property var lyricsComp
    required property var notifCenterComp
    required property var clipPanelComp
    required property var trayPanelComp
    required property var btMenuComp
    required property var wsOverviewComp
    required property var controlCenterComp

    readonly property bool island: barLayout.island !== false
    readonly property real edgeGap: island ? 6 : 0
    readonly property real sideGap: island ? 8 : 0
    readonly property real cornerBase: island ? 9 : 0

    readonly property real edgePad: island ? 0 : 8

    readonly property real edgeShift: island ? 0 : 4

    readonly property string wallpaperPath: backdrop.wallpaperPath
    function redetectBackdrop() { backdrop.redetect() }

    function pillOf(it) {
        const p = it ? it.parent : null
        if (!p || p.pill === undefined) return logic.colGlass
        return p.pill
    }

    property bool mprisHovered: false
    property bool lyricsHovered: false

    // настройка «Автоскрытие лирики» из меню mpris идёт в сервис Lyrics: autoHide=false => lyricsComp.pinned
    Binding { target: bar.lyricsComp; property: "autoHide"; value: bar.barLayout.lyricsAutoHide }

    // mpris и lyrics сами больше не склеиваются, только если юзер включил соединение в редакторе.
    // эта функция просто находит «пару», чтобы они подсвечивались вместе при наведении
    // и чтобы прятать разделитель внутри уже соединённой плашки
    function autoPair(a, b) {
        return (a === "mpris" && b === "lyrics") || (a === "lyrics" && b === "mpris")
    }

    // радиус подсветки при наведении: на стыке соединённых блоков 0, иначе будут «выемки»
    function hoverR(it, corner, base) {
        const p = it ? it.parent : null
        if (!p || p.joinPrev === undefined) return base
        const atStart = corner === 0 || corner === 3
        return (atStart ? p.joinPrev : p.joinNext) ? 0 : base
    }

    // координата вдоль оси бара (в окне), lx — позиция внутри slideWrapper
    function axisAt(lx) {
        const r = slideWrapper.toWindowSmooth(lx, 0, 0, 0)
        return bar.sideGap + (bar.vertical ? r.y : r.x)
    }

    // true, если точка lx лежит под открытой панелью (панель прирастает к бару)
    function underPanel(lx) {
        const pn = visualRoot.attachedPanel
        if (!pn) return false
        const a = axisAt(lx)
        const s0 = bar.vertical ? pn.py : pn.px
        const e0 = s0 + (bar.vertical ? pn.ph : pn.pw)
        return a >= s0 - 1 && a <= e0 + 1
    }

    // радиус угла блока; у соединённых блоков на стыке скругление убираем
    function cornerR(it, corner, r) {
        const cutTop = bar.applied === "bottom" || bar.applied === "left"

        if ((corner < 2) !== cutTop) return bar.island ? r : 0
        const p = it ? it.parent : null
        if (!p || p.cutS === undefined) return r
        const atStart = corner === 0 || corner === 3
        return (atStart ? p.cutS : p.cutE) ? 0 : r
    }

    // какая доля ширины w (центр в c) попадает в диапазон [-half, half], от 0 до 1
    function coverage(c, w, half) {
        const lo = Math.max(c - w / 2, -half)
        const hi = Math.min(c + w / 2, half)
        return Math.max(0, Math.min(1, (hi - lo) / Math.max(w, 1)))
    }

    function blockAnchor(id) {
        const dep = barLayout.rev
        const i = barLayout.allBlocks.indexOf(id)
        const ld = blockRep.count > i ? blockRep.itemAt(i) : null
        if (!ld || ld.width < 1 || ld.height < 1 || !bar.screen) return visualRoot.noRect

        let gx = ld.x
        let gw = ld.width
        const gl = slideWrapper.groupList
        for (let gi = 0; gi < gl.length; gi++) {
            if (gl[gi].members.indexOf(ld) >= 0) {
                gx = gl[gi].head.x
                gw = gl[gi].tail.x + gl[gi].tail.width - gl[gi].head.x
                break
            }
        }

        const solidNow = barLayout.solidBar
        const ly = solidNow ? ld.y - (36 - ld.height) / 2 : ld.y
        const lh = solidNow ? 36 : ld.height
        const r = slideWrapper.toWindow(gx, ly, gw, lh)

        const horiz = !bar.vertical
        const ox = horiz ? bar.sideGap : (bar.applied === "left" ? 0 : bar.screen.width - bar.width)
        const oy = horiz ? (bar.applied === "top" ? 0 : bar.screen.height - bar.height) : bar.sideGap
        const x = ox + r.x
        const y = oy + r.y

        let lo = horiz ? x : y
        let hi = horiz ? x + r.w : y + r.h
        if (solidNow) {
            lo = horiz ? ox : oy
            hi = horiz ? ox + bar.width : oy + bar.height
        }

        const spans = []
        if (solidNow) {
            spans.push([lo, hi])
        } else {
            for (let k = 0; k < blockRep.count; k++) {
                const b = blockRep.itemAt(k)
                if (!b || !b.visible || b.width < 1) continue
                spans.push([axisAt(b.x), axisAt(b.x + b.width)])
            }
            spans.push([axisAt(settingsBtn.x), axisAt(settingsBtn.x + settingsBtn.width)])
        }
        return { x: x, y: y, w: r.w, h: r.h, lo: lo, hi: hi, spans: spans }
    }

    function blockComponent(id) {
        switch (id) {
        case "ws": return cWs
        case "mpris": return cMpris
        case "bt": return cBt
        case "app": return cApp
        case "search": return cSearch
        case "sys": return cSys
        case "notif": return cNotif
        case "vol": return cVol
        case "battery": return cBattery
        case "clip": return cClip
        case "tray": return cTray
        case "lyrics": return cLyrics
        }
        return null
    }

    readonly property string requested: barLayout.position
    property string applied: "bottom"
    readonly property bool vertical: applied === "left" || applied === "right"

    onRequestedChanged: {
        if (requested === applied) return
        if (introAnim.running) applied = requested
        else swapAnim.restart()
    }

    anchors {
        top: bar.applied !== "bottom"
        bottom: bar.applied !== "top"
        left: bar.applied !== "right"
        right: bar.applied !== "left"
    }

    margins {
        top: bar.vertical ? bar.sideGap : 0
        bottom: bar.vertical ? bar.sideGap : 0
        left: bar.vertical ? 0 : bar.sideGap
        right: bar.vertical ? 0 : bar.sideGap
    }

    readonly property real barLen: screen ? (vertical ? screen.height : screen.width) - 2 * sideGap : 0

    implicitWidth: bar.vertical ? 50 : Math.max(0, barLen)
    implicitHeight: bar.vertical ? Math.max(0, barLen) : 50

    onAppliedChanged: slideWrapper.settle()
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "bar"
    WlrLayershell.exclusiveZone: barLayout.autoHide ? 0 : 36 + bar.edgeGap
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    mask: Region {
        item: hitBox
    }

    Item {
        id: barContainer
        anchors.fill: parent
        clip: true

        readonly property real stripX: !bar.vertical ? 0
            : (bar.applied === "left" ? bar.edgeGap - slideWrapper.slide : width - bar.edgeGap - 36 + slideWrapper.slide)
        readonly property real stripY: bar.vertical ? 0
            : (bar.applied === "top" ? bar.edgeGap - slideWrapper.slide : height - bar.edgeGap - 36 + slideWrapper.slide)

        readonly property bool autoHide: barLayout.autoHide

        property bool anyRevealed: false

        readonly property real peek: 6
        readonly property real hitThick: autoHide ? (anyRevealed ? 36 + bar.edgeGap : peek) : 36

        Item {
            id: hitBox
            x: barContainer.autoHide
                ? (bar.applied === "right" ? barContainer.width - barContainer.hitThick : 0)
                : barContainer.stripX
            y: barContainer.autoHide
                ? (bar.applied === "bottom" ? barContainer.height - barContainer.hitThick : 0)
                : barContainer.stripY
            width: bar.vertical ? barContainer.hitThick : barContainer.width
            height: bar.vertical ? barContainer.height : barContainer.hitThick
        }

        HoverHandler {
            id: hover
            enabled: barContainer.autoHide
            onHoveredChanged: {
                if (hovered) {
                    hideTimer.stop()
                    slideWrapper.hoverActive = true
                } else {
                    hideTimer.restart()
                }
                slideWrapper.updateHover()
            }
            onPointChanged: slideWrapper.updateHover()
        }

        Timer {
            id: hideTimer
            interval: 350
            onTriggered: {
                slideWrapper.hoverActive = false
                slideWrapper.updateHover()
            }
        }

        readonly property real winOx: !bar.screen ? 0
            : (!bar.vertical ? bar.sideGap : (bar.applied === "left" ? 0 : bar.screen.width - bar.width))
        readonly property real winOy: !bar.screen ? 0
            : (bar.vertical ? bar.sideGap : (bar.applied === "top" ? 0 : bar.screen.height - bar.height))

        LiveBackdrop {
            id: backdrop
            active: visualRoot.blurOn
            screenObj: bar.screen
            wallpaper: visualRoot.wallpaper
            roi: Qt.rect(barContainer.winOx, barContainer.winOy, bar.width, bar.height)
            pollInterval: 1200
            trackFast: true
            prewarm: 160
            slideWorkspaces: false
            x: -100000
            y: -100000
        }

        readonly property bool blurReady: backdrop.width > 0 && visualRoot.blurOn

        BarBlur {
            source: barContainer.blurReady ? backdrop.texture : null
            srcSize: Qt.size(backdrop.width, backdrop.height)
            originX: barContainer.winOx
            originY: barContainer.winOy
            rect: slideWrapper.solidBlur()
            cornerRadius: bar.cornerBase * slideWrapper.fit

            corners: {
                const f = slideWrapper.fit
                const a = solidBg.topLeftRadius * f, b = solidBg.topRightRadius * f
                const c = solidBg.bottomRightRadius * f, d = solidBg.bottomLeftRadius * f
                return bar.vertical ? Qt.vector4d(d, a, b, c) : Qt.vector4d(a, b, c, d)
            }
            blurRadius: visualRoot.blurRadius
            tint: visualRoot.blurTint
            strength: slideWrapper.opacity * solidBg.opacity
        }

        Repeater {
            model: blockRep.count

            delegate: BarBlur {
                id: pillBlur
                required property int index
                readonly property Item ld: blockRep.count > index ? blockRep.itemAt(index) : null

                source: barContainer.blurReady ? backdrop.texture : null
                srcSize: Qt.size(backdrop.width, backdrop.height)
                originX: barContainer.winOx
                originY: barContainer.winOy
                rect: slideWrapper.blockBlur(index)
                cornerRadius: 6 * slideWrapper.fit
                corners: {
                    const r = 6 * slideWrapper.fit
                    const cs = pillBlur.ld ? pillBlur.ld.cutS : false
                    const ce = pillBlur.ld ? pillBlur.ld.cutE : false
                    const cT = bar.applied === "bottom" || bar.applied === "left"
                    const e = bar.island ? r : 0
                    const a = cT ? (cs ? 0 : r) : e, b = cT ? (ce ? 0 : r) : e
                    const c = cT ? e : (ce ? 0 : r), d = cT ? e : (cs ? 0 : r)
                    return bar.vertical ? Qt.vector4d(d, a, b, c) : Qt.vector4d(a, b, c, d)
                }
                blurRadius: visualRoot.blurRadius
                tint: visualRoot.blurTint

                property real alone: ld && ld.grouped ? 0 : 1
                Behavior on alone {
                    NumberAnimation { duration: pillBlur.ld && pillBlur.ld.grouped ? 180 : 0; easing.type: Easing.OutCubic }
                }
                strength: ld ? alone * (1 - ld.pillFade)
                               * slideWrapper.opacity * (ld.item ? ld.item.opacity : 1) : 0
            }
        }

        Repeater {
            model: groupRep.count

            delegate: BarBlur {
                id: groupBlur
                required property int index
                readonly property Item g: groupRep.count > index ? groupRep.itemAt(index) : null

                source: barContainer.blurReady ? backdrop.texture : null
                srcSize: Qt.size(backdrop.width, backdrop.height)
                originX: barContainer.winOx
                originY: barContainer.winOy
                rect: g ? slideWrapper.toWindowSmooth(g.x, g.y, g.width, g.height) : slideWrapper.noBlur
                cornerRadius: 6 * slideWrapper.fit
                corners: {
                    const f = slideWrapper.fit
                    const a = g ? g.topLeftRadius * f : 6 * f, b = g ? g.topRightRadius * f : 6 * f
                    const c = g ? g.bottomRightRadius * f : 6 * f, d = g ? g.bottomLeftRadius * f : 6 * f
                    return bar.vertical ? Qt.vector4d(d, a, b, c) : Qt.vector4d(a, b, c, d)
                }
                blurRadius: visualRoot.blurRadius
                tint: visualRoot.blurTint
                strength: g ? (1 - g.fade) * slideWrapper.opacity : 0
            }
        }

        BarBlur {
            source: barContainer.blurReady ? backdrop.texture : null
            srcSize: Qt.size(backdrop.width, backdrop.height)
            originX: barContainer.winOx
            originY: barContainer.winOy
            rect: slideWrapper.settingsBlur()
            cornerRadius: 6 * slideWrapper.fit
            blurRadius: visualRoot.blurRadius
            tint: visualRoot.blurTint
            strength: slideWrapper.opacity * (1 - bar.coverage(
                settingsBtn.x + settingsBtn.width / 2 - slideWrapper.width / 2,
                settingsBtn.width, slideWrapper.width * slideWrapper.fill / 2))
        }

        Item {
            id: slideWrapper

            property real slide: 85

            function toWindow(lx, ly, lw, lh) {
                const f = fit
                if (!bar.vertical) {
                    return {
                        x: Math.round(x + lx * f),
                        y: Math.round(y + 18 + (ly - 18) * f),
                        w: Math.round(lw * f),
                        h: Math.round(lh * f)
                    }
                }
                const cx = x + width / 2
                const cy = y + 18
                const dx = lx - width / 2
                const dy = ly - 18
                return {
                    x: Math.round(cx - (dy + lh) * f),
                    y: Math.round(cy + dx * f),
                    w: Math.round(lh * f),
                    h: Math.round(lw * f)
                }
            }

            function toWindowSmooth(lx, ly, lw, lh) {
                const f = fit
                if (!bar.vertical) {
                    return { x: x + lx * f, y: y + 18 + (ly - 18) * f, w: lw * f, h: lh * f }
                }
                const cx = x + width / 2
                const cy = y + 18
                const dx = lx - width / 2
                const dy = ly - 18
                return { x: cx - (dy + lh) * f, y: cy + dx * f, w: lh * f, h: lw * f }
            }

            readonly property var noBlur: ({ x: 0, y: 0, w: 0, h: 0 })

            function blockBlur(i) {
                if (opacity < 0.02 || blockRep.count <= i) return noBlur
                const ld = blockRep.itemAt(i)
                if (!ld || !ld.visible || ld.width < 1 || ld.height < 1) return noBlur
                const ph = Math.min(ld.height, 30)
                return toWindowSmooth(ld.x, ld.y + (ld.height - ph) / 2, ld.width, ph)
            }

            function settingsBlur() {
                if (opacity < 0.02) return noBlur
                return toWindowSmooth(settingsBtn.x, settingsBtn.y, settingsBtn.width, settingsBtn.height)
            }

            function solidBlur() {
                if (opacity < 0.02 || fill < 0.001) return noBlur
                return toWindowSmooth(solidBg.x, solidBg.y, solidBg.width, solidBg.height)
            }

            property real fit: 1
            readonly property real physLen: bar.barLen > 0 ? bar.barLen : (bar.vertical ? barContainer.height : barContainer.width)
            width: physLen / fit
            height: 36
            scale: fit
            rotation: bar.vertical ? 90 : 0

            transformOrigin: bar.vertical ? Item.Center : Item.Left
            x: bar.vertical ? barContainer.stripX + 18 - width / 2 : barContainer.stripX
            y: bar.vertical ? barContainer.stripY + barContainer.height / 2 - 18 : barContainer.stripY
            opacity: 0.0

            Anim {
                id: introAnim
                targetItem: slideWrapper
            }

            SequentialAnimation {
                id: swapAnim

                ParallelAnimation {
                    NumberAnimation { target: slideWrapper; property: "slide"; to: 85; duration: 280; easing.type: Easing.InCubic }
                    NumberAnimation { target: slideWrapper; property: "opacity"; to: 0.0; duration: 240; easing.type: Easing.InCubic }
                }
                ScriptAction { script: bar.applied = bar.requested }
                PauseAnimation { duration: 140 }
                ParallelAnimation {
                    NumberAnimation { target: slideWrapper; property: "slide"; to: 0; duration: 520; easing.type: Easing.OutCubic }
                    NumberAnimation { target: slideWrapper; property: "opacity"; to: 1.0; duration: 420; easing.type: Easing.OutCubic }
                }
            }

            readonly property int gap: 8
            property bool animateMove: false

            property bool groupSnap: false
            readonly property bool colorAnim: !animating && !groupSnap
            Timer {
                id: groupSnapTimer
                interval: 60
                onTriggered: slideWrapper.groupSnap = false
            }

            property var groupList: []
            property string groupKey: ""

            property bool hoverActive: false
            readonly property real hideDist: (33 + bar.edgeGap - barContainer.peek) / fit

            readonly property int hideSign: (bar.applied === "bottom" || bar.applied === "left") ? 1 : -1

            Connections {
                target: barLayout
                function onAutoHideChanged() { slideWrapper.updateHover() }
            }

            function updateHover() {
                if (!barLayout.autoHide) {
                    barContainer.anyRevealed = false
                    for (let i = 0; i < blockRep.count; i++) {
                        const l = blockRep.itemAt(i)
                        if (l) l.near = false
                    }
                    settingsBtn.near = false
                    return
                }

                const m = 26
                let px = -1e6
                if (hoverActive) {
                    const p = slideWrapper.mapFromItem(barContainer, hover.point.position.x, hover.point.position.y)
                    px = p.x
                }

                let any = false
                for (let i = 0; i < blockRep.count; i++) {
                    const ld = blockRep.itemAt(i)
                    if (!ld) continue
                    const near = hoverActive && ld.visible && ld.width > 0
                                 && px >= ld.targetX - m && px <= ld.targetX + ld.width + m
                    ld.near = near
                    if (near || ld.keep) any = true
                }

                for (let gi = 0; gi < groupList.length; gi++) {
                    const mem = groupList[gi].members
                    let gAny = false
                    for (let mi = 0; mi < mem.length; mi++) if (mem[mi].near || mem[mi].keep) gAny = true
                    if (gAny) {
                        for (let mi = 0; mi < mem.length; mi++) mem[mi].near = true
                        any = true
                    }
                }

                const sNear = hoverActive && px >= settingsBtn.x - m && px <= settingsBtn.x + settingsBtn.width + m
                settingsBtn.near = sNear
                if (sNear) any = true

                barContainer.anyRevealed = any
            }

            function snapAll() {
                if (animateMove) return
                for (let i = 0; i < blockRep.count; i++) {
                    const ld = blockRep.itemAt(i)
                    if (ld) ld.snap()
                }
            }

            Timer {
                id: moveTimer
                interval: 340
                onTriggered: {
                    slideWrapper.animateMove = false
                    slideWrapper.snapAll()
                }
            }

            Connections {
                target: barLayout
                function onRevChanged() {
                    slideWrapper.animateMove = true
                    moveTimer.restart()
                    slideWrapper.relayout()
                }
            }
            onPhysLenChanged: relayout()
            Component.onCompleted: Qt.callLater(relayout)

            property int settleRuns: 0
            function settle() {
                settleRuns = 0
                settleTimer.restart()
                relayout()
                snapAll()
            }
            Timer {
                id: settleTimer
                interval: 80
                repeat: true
                onTriggered: {
                    slideWrapper.relayout()
                    slideWrapper.snapAll()
                    if (++slideWrapper.settleRuns >= 8) stop()
                }
            }

            Connections {
                target: barContainer
                function onWidthChanged() { slideWrapper.relayout() }
                function onHeightChanged() { slideWrapper.relayout() }
            }

            function isShown(ld) {
                return !ld.item || ld.item.shown !== false
            }
            function pres(ld) {
                return (ld.item && ld.item.opacity !== undefined) ? ld.item.opacity : 1
            }

            function relayout() {
                const ids = barLayout.allBlocks
                if (blockRep.count < ids.length) return
                if (physLen <= 0) return
                const zoneNames = ["left", "center", "right"]
                const lists = []
                const totals = []
                const zonePres = [0, 0, 0]

                for (let k = 0; k < 3; k++) {
                    const m = barLayout.model(zoneNames[k])
                    const list = []
                    let total = 0
                    let shownCount = 0
                    let prevPres = 0
                    let prevLd = null
                    let prevId = ""

                    for (let i = 0; i < m.count; i++) {
                        const ld = blockRep.itemAt(ids.indexOf(m.get(i).blockId))
                        if (!ld) continue
                        list.push(ld)
                        if (isShown(ld)) {
                            const bid = m.get(i).blockId
                            const jn = shownCount > 0 && barLayout.isJoined(bid)
                            const pr = pres(ld)
                            ld.joinPrev = jn
                            ld.joinNext = false
                            const pair = jn && bar.autoPair(prevId, bid)
                            ld.joinedPair = pair
                            if (jn && prevLd) prevLd.joinNext = true
                            if (pair && prevLd) prevLd.joinedPair = true
                            prevLd = ld
                            prevId = bid
                            ld.gapBefore = (shownCount > 0 && !jn) ? gap * Math.min(prevPres, pr) : 0
                            total += ld.gapBefore + ld.width
                            prevPres = pr
                            zonePres[k] = Math.max(zonePres[k], pr)
                            shownCount++
                        } else {
                            ld.joinPrev = false
                            ld.joinNext = false
                            ld.joinedPair = false
                            ld.gapBefore = 0
                        }
                    }
                    lists.push(list)
                    totals.push(total)
                }

                const sw = settingsBtn.width
                const need = totals[0] + totals[1] + totals[2] + sw + (zonePres[0] + zonePres[1] + zonePres[2]) * gap + 2 * bar.edgePad
                const f = need > physLen ? Math.max(0.5, physLen / need) : 1
                if (Math.abs(f - fit) > 0.001) fit = f

                const W = physLen / f
                const rightStart = W - bar.edgePad - sw - (totals[2] + gap * zonePres[2])
                const leftEnd = bar.edgePad + totals[0] + gap * zonePres[0]

                let cs = (W - totals[1]) / 2
                const hi = rightStart - gap - totals[1]
                cs = Math.max(leftEnd, Math.min(cs, hi))

                const starts = [bar.edgePad, cs, rightStart]
                const grps = []
                for (let k = 0; k < 3; k++) {
                    let x = starts[k]
                    let cur = null
                    for (let j = 0; j < lists[k].length; j++) {
                        const ld = lists[k][j]
                        if (!isShown(ld)) {
                            ld.targetX = x
                            continue
                        }
                        x += ld.gapBefore
                        ld.targetX = x
                        x += ld.width
                        if (ld.joinPrev && cur) {
                            cur.push(ld)
                        } else {
                            cur = [ld]
                            grps.push(cur)
                        }
                    }
                }

                const real = grps.filter(g => g.length > 1)
                const key = real.map(g => g.map(l => l.modelData).join(">")).join("|")
                if (key !== groupKey) {
                    if (!animateMove) {
                        groupSnap = true
                        groupSnapTimer.restart()
                    }
                }

                const inGroup = {}
                for (let gi = 0; gi < real.length; gi++)
                    for (let mi = 0; mi < real[gi].length; mi++) inGroup[real[gi][mi].modelData] = true
                for (let k = 0; k < 3; k++)
                    for (let j = 0; j < lists[k].length; j++)
                        lists[k][j].grouped = inGroup[lists[k][j].modelData] === true

                if (key !== groupKey) {
                    groupKey = key
                    groupList = real.map(g => ({ head: g[0], tail: g[g.length - 1], members: g }))
                }
                updateHover()
            }

            property real fill: barLayout.solidBar ? 1.0 : 0.0
            Behavior on fill {
                NumberAnimation {
                    duration: barLayout.solidBar ? 900 : 700
                    easing.type: barLayout.solidBar ? Easing.OutCubic : Easing.InOutCubic
                }
            }

            readonly property bool animating: fill > 0.001 && fill < 0.999

            Connections {
                target: barLayout
                function onSolidBarChanged() { if (barLayout.solidBar) shimmerAnim.restart() }
            }

            property real bgReveal: (!barLayout.autoHide || barContainer.anyRevealed) ? 1.0 : 0.0
            Behavior on bgReveal { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            Rectangle {
                id: solidBg
                visible: slideWrapper.fill > 0.001
                width: slideWrapper.width * slideWrapper.fill
                height: slideWrapper.height
                x: (slideWrapper.width - width) / 2
                y: slideWrapper.hideSign * (1 - slideWrapper.bgReveal) * ((36 + bar.edgeGap - barContainer.peek) / slideWrapper.fit)
                color: logic.colGlass

                readonly property var coverPanel: visualRoot.attachedPanel
                readonly property bool cutTop: bar.applied === "bottom" || bar.applied === "left"
                readonly property real pStart: coverPanel ? (bar.vertical ? coverPanel.py : coverPanel.px) : 0
                readonly property real pEnd: coverPanel ? pStart + (bar.vertical ? coverPanel.ph : coverPanel.pw) : 0
                readonly property bool cutStart: coverPanel !== null && pStart <= coverPanel.anchorRect.lo + 0.5
                readonly property bool cutEnd: coverPanel !== null && pEnd >= coverPanel.anchorRect.hi - 0.5
                topLeftRadius: cutTop && cutStart ? 0 : bar.cornerBase
                topRightRadius: cutTop && cutEnd ? 0 : bar.cornerBase
                bottomLeftRadius: !cutTop && cutStart ? 0 : bar.cornerBase
                bottomRightRadius: !cutTop && cutEnd ? 0 : bar.cornerBase
                Behavior on topLeftRadius { NumberAnimation { duration: 120 } }
                Behavior on topRightRadius { NumberAnimation { duration: 120 } }
                Behavior on bottomLeftRadius { NumberAnimation { duration: 120 } }
                Behavior on bottomRightRadius { NumberAnimation { duration: 120 } }
                opacity: Math.min(1, slideWrapper.fill * 6)

                Behavior on color { enabled: slideWrapper.colorAnim; ColorAnimation { duration: 300 } }

                Item {
                    anchors.fill: parent
                    anchors.margins: 1
                    clip: true

                    Rectangle {
                        id: shimmer
                        width: 200
                        height: parent.height
                        x: -width
                        opacity: 0
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: Qt.alpha(logic.colAccent, 0) }
                            GradientStop { position: 0.5; color: Qt.alpha(logic.colAccent, 0.22) }
                            GradientStop { position: 1.0; color: Qt.alpha(logic.colAccent, 0) }
                        }
                    }
                }
            }

            SequentialAnimation {
                id: shimmerAnim
                PauseAnimation { duration: 180 }
                ParallelAnimation {
                    NumberAnimation { target: shimmer; property: "x"; from: -shimmer.width; to: slideWrapper.width; duration: 850; easing.type: Easing.InOutSine }
                    SequentialAnimation {
                        NumberAnimation { target: shimmer; property: "opacity"; to: 1; duration: 200 }
                        PauseAnimation { duration: 450 }
                        NumberAnimation { target: shimmer; property: "opacity"; to: 0; duration: 200 }
                    }
                }
            }

            Rectangle {
                visible: !bar.island && slideWrapper.fill < 0.999
                x: 0
                width: slideWrapper.width
                height: 0
                y: slideWrapper.hideSign > 0 ? 0 : slideWrapper.height - 1
                color: Qt.alpha(logic.colText, 0.12)
                opacity: (1 - slideWrapper.fill) * slideWrapper.bgReveal
            }

            Repeater {
                id: groupRep
                model: slideWrapper.groupList

                delegate: Rectangle {
                    id: grp
                    required property var modelData
                    readonly property Item hd: modelData.head
                    readonly property Item tl: modelData.tail
                    readonly property var members: modelData.members

                    x: hd.x
                    y: hd.y + Math.round((hd.height - height) / 2)
                    width: Math.max(0, tl.x + tl.width - hd.x)
                    height: 30
                    radius: 6

                    readonly property real fade: bar.coverage(
                        (hd.targetX + tl.targetX + tl.width) / 2 - slideWrapper.width / 2, width,
                        slideWrapper.width * slideWrapper.fill / 2)
                    color: Qt.alpha(logic.colGlass, logic.colGlass.a * (1 - fade))

                    readonly property bool cutS: bar.underPanel(hd.x)
                    readonly property bool cutE: bar.underPanel(tl.x + tl.width)
                    readonly property bool cutTop: bar.applied === "bottom" || bar.applied === "left"

                    readonly property real edgeR: bar.island ? 6 : 0
                    topLeftRadius: cutTop ? (cutS ? 0 : 6) : edgeR
                    topRightRadius: cutTop ? (cutE ? 0 : 6) : edgeR
                    bottomRightRadius: cutTop ? edgeR : (cutE ? 0 : 6)
                    bottomLeftRadius: cutTop ? edgeR : (cutS ? 0 : 6)

                    Behavior on topLeftRadius { NumberAnimation { duration: 120 } }
                    Behavior on topRightRadius { NumberAnimation { duration: 120 } }
                    Behavior on bottomLeftRadius { NumberAnimation { duration: 120 } }
                    Behavior on bottomRightRadius { NumberAnimation { duration: 120 } }

                    opacity: 0.0
                    Component.onCompleted: opacity = 1.0
                    Behavior on opacity { enabled: !slideWrapper.groupSnap; NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                    Behavior on color { enabled: slideWrapper.colorAnim; ColorAnimation { duration: 300 } }

                    Repeater {
                        model: Math.max(0, grp.members.length - 1)

                        Rectangle {
                            required property int index
                            visible: !bar.autoPair(grp.members[index].modelData, grp.members[index + 1].modelData)
                            x: grp.members[index + 1].x - grp.x - 0.5
                            y: Math.round((grp.height - height) / 2)
                            width: 1
                            height: 14
                            radius: 0.5
                            color: Qt.alpha(logic.colText, 0.16)
                        }
                    }
                }
            }

            Repeater {
                id: blockRep
                model: barLayout.allBlocks

                delegate: Loader {
                    id: blk
                    required property string modelData

                    property real targetX: 0

                    readonly property real pillFade: bar.coverage(
                        targetX + width / 2 - slideWrapper.width / 2, width, slideWrapper.width * slideWrapper.fill / 2)

                    readonly property bool cutS: bar.underPanel(x)
                    readonly property bool cutE: bar.underPanel(x + width)

                    property bool grouped: false

                    property bool joinPrev: false
                    property bool joinNext: false
                    property bool joinedPair: false

                    property real gapBefore: 0
                    readonly property color pill: grouped ? "transparent" : Qt.alpha(logic.colGlass, logic.colGlass.a * (1 - pillFade))

                    property bool near: false
                    readonly property bool keep: item ? item.keepOpen === true : false
                    property real reveal: (!barLayout.autoHide || near || keep || (visualRoot.solid && barContainer.anyRevealed)) ? 1.0 : 0.0
                    Behavior on reveal { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                    onKeepChanged: slideWrapper.updateHover()

                    sourceComponent: bar.blockComponent(modelData)

                    visible: !item || item.shown !== false

                    y: Math.round((slideWrapper.height - height) / 2) + slideWrapper.hideSign * ((1 - reveal) * slideWrapper.hideDist + bar.edgeShift)

                    onTargetXChanged: x = targetX
                    Component.onCompleted: x = targetX

                    function snap() {
                        xAnim.stop()
                        x = targetX
                    }

                    Behavior on x {
                        enabled: slideWrapper.animateMove
                        NumberAnimation { id: xAnim; duration: 280; easing.type: Easing.OutCubic }
                    }
                    onWidthChanged: slideWrapper.relayout()
                    onItemChanged: slideWrapper.relayout()
                    onVisibleChanged: slideWrapper.relayout()
                }
            }

            SettingsButton {
                id: settingsBtn
                x: slideWrapper.width - bar.edgePad - width

                animateColor: slideWrapper.colorAnim
                glass: Qt.alpha(logic.colGlass, logic.colGlass.a * (1 - bar.coverage(
                    x + width / 2 - slideWrapper.width / 2, width, slideWrapper.width * slideWrapper.fill / 2)))

                property bool near: false
                property real reveal: (!barLayout.autoHide || near || (visualRoot.solid && barContainer.anyRevealed)) ? 1.0 : 0.0
                Behavior on reveal { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                y: Math.round((slideWrapper.height - height) / 2) + slideWrapper.hideSign * ((1 - reveal) * slideWrapper.hideDist + bar.edgeShift)

                colBg: logic.colBg
                colAccent: logic.colAccent
                colText: logic.colText
                colSecondary: logic.colSecondary

                onClicked: {
                    settingsMenuComp.toggleMenu()
                }
            }
        }
    }

    Component {
        id: cWs

                    Item {
                        id: wsContainer
                        readonly property bool shown: opacity > 0
                        height: 30
                        opacity: settingsMenuComp.showWorkspaces ? 1.0 : 0.0
                        property real expandedWidth: wsRect.implicitWidth
                        width: settingsMenuComp.showWorkspaces ? expandedWidth : 0
                        visible: opacity > 0
                        clip: true
                        anchors.verticalCenter: parent.verticalCenter

                        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutExpo } }

                        Rectangle {
                            id: wsRect
                            height: 30
                            implicitWidth: wsRow.implicitWidth + 16
                            radius: 6
                            color: bar.pillOf(wsContainer)
                            topLeftRadius: bar.cornerR(wsContainer, 0, 6)
                            topRightRadius: bar.cornerR(wsContainer, 1, 6)
                            bottomRightRadius: bar.cornerR(wsContainer, 2, 6)
                            bottomLeftRadius: bar.cornerR(wsContainer, 3, 6)

                            Behavior on topLeftRadius { NumberAnimation { duration: 120 } }
                            Behavior on topRightRadius { NumberAnimation { duration: 120 } }
                            Behavior on bottomLeftRadius { NumberAnimation { duration: 120 } }
                            Behavior on bottomRightRadius { NumberAnimation { duration: 120 } }
                            anchors.verticalCenter: parent.verticalCenter

                            Behavior on color { enabled: slideWrapper.colorAnim; ColorAnimation { duration: 300 } }

                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                cursorShape: Qt.PointingHandCursor
                                onClicked: ipcShell.only(wsOverviewComp)
                            }

                            Row {
                                id: wsRow
                                anchors.centerIn: parent
                                spacing: 8

                                Repeater {
                                    model: 5

                                    Rectangle {
                                        required property int index
                                        property int wsId: index + 1
                                        property bool isActive: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id === wsId : false

                                        width: isActive ? 28 : 12
                                        height: 12
                                        radius: 3
                                        color: isActive ? logic.colAccent : logic.colSecondary
                                        opacity: isActive ? 1.0 : 0.6

                                        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutExpo } }
                                        Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
                                        Behavior on opacity { NumberAnimation { duration: 150 } }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: Hyprland.dispatch('hl.dsp.focus({ workspace = "' + parent.wsId + '" })')
                                        }
                                    }
                                }
                            }
                        }
                    }
    }

    Component {
        id: cMpris

                    Rectangle {
                        id: mprisRect
                        readonly property bool shown: opacity > 0
                        height: 30

                        opacity: settingsMenuComp.showMpris ? 1.0 : 0.0
                        property real expandedWidth: Math.ceil(mprisRow.implicitWidth + 16)
                        width: settingsMenuComp.showMpris ? expandedWidth : 0
                        visible: opacity > 0

                        radius: 6
                        color: bar.pillOf(mprisRect)
                        clip: true
                        anchors.verticalCenter: parent.verticalCenter

                        readonly property bool keepOpen: mprisPanelComp.visible

                        topLeftRadius: bar.cornerR(mprisRect, 0, 6)
                        topRightRadius: bar.cornerR(mprisRect, 1, 6)
                        bottomRightRadius: bar.cornerR(mprisRect, 2, 6)
                        bottomLeftRadius: bar.cornerR(mprisRect, 3, 6)

                        Behavior on topLeftRadius { NumberAnimation { duration: 120 } }
                        Behavior on topRightRadius { NumberAnimation { duration: 120 } }
                        Behavior on bottomLeftRadius { NumberAnimation { duration: 120 } }
                        Behavior on bottomRightRadius { NumberAnimation { duration: 120 } }

                        Behavior on color { enabled: slideWrapper.colorAnim; ColorAnimation { duration: 300 } }
                        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutExpo } }
                        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                        property var player: Mpris.players.values.length > 0 ? Mpris.players.values[0] : null
                        property real currentPos: player ? player.position : 0

                        onVisibleChanged: {
                            if (visible && player) currentPos = player.position
                        }

                        Timer {
                            interval: 500
                            running: mprisRect.visible && mprisRect.player !== null && mprisRect.player.playbackState === MprisPlaybackState.Playing
                            repeat: true
                            triggeredOnStart: true
                            onTriggered: {
                                if (mprisRect.player) mprisRect.currentPos = mprisRect.player.position
                            }
                        }

                        function formatTime(val) {
                            if (!val || isNaN(val) || val <= 0) return "00:00"
                            let seconds = val > 10000000 ? Math.floor(val / 1000000) : (val > 10000 ? Math.floor(val / 1000) : Math.floor(val))
                            let mins = Math.floor(seconds / 60)
                            let secs = seconds % 60
                            return (mins < 10 ? "0" : "") + mins + ":" + (secs < 10 ? "0" : "") + secs
                        }

                        Row {
                            id: mprisRow
                            anchors.centerIn: parent
                            spacing: 8

                            Item {
                                id: coverBox
                                width: 24
                                height: 24
                                anchors.verticalCenter: parent.verticalCenter

                                readonly property string artUrl: mprisRect.player && mprisRect.player.trackArtUrl ? mprisRect.player.trackArtUrl : ""

                                Rectangle {
                                    anchors.fill: parent
                                    radius: 6
                                    color: logic.colSecondary
                                    opacity: coverImg.status === Image.Ready ? 0.0 : 1.0

                                    Behavior on opacity { NumberAnimation { duration: 200 } }
                                    Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }

                                    Icon {
                                        anchors.centerIn: parent
                                        name: "player"
                                        size: 14
                                        color: logic.colAccent
                                        dim: 1.3

                                        Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
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
                                    sourceSize.width: 96
                                    sourceSize.height: 96
                                    opacity: status === Image.Ready ? 1.0 : 0.0

                                    Behavior on opacity { NumberAnimation { duration: 200 } }

                                    layer.enabled: true
                                    layer.effect: MultiEffect {
                                        maskEnabled: true
                                        maskSource: coverMask
                                        maskThresholdMin: 0.5
                                        maskSpreadAtMin: 1.0
                                    }
                                }

                                Item {
                                    id: coverMask
                                    anchors.fill: parent
                                    visible: false
                                    layer.enabled: true

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 6
                                    }
                                }
                            }

                            Item {
                                width: visualRoot.compact ? 100 : 160
                                height: parent.height
                                anchors.verticalCenter: parent.verticalCenter
                                clip: true

                                Text {
                                    text: {
                                        let pl = mprisRect.player
                                        if (!pl) return "No media"
                                        let title = pl.trackTitle || ""
                                        let artist = pl.trackArtist || ""
                                        if (title !== "" && artist !== "") return artist + " - " + title
                                        if (title !== "") return title
                                        return "Paused"
                                    }
                                    color: logic.colText
                                    font.pixelSize: 11
                                    font.bold: true
                                    font.family: "JetBrainsMono Nerd Font, Monospace"
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width
                                    elide: Text.ElideRight

                                    Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
                                }
                            }

                            Item {
                                id: timeBox
                                visible: mprisRect.player !== null
                                width: timeW
                                height: timeText.implicitHeight
                                anchors.verticalCenter: parent.verticalCenter

                                property real timeW: 0

                                Text {
                                    id: timeText
                                    x: 0
                                    text: mprisRect.formatTime(mprisRect.currentPos)
                                    color: logic.colText
                                    font.pixelSize: 11
                                    font.bold: true
                                    font.family: "JetBrainsMono Nerd Font, Monospace"
                                    font.kerning: false
                                    font.hintingPreference: Font.PreferNoHinting

                                    onImplicitWidthChanged: {
                                        const w = Math.ceil(implicitWidth)
                                        if (w > timeBox.timeW) timeBox.timeW = w
                                    }
                                    Component.onCompleted: timeBox.timeW = Math.ceil(implicitWidth)

                                    Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
                                }
                            }
                        }

                        MouseArea {
                            id: mprisMa
                            anchors.fill: parent
                            hoverEnabled: true
                            onContainsMouseChanged: bar.mprisHovered = containsMouse
                            cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                            onClicked: (mouse) => {
                                if (mouse.button === Qt.LeftButton) mprisPanelComp.toggleMenu()
                                else if (mprisRect.player && mprisRect.player.canTogglePlaying) mprisRect.player.togglePlaying()
                            }
                            Rectangle {
                                anchors.fill: parent
                                topLeftRadius: bar.hoverR(mprisRect, 0, mprisRect.topLeftRadius)
                                topRightRadius: bar.hoverR(mprisRect, 1, mprisRect.topRightRadius)
                                bottomLeftRadius: bar.hoverR(mprisRect, 3, mprisRect.bottomLeftRadius)
                                bottomRightRadius: bar.hoverR(mprisRect, 2, mprisRect.bottomRightRadius)
                                color: Qt.alpha(logic.colText, mprisMa.containsMouse || (mprisRect.parent.joinedPair && bar.lyricsHovered) || mprisPanelComp.visible ? 0.12 : 0.0)

                                Behavior on color { ColorAnimation { duration: 150 } }
                            }
                        }
                    }
    }

    Component {
        id: cBt

                    Rectangle {
                        id: btRect
                        readonly property bool shown: opacity > 0
                        height: 30

                        opacity: settingsMenuComp.showBluetooth ? 1.0 : 0.0
                        property real expandedWidth: btRowContent.implicitWidth + 16
                        width: settingsMenuComp.showBluetooth ? expandedWidth : 0
                        visible: opacity > 0

                        radius: 6
                        color: bar.pillOf(btRect)
                        topLeftRadius: bar.cornerR(btRect, 0, 6)
                        topRightRadius: bar.cornerR(btRect, 1, 6)
                        bottomRightRadius: bar.cornerR(btRect, 2, 6)
                        bottomLeftRadius: bar.cornerR(btRect, 3, 6)

                        Behavior on topLeftRadius { NumberAnimation { duration: 120 } }
                        Behavior on topRightRadius { NumberAnimation { duration: 120 } }
                        Behavior on bottomLeftRadius { NumberAnimation { duration: 120 } }
                        Behavior on bottomRightRadius { NumberAnimation { duration: 120 } }
                        clip: true
                        anchors.verticalCenter: parent.verticalCenter

                        Behavior on color { enabled: slideWrapper.colorAnim; ColorAnimation { duration: 300 } }
                        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutExpo } }
                        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                        property var connectedDev: {
                            if (Bluetooth.adapters.values.length === 0) return null
                            let devices = Bluetooth.adapters.values[0].devices.values
                            for (let i = 0; i < devices.length; i++) {
                                if (devices[i].connected) return devices[i]
                            }
                            return null
                        }
                        Row {
                            id: btRowContent
                            spacing: 6
                            anchors.centerIn: parent

                            Icon {
                                name: parent.parent.connectedDev ? "bluetoothOn" : "bluetooth"
                                size: 15
                                color: logic.colAccent
                                dim: 1.3
                                anchors.verticalCenter: parent.verticalCenter

                                Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
                            }

                            Text {
                                text: {
                                    let dev = parent.parent.connectedDev
                                    if (!dev) return "Bluetooth"
                                    if (dev.batteryPercentage !== undefined && dev.batteryPercentage >= 0) {
                                        return dev.name + " " + dev.batteryPercentage + "%"
                                    }
                                    return dev.name || "Connected"
                                }
                                color: logic.colText
                                font.pixelSize: 11
                                font.bold: true
                                font.family: "JetBrainsMono Nerd Font, Monospace"
                                anchors.verticalCenter: parent.verticalCenter

                                Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
                            }
                        }
                        MouseArea {
                            id: btMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: btMenuComp.toggleMenu()

                            Rectangle {
                                anchors.fill: parent
                                topLeftRadius: bar.hoverR(btRect, 0, 6)
                                topRightRadius: bar.hoverR(btRect, 1, 6)
                                bottomRightRadius: bar.hoverR(btRect, 2, 6)
                                bottomLeftRadius: bar.hoverR(btRect, 3, 6)
                                color: Qt.alpha(logic.colText, btMa.containsMouse || btMenuComp.visible ? 0.12 : 0.0)


                                Behavior on color { ColorAnimation { duration: 150 } }
                            }
                        }
                    }
    }

    Component {
        id: cApp

                    Item {
                        id: centerContainer
                        readonly property bool shown: opacity > 0
                        height: 30
                        opacity: settingsMenuComp.showCenterApp ? 1.0 : 0.0
                        property real expandedWidth: centerPill.implicitWidth
                        width: settingsMenuComp.showCenterApp ? expandedWidth : 0
                        visible: opacity > 0
                        clip: true

                        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutExpo } }

                        Rectangle {
                            id: centerPill
                            anchors.centerIn: parent
                            height: 30
                            implicitWidth: appRow.implicitWidth + 20
                            radius: 6
                            color: bar.pillOf(centerContainer)
                            topLeftRadius: bar.cornerR(centerContainer, 0, 6)
                            topRightRadius: bar.cornerR(centerContainer, 1, 6)
                            bottomRightRadius: bar.cornerR(centerContainer, 2, 6)
                            bottomLeftRadius: bar.cornerR(centerContainer, 3, 6)


                            Behavior on topLeftRadius { NumberAnimation { duration: 120 } }
                            Behavior on topRightRadius { NumberAnimation { duration: 120 } }
                            Behavior on bottomLeftRadius { NumberAnimation { duration: 120 } }
                            Behavior on bottomRightRadius { NumberAnimation { duration: 120 } }
                            Behavior on color { enabled: slideWrapper.colorAnim; ColorAnimation { duration: 300 } }
                            Row {
                                id: appRow
                                anchors.centerIn: parent
                                spacing: 6

                                Rectangle {
                                    width: 6
                                    height: 6
                                    radius: 2
                                    color: logic.displayText === "~ desktop" ? logic.colSecondary : logic.colAccent
                                    anchors.verticalCenter: parent.verticalCenter

                                    Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
                                }

                                Text {
                                    text: logic.displayText
                                    color: logic.displayText === "~ desktop" ? logic.colSecondary : logic.colText
                                    font.pixelSize: 11
                                    font.bold: true
                                    font.family: "JetBrainsMono Nerd Font, Monospace"
                                    verticalAlignment: Text.AlignVCenter
                                    anchors.verticalCenter: parent.verticalCenter

                                    Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
                                }
                            }
                        }
                    }
    }

    Component {
        id: cSearch


                    Item {
                        id: searchContainer
                        readonly property bool shown: opacity > 0
                        height: 30
                        opacity: settingsMenuComp.showSearch ? 1.0 : 0.0
                        readonly property bool keepOpen: searchWidget.searchOpen
                        property real expandedWidth: searchWidget.searchOpen ? 220 : 30
                        width: settingsMenuComp.showSearch ? expandedWidth : 0
                        visible: opacity > 0
                        clip: true
                        anchors.verticalCenter: parent.verticalCenter

                        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutExpo } }

                        Rectangle {
                            id: searchWidget
                            height: 30
                            radius: 6
                            color: searchWidget.searchOpen && visualRoot.solid ? Qt.alpha(logic.colText, 0.12) : bar.pillOf(searchContainer)
                            topLeftRadius: bar.cornerR(searchContainer, 0, 6)
                            topRightRadius: bar.cornerR(searchContainer, 1, 6)
                            bottomRightRadius: bar.cornerR(searchContainer, 2, 6)
                            bottomLeftRadius: bar.cornerR(searchContainer, 3, 6)

                            Behavior on topLeftRadius { NumberAnimation { duration: 120 } }
                            Behavior on topRightRadius { NumberAnimation { duration: 120 } }
                            Behavior on bottomLeftRadius { NumberAnimation { duration: 120 } }
                            Behavior on bottomRightRadius { NumberAnimation { duration: 120 } }
                            clip: true
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left

                            property bool searchOpen: false
                            width: searchOpen ? 220 : 30

                            Behavior on width {
                                NumberAnimation {
                                    duration: 250;
                                    easing.type: Easing.OutCubic
                                }
                            }
                            Behavior on color { enabled: slideWrapper.colorAnim; ColorAnimation { duration: 300 } }

                            onWidthChanged: {
                                if (searchOpen && width === 220) {
                                    searchInput.forceActiveFocus();
                                }
                            }

                            Row {
                                anchors.fill: parent
                                spacing: 4

                                Item {
                                    width: 30
                                    height: 30

                                    Icon {
                                        anchors.centerIn: parent
                                        name: "search"
                                        size: 15
                                        color: logic.colAccent
                                        dim: 1.3
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            searchWidget.searchOpen = !searchWidget.searchOpen;
                                            if (searchWidget.searchOpen) {
                                                Qt.callLater(() => searchInput.forceActiveFocus());
                                            } else {
                                                searchInput.text = "";
                                            }
                                        }
                                    }
                                }

                                TextInput {
                                    id: searchInput
                                    width: parent.width - 35
                                    height: parent.height
                                    anchors.verticalCenter: parent.verticalCenter
                                    verticalAlignment: TextInput.AlignVCenter

                                    focus: true
                                    color: logic.colText
                                    selectedTextColor: logic.colBg
                                    selectionColor: logic.colAccent
                                    font.pixelSize: 11
                                    font.bold: true
                                    font.family: "JetBrainsMono Nerd Font, Monospace"

                                    Text {
                                        text: "Поиск... (yt: / tt:)"
                                        color: Qt.alpha(logic.colText, 0.55)
                                        font: searchInput.font
                                        visible: !searchInput.text && !searchInput.activeFocus
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Keys.onReturnPressed: {
                                        if (text.trim() !== "") {
                                            logic.searchProc.query = text.trim();
                                            logic.searchProc.running = true;
                                            text = "";
                                            searchWidget.searchOpen = false;
                                        }
                                    }
                                    Keys.onEscapePressed: {
                                        text = "";
                                        searchWidget.searchOpen = false;
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                z: -1
                                onClicked: {
                                    if (searchWidget.searchOpen) {
                                        searchInput.forceActiveFocus();
                                    }
                                }
                            }
                        }
                    }
    }
    Component {
        id: cSys

                    Rectangle {
                        id: rightPill
                        height: 30
                        implicitWidth: rightRow.implicitWidth + 20
                        radius: 6

                        readonly property bool keepOpen: calendarComp.visible || sysMenuComp.visible

                        topLeftRadius: bar.cornerR(rightPill, 0, 6)
                        topRightRadius: bar.cornerR(rightPill, 1, 6)
                        bottomRightRadius: bar.cornerR(rightPill, 2, 6)
                        bottomLeftRadius: bar.cornerR(rightPill, 3, 6)

                        Behavior on topLeftRadius { NumberAnimation { duration: 120 } }
                        Behavior on topRightRadius { NumberAnimation { duration: 120 } }
                        Behavior on bottomLeftRadius { NumberAnimation { duration: 120 } }
                        Behavior on bottomRightRadius { NumberAnimation { duration: 120 } }
                        color: bar.pillOf(rightPill)
                        clip: true
                        anchors.verticalCenter: parent.verticalCenter

                        Behavior on color { enabled: slideWrapper.colorAnim; ColorAnimation { duration: 300 } }
                        Row {
                            id: rightRow
                            anchors.centerIn: parent
                            spacing: 8

                            Row {
                                spacing: 4
                                anchors.verticalCenter: parent.verticalCenter

                                Icon {
                                    name: "lang"
                                    size: 15
                                    color: logic.colAccent
                                    dim: 1.3
                                    anchors.verticalCenter: parent.verticalCenter

                                    Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
                                }

                                Item {
                                    width: 22
                                    height: 16
                                    anchors.verticalCenter: parent.verticalCenter

                                    Text {
                                        text: logic.langVal
                                        color: logic.colText
                                        font.pixelSize: 11
                                        font.bold: true
                                        font.family: "JetBrainsMono Nerd Font, Monospace"
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        horizontalAlignment: Text.AlignHCenter

                                        Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
                                    }
                                }
                            }

                            Row {
                                id: statsContainer
                                spacing: 8

                                opacity: settingsMenuComp.showSystemStats ? 1.0 : 0.0
                                property real expandedWidth: statsInnerRow.implicitWidth
                                width: settingsMenuComp.showSystemStats ? expandedWidth : 0
                                visible: opacity > 0
                                clip: true
                                anchors.verticalCenter: parent.verticalCenter

                                Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutExpo } }

                                Row {
                                    id: statsInnerRow
                                    spacing: 8
                                    anchors.verticalCenter: parent.verticalCenter

                                    Row {
                                        spacing: 3
                                        anchors.verticalCenter: parent.verticalCenter
                                        Icon { name: "sys"; size: 14; color: logic.colAccent; anchors.verticalCenter: parent.verticalCenter; dim: 1.3 }
                                        Item {
                                            width: 34
                                            height: 16
                                            anchors.verticalCenter: parent.verticalCenter
                                            Text { text: logic.cpuVal; color: logic.colText; font.pixelSize: 11; font.bold: true; font.family: "JetBrainsMono Nerd Font, Monospace"; anchors.verticalCenter: parent.verticalCenter }
                                        }
                                    }

                                    Row {
                                        spacing: 3
                                        anchors.verticalCenter: parent.verticalCenter
                                        Icon { name: "ram"; size: 14; color: logic.colAccent; anchors.verticalCenter: parent.verticalCenter; dim: 1.3 }
                                        Item {
                                            width: 34
                                            height: 16
                                            anchors.verticalCenter: parent.verticalCenter
                                            Text { text: logic.ramVal; color: logic.colText; font.pixelSize: 11; font.bold: true; font.family: "JetBrainsMono Nerd Font, Monospace"; anchors.verticalCenter: parent.verticalCenter }
                                        }
                                    }
                                    Row {
                                        spacing: 3
                                        anchors.verticalCenter: parent.verticalCenter
                                        Icon { name: "gpu"; size: 14; color: logic.colAccent; anchors.verticalCenter: parent.verticalCenter; dim: 1.3 }
                                        Item {
                                            width: 34
                                            height: 16
                                            anchors.verticalCenter: parent.verticalCenter
                                            Text { text: logic.gpuVal; color: logic.colText; font.pixelSize: 11; font.bold: true; font.family: "JetBrainsMono Nerd Font, Monospace"; anchors.verticalCenter: parent.verticalCenter }
                                        }
                                    }
                                }
                            }

                            Row {
                                id: clockRow
                                spacing: 4
                                anchors.verticalCenter: parent.verticalCenter

                                Icon {
                                    name: "clock12"
                                    size: 14
                                    color: logic.colAccent
                                    dim: 1.3
                                    anchors.verticalCenter: parent.verticalCenter
                                }


                                Text {
                                    color: logic.colText
                                    font.pixelSize: 11
                                    font.bold: true
                                    font.family: "JetBrainsMono Nerd Font, Monospace"
                                    text: visualRoot.clockText()
                                    anchors.verticalCenter: parent.verticalCenter

                                    Behavior on color { ColorAnimation { duration: 150 } }
                                }
                            }
                        }

                        MouseArea {
                            id: clockMa
                            x: rightRow.x + clockRow.x - 4
                            y: 0
                            width: clockRow.width + 8
                            height: rightPill.height
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: calendarComp.toggleMenu()

                            Rectangle {
                                anchors.fill: parent
                                radius: 6
                                color: Qt.alpha(logic.colText, clockMa.containsMouse || calendarComp.visible ? 0.12 : 0.0)


                                Behavior on color { ColorAnimation { duration: 150 } }
                            }
                        }

                        MouseArea {
                            id: statsMa
                            x: rightRow.x + statsContainer.x - 4
                            y: 0
                            width: statsContainer.width + 8
                            height: rightPill.height
                            enabled: statsContainer.visible && statsContainer.width > 20
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: sysMenuComp.toggleMenu()

                            Rectangle {
                                anchors.fill: parent
                                radius: 6
                                color: Qt.alpha(logic.colText, statsMa.containsMouse || sysMenuComp.visible ? 0.12 : 0.0)

                                Behavior on color { ColorAnimation { duration: 150 } }
                            }
                        }
                    }
    }

    Component {
        id: cNotif

                    NotifButton {
                        id: notifBtnRoot
                        colBg: logic.colBg
                        glass: bar.pillOf(notifBtnRoot)
                        animateColor: slideWrapper.colorAnim
                        colAccent: logic.colAccent
                        colText: logic.colText
                        colSecondary: logic.colSecondary
                        count: visualRoot.notify.unreadCount
                        dnd: settingsMenuComp.doNotDisturb
                        anchors.verticalCenter: parent.verticalCenter

                        // пока центр управления открыт, бар с автоскрытием не прячет кнопку
                        readonly property bool keepOpen: notifCenterComp.visible

                        onClicked: {
                            notifCenterComp.toggleMenu()
                        }
                    }
    }

    Component {
        id: cVol

                    Rectangle {
                        id: volRect
                        readonly property bool shown: opacity > 0
                        height: 30

                        opacity: settingsMenuComp.showVolume ? 1.0 : 0.0
                        property real expandedWidth: volRow.implicitWidth + 20
                        width: settingsMenuComp.showVolume ? expandedWidth : 0
                        visible: opacity > 0

                        radius: 6
                        color: bar.pillOf(volRect)
                        clip: true
                        anchors.verticalCenter: parent.verticalCenter

                        readonly property bool keepOpen: volMenuComp.visible

                        topLeftRadius: bar.cornerR(volRect, 0, 6)
                        topRightRadius: bar.cornerR(volRect, 1, 6)
                        bottomRightRadius: bar.cornerR(volRect, 2, 6)
                        bottomLeftRadius: bar.cornerR(volRect, 3, 6)

                        Behavior on topLeftRadius { NumberAnimation { duration: 120 } }
                        Behavior on topRightRadius { NumberAnimation { duration: 120 } }
                        Behavior on bottomLeftRadius { NumberAnimation { duration: 120 } }
                        Behavior on bottomRightRadius { NumberAnimation { duration: 120 } }

                        Behavior on color { enabled: slideWrapper.colorAnim; ColorAnimation { duration: 300 } }
                        Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutExpo } }
                        Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                        Row {
                            id: volRow
                            anchors.centerIn: parent
                            spacing: 6

                            Icon {
                                name: visualRoot.volIcon()
                                size: 15
                                color: logic.colAccent
                                dim: 1.3
                                anchors.verticalCenter: parent.verticalCenter

                                Behavior on color { ColorAnimation { duration: 150 } }
                            }

                            Item {
                                width: 30
                                height: 16
                                anchors.verticalCenter: parent.verticalCenter

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.right: parent.right
                                    text: visualRoot.volMuted ? "mute" : visualRoot.volPercent + "%"
                                    color: logic.colText
                                    opacity: visualRoot.volMuted ? 0.5 : 1.0
                                    font.pixelSize: 11
                                    font.bold: true
                                    font.family: "JetBrainsMono Nerd Font, Monospace"
                                }
                            }
                        }

                        MouseArea {
                            id: volMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                            onClicked: (mouse) => {
                                if (mouse.button === Qt.LeftButton) volMenuComp.toggleMenu()
                                else visualRoot.toggleVolMute()
                            }
                            onWheel: (wheel) => visualRoot.stepVolume(wheel.angleDelta.y > 0 ? 5 : -5)

                            Rectangle {
                                anchors.fill: parent
                                topLeftRadius: bar.hoverR(volRect, 0, volRect.topLeftRadius)
                                topRightRadius: bar.hoverR(volRect, 1, volRect.topRightRadius)
                                bottomLeftRadius: bar.hoverR(volRect, 3, volRect.bottomLeftRadius)
                                bottomRightRadius: bar.hoverR(volRect, 2, volRect.bottomRightRadius)
                                color: Qt.alpha(logic.colText, volMa.containsMouse || volMenuComp.visible ? 0.12 : 0.0)

                                Behavior on color { ColorAnimation { duration: 150 } }
                            }
                        }
                    }
    }

    Component {
        id: cBattery

        Rectangle {
            id: batRect
            height: 30

            readonly property bool fake: false
            property real fakePct: 100
            property bool fakeCharging: false
            Timer {
                running: batRect.fake
                interval: 500
                repeat: true
                onTriggered: {
                    if (batRect.fakePct <= 0) { batRect.fakePct = 100; batRect.fakeCharging = !batRect.fakeCharging }
                    else batRect.fakePct -= 5
                }
            }

            readonly property var dev: UPower.displayDevice
            readonly property bool present: fake || (dev !== null && dev.ready && dev.isPresent)
            readonly property bool want: settingsMenuComp.showBattery && present
            readonly property bool shown: opacity > 0

            readonly property real pct: {
                if (fake) return fakePct
                if (!dev) return 0
                const v = dev.percentage
                return Math.max(0, Math.min(100, Math.round(v > 1 ? v : v * 100)))
            }
            readonly property bool charging: fake ? fakeCharging
                : (dev !== null && (dev.state === UPowerDeviceState.Charging
                                    || dev.state === UPowerDeviceState.PendingCharge))
            readonly property bool full: !fake && dev !== null && dev.state === UPowerDeviceState.FullyCharged
            readonly property bool low: !charging && !full && pct <= 20
            readonly property bool critical: !charging && !full && pct <= 10
            readonly property color tone: critical ? "#f38ba8" : (low ? "#f9e2af" : logic.colAccent)

            property bool showTime: false
            readonly property real secs: fake ? 5400 : (dev ? (charging ? dev.timeToFull : dev.timeToEmpty) : 0)
            readonly property string timeText: {
                if (secs <= 0) return pct + "%"
                const m = Math.round(secs / 60)
                return Math.floor(m / 60) + ":" + (m % 60 < 10 ? "0" : "") + (m % 60)
            }

            opacity: want ? 1.0 : 0.0
            property real expandedWidth: batRow.implicitWidth + 20
            width: want ? expandedWidth : 0
            visible: opacity > 0

            radius: 6
            color: bar.pillOf(batRect)
            clip: true
            anchors.verticalCenter: parent.verticalCenter

            topLeftRadius: bar.cornerR(batRect, 0, 6)
            topRightRadius: bar.cornerR(batRect, 1, 6)
            bottomRightRadius: bar.cornerR(batRect, 2, 6)
            bottomLeftRadius: bar.cornerR(batRect, 3, 6)

            Behavior on topLeftRadius { NumberAnimation { duration: 120 } }
            Behavior on topRightRadius { NumberAnimation { duration: 120 } }
            Behavior on bottomLeftRadius { NumberAnimation { duration: 120 } }
            Behavior on bottomRightRadius { NumberAnimation { duration: 120 } }

            Behavior on color { enabled: slideWrapper.colorAnim; ColorAnimation { duration: 300 } }
            Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutExpo } }
            Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            Row {
                id: batRow
                anchors.centerIn: parent
                spacing: 6

                Item {
                    id: batIcon
                    width: 20
                    height: 20
                    anchors.verticalCenter: parent.verticalCenter

                    readonly property real k: width / 24


                    Icon {
                        anchors.fill: parent
                        name: "battery-frame"
                        size: batIcon.width
                        color: Qt.alpha(batRect.tone, 0.75)

                        Behavior on color { ColorAnimation { duration: 400 } }
                    }

                    Rectangle {
                        id: batFill
                        x: 4 * batIcon.k
                        y: 9 * batIcon.k
                        height: 6 * batIcon.k
                        width: Math.max(batRect.pct > 0 ? 2 : 0, 13 * batIcon.k * batRect.pct / 100)
                        radius: 1.2 * batIcon.k
                        color: batRect.tone

                        Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                        Behavior on color { ColorAnimation { duration: 400 } }

                        SequentialAnimation on opacity {
                            running: batRect.charging && batRect.shown
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0; duration: 900; easing.type: Easing.InOutSine }
                            onRunningChanged: if (!running) batFill.opacity = 1.0
                        }
                    }
                }

                Item {
                    width: 32
                    height: 16
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.right: parent.right
                        text: batRect.showTime ? batRect.timeText : batRect.pct + "%"
                        color: batRect.critical ? batRect.tone : logic.colText
                        font.pixelSize: 11
                        font.bold: true
                        font.family: "JetBrainsMono Nerd Font, Monospace"

                        Behavior on color { ColorAnimation { duration: 400 } }
                    }
                }
            }

            MouseArea {
                id: batMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: batRect.showTime = !batRect.showTime

                Rectangle {
                    anchors.fill: parent
                    topLeftRadius: bar.hoverR(batRect, 0, batRect.topLeftRadius)
                    topRightRadius: bar.hoverR(batRect, 1, batRect.topRightRadius)
                    bottomLeftRadius: bar.hoverR(batRect, 3, batRect.bottomLeftRadius)
                    bottomRightRadius: bar.hoverR(batRect, 2, batRect.bottomRightRadius)
                    color: Qt.alpha(logic.colText, batMa.containsMouse ? 0.12 : 0.0)

                    Behavior on color { ColorAnimation { duration: 150 } }
                }
            }
        }
    }

    Component {
        id: cClip

        BarChip {
            id: clipChip
            glass: bar.pillOf(clipChip)
            animateColor: slideWrapper.colorAnim
            svg: "clipboard"
            label: clipStore.count > 0 ? String(clipStore.count) : ""
            shown: settingsMenuComp.showClipboard
            colSecondary: logic.colSecondary
            colAccent: logic.colAccent
            colText: logic.colText
            anchors.verticalCenter: parent.verticalCenter

            onClicked: clipPanelComp.toggleMenu()
        }
    }

    Component {
        id: cTray

        BarChip {
            id: trayChip
            glass: bar.pillOf(trayChip)
            animateColor: slideWrapper.colorAnim
            svg: "tray"
            label: trayPanelComp.trayCount > 0 ? String(trayPanelComp.trayCount) : ""
            shown: settingsMenuComp.showTray
            colSecondary: logic.colSecondary
            colAccent: logic.colAccent
            colText: logic.colText
            anchors.verticalCenter: parent.verticalCenter

            onClicked: trayPanelComp.toggleMenu()
        }
    }

    Component {
        id: cLyrics

        Rectangle {
            id: lyricsRect

            readonly property bool want: barLayout.showLyrics
                && (lyricsComp.status === "found" || lyricsComp.status === "recognizing" || lyricsComp.status === "confirm" || lyricsComp.notFoundFlash
                    || lyricsComp.pinned   // автоскрытие выключено — плашка не пропадает
                    || lyricsPanelComp.visible)   // пока панель открыта плашку не схлопываем, иначе панель теряет привязку и закрывается
            readonly property bool shown: opacity > 0
            height: 30

            opacity: want ? 1.0 : 0.0
            property real expandedWidth: Math.ceil(lyricsRow.implicitWidth + 20)
            width: want ? expandedWidth : 0
            visible: opacity > 0

            radius: 6
            color: bar.pillOf(lyricsRect)
            clip: true
            anchors.verticalCenter: parent.verticalCenter

            readonly property bool keepOpen: lyricsPanelComp.visible

            topLeftRadius: bar.cornerR(lyricsRect, 0, 6)
            topRightRadius: bar.cornerR(lyricsRect, 1, 6)
            bottomRightRadius: bar.cornerR(lyricsRect, 2, 6)
            bottomLeftRadius: bar.cornerR(lyricsRect, 3, 6)


            Behavior on topLeftRadius { NumberAnimation { duration: 120 } }
            Behavior on topRightRadius { NumberAnimation { duration: 120 } }
            Behavior on bottomLeftRadius { NumberAnimation { duration: 120 } }
            Behavior on bottomRightRadius { NumberAnimation { duration: 120 } }

            Behavior on color { enabled: slideWrapper.colorAnim; ColorAnimation { duration: 300 } }
            Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

            readonly property string liveCaption: lyricsComp.status === "recognizing" ? Tr.tr("lyrics.bar.listening")
                : lyricsComp.status === "confirm" ? ("«" + (lyricsComp.suggestion ? lyricsComp.suggestion.title : "") + "»?")
                : lyricsComp.status === "notfound" ? Tr.tr("lyrics.bar.notfound")
                : lyricsComp.status === "searching" ? "\u2026"
                : (lyricsComp.currentLine !== "" ? lyricsComp.currentLine : "\u00a0")

            function snapCaption() {
                capAnim.stop()
                capLine.opacity = 1
                capLine.y = 0
                capBox.shownText = liveCaption
            }

            onLiveCaptionChanged: {
                if (!want) return
                if (opacity > 0.99) capAnim.restart()
                else snapCaption()
            }
            onWantChanged: if (want) snapCaption()

            Row {
                id: lyricsRow
                anchors.centerIn: parent
                spacing: 6

                Icon {
                    name: "lyrics"
                    size: 17
                    color: logic.colAccent
                    dim: 1.3
                    anchors.verticalCenter: parent.verticalCenter

                    Behavior on color { ColorAnimation { duration: 800; easing.type: Easing.InOutCubic } }
                }

                Item {
                    id: capBox
                    width: visualRoot.compact ? 90 : 220
                    height: capLine.implicitHeight
                    clip: true
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: -capLine.reserve / 2 + 1.5

                    property string shownText: lyricsRect.liveCaption

                    KaraokeLine {
                        id: capLine
                        width: parent.width
                        text: capBox.shownText
                        words: lyricsRect.want ? lyricsComp.curWords : []
                        wordIndex: lyricsComp.wordIndex
                        wrap: false
                        jumpEnabled: lyricsComp.wordJump
                        color: logic.colText
                        dotColor: lyricsComp.wordHighlight ? logic.colAccent : "transparent"
                        pixelSize: 11
                        bold: true

                        Icon {
                            visible: capBox.shownText === "\u00a0"
                            name: "player"
                            size: 15
                            color: "white"
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                        }
                    }

                    SequentialAnimation {
                        id: capAnim

                        ParallelAnimation {
                            NumberAnimation { target: capLine; property: "opacity"; to: 0; duration: 110; easing.type: Easing.InQuad }
                            NumberAnimation { target: capLine; property: "y"; to: -capBox.height * 0.5; duration: 110; easing.type: Easing.InQuad }
                        }

                        ScriptAction {
                            script: {
                                capBox.shownText = lyricsRect.liveCaption
                                capLine.y = capBox.height * 0.6
                            }
                        }

                        ParallelAnimation {
                            NumberAnimation { target: capLine; property: "opacity"; to: 1; duration: 320; easing.type: Easing.OutCubic }
                            NumberAnimation { target: capLine; property: "y"; to: 0; duration: 320; easing.type: Easing.OutCubic }
                        }
                    }
                }
            }

            MouseArea {
                id: lyricsMa
                anchors.fill: parent
                hoverEnabled: true
                onContainsMouseChanged: bar.lyricsHovered = containsMouse
                cursorShape: Qt.PointingHandCursor
                onClicked: lyricsPanelComp.toggleMenu()

                Rectangle {
                    anchors.fill: parent
                    topLeftRadius: bar.hoverR(lyricsRect, 0, lyricsRect.topLeftRadius)
                    topRightRadius: bar.hoverR(lyricsRect, 1, lyricsRect.topRightRadius)
                    bottomLeftRadius: bar.hoverR(lyricsRect, 3, lyricsRect.bottomLeftRadius)
                    bottomRightRadius: bar.hoverR(lyricsRect, 2, lyricsRect.bottomRightRadius)
                    color: Qt.alpha(logic.colText, lyricsMa.containsMouse || (lyricsRect.parent.joinedPair && bar.mprisHovered) || lyricsPanelComp.visible ? 0.12 : 0.0)

                    Behavior on color { ColorAnimation { duration: 150 } }
                }
            }
        }
    }
}
