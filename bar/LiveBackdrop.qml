// LiveBackdrop.qml
//
// Зачем это: "живой" фон для стеклянного (blur) бара и панелей. Бар размывает то,
// что под ним, поэтому нужна картинка того, что реально на экране: обои и окна.
// Тут обои рисуются двумя слоями с плавной сменой, окна захватываются через
// ScreencopyView по данным hyprctl и двигаются так же, как анимация переключения
// воркспейсов в Hyprland (кривую и время вытаскиваем из конфига), а всё вместе
// собирается в одну текстуру tex, которую потом берёт BarBlur.
//
// Обои определяются сами (hyprpaper / swww / awww) или приходят по IPC:
//   qs ipc call backdrop setWallpaper /путь/к/обоям
// Включить отладку: debug: true (пишет в лог что видит и почему не рисует).

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "../panels"
import "../notifications"
import "../settings"
import "../common"

Item {
    id: root

    // монитор, для которого строим фон (размер берём с него)
    property var screenObj: null
    property string wallpaper: ""
    property bool active: true;  property bool autoDetect: true
    // roi - область, которую реально размываем (под баром), остальное захватывать незачем
    property rect roi: Qt.rect(0, 0, width, height)
    property int pollInterval: 1000
    property bool trackFast: false
    property int fastPollMs: 60
    property int pad: 32;  property int wallFadeMs: 220
    property int detectMs: 300
    // есть ли на экране плавающие окна (тогда опрашиваем чаще)
    property bool hasFloat: false
    property real prewarm: 0
    property color baseColor: "transparent"

    property color windowBase: "transparent"
    property bool debug: false

    // если область почти на весь экран - окна не рисуем, хватит обоев
    property bool hideWindowsFullscreen: true
    property real fullscreenRatio: 0.6
    readonly property bool fullscreenRoi: width > 0 && height > 0
                                          && (roi.width * roi.height) >= width * height * fullscreenRatio
    readonly property bool showWindows: !(hideWindowsFullscreen && fullscreenRoi)
    // окна то включаются, то выключаются - в первом случае пересобираем, во втором чистим
    onShowWindowsChanged: {
        if (showWindows) { resnap(); kick(); refresh() }
        else clearWindows()
    }
    // выкидывает все захваченные окна и останавливает анимации
    function clearWindows() {
        winModel.clear()
        aliveCount = 0
        hasFloat = false
        sliding = false
        slideStop.stop()
        tex.scheduleUpdate()
    }

    // режим захвата: live (кадры идут постоянно) или по запросу с заморозкой
    property bool liveCapture: true
    property bool parkOthers: true
    property real texScale: 1.0
    property int wsDelay: 0
    property int settleMs: 900
    property bool settling: false
    // сигнал "обнови снимки окон"
    signal resnap()
    // в режиме без live даёт время на "успокоение", потом текстура обновляется
    function kick() { if (liveCapture) return; settling = true; settleTimer.restart() }
    // таймер для settling
    Timer { id: settleTimer; interval: root.settleMs; onTriggered: { root.settling = false; tex.scheduleUpdate() } }

    // анимация переключения воркспейсов: время, кривая, сдвиг, затухание.
    // Для special-воркспейса те же параметры с префиксом sp
    property bool slideWorkspaces: true

    property bool autoAnim: true;  property bool slideVertical: false
    property int slideMs: 450
    property var slideCurve: [0.23, 1, 0.32, 1]
    property real slideFrac: 1
    property bool slideFade: false

    property bool spEnabled: true
    property int spMs: 450
    property var spCurve: [0.23, 1, 0.32, 1]
    property real spFrac: 1
    property bool spFade: false
    property int curWs: -1;  property int curSp: -1000000
    property int slideDir: 1
    property bool pending: false

    // сколько держим уехавшие окна, пока анимация не закончится
    readonly property int pruneMs: (slideWorkspaces || spEnabled) ? Math.max(slideMs, spMs)+200 : 300

    // now гоняется FrameAnimation-ом только пока идёт слайд, от него считается прогресс
    property double now: Date.now()
    property double wsEventAt: 0
    property bool sliding: false
    property int aliveCount: 0

    // кривая безье из конфига Hyprland: по прогрессу p находим t бисекцией, потом считаем y
    function ease(p, sp) {
        if (p <= 0) return 0
        if (p >= 1) return 1
        const c = sp ? spCurve : slideCurve
        let lo = 0, hi = 1, t = p
        for (let i = 0; i < 16; i++) {
            const u = 1 - t
            const x = 3 * u * u * t * c[0] + 3 * u * t * t * c[2] + t * t * t
            if (x < p) lo = t; else hi = t
            t = (lo + hi) / 2
        }
        const u = 1 - t
        return 3 * u * u * t * c[1] + 3 * u * t * t * c[3] + t * t * t
    }

    // на сколько пикселей окно сдвинуто в начале/конце слайда
    function slideOff(sign, frac, dim) { return sign * Math.max(frac * dim, 0.01) }
    // время старта анимации: если только что было событие воркспейса - берём его время, чтоб не было рассинхрона
    function stamp() {
        const t = Date.now()
        return (t - wsEventAt < 600) ? wsEventAt : t
    }
    // запуск слайда: включаем покадровое обновление и таймер остановки
    function startSlide() {
        now = Date.now()
        sliding = true
        slideStop.restart()
    }

    // пока слайд идёт - обновляем now каждый кадр
    FrameAnimation {
        running: root.sliding
        onTriggered: root.now = Date.now()
    }
    // когда анимация точно кончилась - выключаем покадровое обновление
    Timer {
        id: slideStop
        interval: Math.max(root.slideMs, root.spMs)+150
        onTriggered: { root.now = Date.now(); root.sliding = false }
    }

    readonly property Item texture: tex

    // какой кусок сцены снимаем в текстуру: roi + запас pad со всех сторон, не выходя за экран
    readonly property rect capRect: {
        const x0 = Math.max(0, Math.floor(roi.x - pad))
        const y0 = Math.max(0, Math.floor(roi.y - pad))
        const x1 = Math.min(width, Math.ceil(roi.x+roi.width+pad))
        const y1 = Math.min(height, Math.ceil(roi.y + roi.height + pad))
        return Qt.rect(x0, y0, Math.max(1, x1 - x0), Math.max(1, y1 - y0))
    }
    property string detected: ""
    readonly property string wallpaperPath: wallpaper !== "" ? wallpaper : detected

    // модель захваченных окон (адрес, позиция, размер, состояния анимации)
    ListModel {
        id: winModel
        dynamicRoles: true
    }

    width: screenObj ? screenObj.width : 0
    height: screenObj ? screenObj.height : 0

    // сцена: цвет подложки, два слоя обоев и окна поверх
    Item {
        id: scene
        width: root.width
        height: root.height

        Rectangle {
            z: -3
            anchors.fill: parent
            color: root.baseColor
        }

        // два слоя обоев: один показываем, во второй грузим новые, потом плавно меняем
        Image {
            id: wallA
            anchors.fill: parent
            sourceSize: Qt.size(Math.max(1, Math.round(root.width * root.texScale)), Math.max(1, Math.round(root.height * root.texScale)))
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            smooth: true
            z: root.frontIsA ? -1 : -2
            opacity: root.frontIsA ? root.wallFade : 1
            onStatusChanged: root.wallStatus(wallA)
        }
        Image {
            id: wallB
            anchors.fill: parent
            sourceSize: Qt.size(Math.max(1, Math.round(root.width * root.texScale)), Math.max(1, Math.round(root.height * root.texScale)))
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            smooth: true
            z: root.frontIsA ? -2 : -1
            opacity: root.frontIsA ? 1 : root.wallFade
            onStatusChanged: root.wallStatus(wallB)
        }

        Repeater {
            model: winModel

            // одно окно: захват через ScreencopyView, а положение = позиция + текущий сдвиг слайда.
            // retarget() пересчитывает откуда и куда ехать, когда окно появилось или исчезло с экрана
            delegate: ScreencopyView {
                id: view
                required property string addr
                required property real wx
                required property real wy
                required property real ww
                required property real wh
                required property real wz
                required property var wtop
                required property bool walive
                required property real wenter
                required property real wleave
                required property real wstart
                required property bool wvert

                property real offFrom: wenter
                property real offTo: 0
                property double t0: wstart
                required property bool wspecial
                readonly property real prog: Math.min(1, Math.max(0, (root.now - t0) / (wspecial ? root.spMs : root.slideMs)))
                readonly property real eased: root.ease(prog, wspecial)
                readonly property real off: offFrom + (offTo - offFrom) * eased

                readonly property bool fadeOn: wspecial ? root.spFade : root.slideFade
                property real alphaFrom: (fadeOn && wenter !== 0) ? 0 : 1
                property real alphaTo: 1
                readonly property real alpha: alphaFrom + (alphaTo - alphaFrom) * eased

                property real px: wx
                property real py: wy

                property bool atRest: !walive
                property bool warm: root.parkOthers
                property bool frozen: false
                Timer { id: freezeT; interval: 250; onTriggered: view.frozen = true }
                Connections { target: root; function onResnap() { view.frozen = false; if (!root.liveCapture) freezeT.restart() } }
                Timer { running: true; interval: 1500; onTriggered: view.warm = false }

                captureSource: wtop
                live: root.active && (root.liveCapture ? (walive || prog < 1 || warm) : (!frozen && (walive || prog < 1 || warm)))

                Rectangle {
                    z: -1
                    anchors.fill: parent
                    color: root.windowBase
                    visible: root.windowBase.a > 0
                }

                onHasContentChanged: {
                    if (hasContent) { root.kick(); if (!root.liveCapture) freezeT.restart() }
                    if (root.debug) console.warn("[LB dbg] окно", addr, "hasContent:", hasContent, ww + "x" + wh)
                }
                x: px + (wvert ? 0 : off)
                y: py + (wvert ? off : 0)
                width: ww
                height: wh
                z: wz

                opacity: (hasContent && (walive || (wleave !== 0 && prog < 1))) ? alpha : 0

                function retarget() {
                    if (walive && atRest) {
                        atRest = false
                        root.startSlide()
                        offFrom = wenter
                        offTo = 0
                        alphaFrom = (fadeOn && wenter !== 0) ? 0 : 1
                        alphaTo = 1
                        t0 = wstart > 0 ? wstart : root.stamp()
                        return
                    }
                    const to = walive ? 0 : wleave
                    if (!walive && to === 0) { atRest = true; return }
                    if (to === offTo) return
                    if (!walive) atRest = false
                    const cur = off
                    const curA = alpha
                    root.startSlide()
                    offFrom = cur
                    offTo = to
                    alphaFrom = curA
                    alphaTo = (walive || !fadeOn || wleave === 0) ? 1 : 0
                    t0 = root.stamp()
                }
                onWaliveChanged: retarget()
                onWleaveChanged: retarget()

                Behavior on px { NumberAnimation { duration: root.trackFast ? 60 : 160; easing.type: Easing.Linear } }
                Behavior on py { NumberAnimation { duration: root.trackFast ? 60 : 160; easing.type: Easing.Linear } }
                Behavior on width { NumberAnimation { duration: root.trackFast ? 60 : 160; easing.type: Easing.Linear } }
                Behavior on height { NumberAnimation { duration: root.trackFast ? 60 : 160; easing.type: Easing.Linear } }

                Behavior on opacity { NumberAnimation { duration: (view.wenter !== 0 || view.wleave !== 0) ? 0 : (root.trackFast ? 110 : 160); easing.type: Easing.OutCubic } }
            }
        }
    }

    // итоговая текстура сцены (обновляется только когда что-то меняется, чтоб не жрать GPU)
    ShaderEffectSource {
        id: tex
        sourceItem: scene
        sourceRect: root.capRect
        hideSource: false
        live: root.active && (root.liveCapture ? (root.aliveCount > 0 || root.sliding || wallFadeAnim.running)
                                               : (root.settling || root.sliding || wallFadeAnim.running))
        mipmap: true
        smooth: true
        width: root.capRect.width
        height: root.capRect.height
        textureSize: Qt.size(Math.max(1, Math.round(root.capRect.width * root.texScale)), Math.max(1, Math.round(root.capRect.height * root.texScale)))
        x: 0
        y: 0
    }

    // какой из слоёв обоев сейчас передний и как идёт плавная смена
    property bool frontIsA: true
    property real wallFade: 1
    property bool awaiting: false
    property string pendingSrc: ""
    readonly property Image frontImg: frontIsA ? wallA : wallB
    readonly property Image backImg: frontIsA ? wallB : wallA

    // плавный переход от старых обоев к новым
    NumberAnimation {
        id: wallFadeAnim
        target: root
        property: "wallFade"
        from: 0
        to: 1
        duration: root.wallFadeMs
        easing.type: Easing.OutQuad
        onFinished: {
            root.backImg.source = ""
            tex.scheduleUpdate()
        }
    }

    // путь -> file:// url (кодируем каждый кусок, чтобы пробелы и кириллица не ломали)
    function fileUrl(p) {
        if (/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(p)) return p
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }

    // грузит обои в задний слой; если путь и reloadTick те же - ничего не делает
    function applyWall() {
        const src = (active && wallpaperPath !== "") ? fileUrl(wallpaperPath) : ""

        const key = src === "" ? "" : src + "\n" + reloadTick
        if (key === pendingSrc) return
        pendingSrc = key
        if (src === "") {
            awaiting = false
            wallFadeAnim.stop()
            wallA.source = ""
            wallB.source = ""
            return
        }
        awaiting = true
        backImg.source = src
        if (awaiting && backImg.status === Image.Ready) promoteWall()
    }

    // обои загрузились - переключаем слои; не открылись - пишем в лог
    function wallStatus(img) {
        if (img.status === Image.Error) {
            console.log("[LiveBackdrop] не открылись обои:", img.source)
            if (img === backImg) awaiting = false
        } else if (img.status === Image.Ready) {
            if (awaiting && img === backImg) promoteWall()
            else tex.scheduleUpdate()
        }
    }

    // новые обои готовы: делаем их передними и запускаем плавную смену
    function promoteWall() {
        awaiting = false
        wallFadeAnim.stop()
        const first = frontImg.status !== Image.Ready
        frontIsA = !frontIsA
        wallFade = first ? 1 : 0
        if (!first) wallFadeAnim.start()
        else backImg.source = ""
        tex.scheduleUpdate()
    }

    onWallpaperPathChanged: applyWall()
    onActiveChanged: { applyWall(); if (active && showWindows) { resnap(); kick(); refresh() } }

    onRoiChanged: debounce.restart()
    onScreenObjChanged: refresh()

    // читаем конфиг hyprland, чтобы вытащить из него параметры анимаций
    Process {
        id: animProc
        command: ["sh", "-c", 'cat "${QS_HYPR_CONF:-$HOME/.config/hypr/hyprland.lua}" 2>/dev/null']
        stdout: StdioCollector {
            onStreamFinished: root.parseAnim(text)
        }
    }

    // перечитать конфиг (если включён autoAnim)
    function loadAnim() { if (autoAnim && !animProc.running) animProc.running = true }

    // разбирает стиль анимации из конфига ("slide", "slidevert 50%", "fade" ...) в сдвиг, затухание и вертикальность
    function parseStyle(st) {
        const t = (st || "").trim().split(/\s+/)
        const name = (t[0] || "slide").toLowerCase()
        if (name.indexOf("slide") !== 0 && name !== "fade") return { frac: 1, fade: false, vert: false }
        const pct = t[1] ? parseFloat(t[1]) : 100
        return {
            frac: name === "fade" ? 0 : (name.indexOf("fade") >= 0 && !isNaN(pct) ? pct / 100 : 1),
            fade: name.indexOf("fade") >= 0,
            vert: /vert$/.test(name)
        }
    }

    // вытаскивает из конфига кривые (hl.curve) и анимации (hl.animation) для workspaces и special-воркспейсов
    function parseAnim(src) {
        if (!autoAnim || !src) return
        src = src.replace(/--[^\n]*/g, "")
        const curves = ({ linear: [0, 0, 1, 1] })
        let m
        const cre = /hl\.curve\s*\(\s*["']([^"']+)["']\s*,\s*\{([\s\S]*?)\}\s*\)/g
        while ((m = cre.exec(src)) !== null) {
            const pi = m[2].indexOf("points")
            if (pi < 0) continue
            const nums = m[2].substring(pi).match(/-?\d*\.?\d+/g)
            if (nums && nums.length >= 4) curves[m[1]] = nums.slice(0, 4).map(Number)
        }
        const anims = ({})
        const are = /hl\.animation\s*\(\s*\{([^}]*)\}/g
        while ((m = are.exec(src)) !== null) {
            const b = m[1]
            const g = re => { const r = b.match(re); return r ? r[1] : undefined }
            const leaf = g(/leaf\s*=\s*["']([^"']+)["']/)
            const speed = parseFloat(g(/speed\s*=\s*([\d.]+)/))
            if (!leaf || isNaN(speed)) continue
            anims[leaf] = { on: g(/enabled\s*=\s*(true|false)/) !== "false", ms: speed * 100,
                            curve: curves[g(/bezier\s*=\s*["']([^"']+)["']/)],
                            style: parseStyle(g(/style\s*=\s*["']([^"']+)["']/)) }
        }
        const w = anims["workspaces"] || anims["workspacesIn"]
        if (!w) return
        slideWorkspaces = w.on
        slideMs = Math.max(1, w.ms)
        if (w.curve) slideCurve = w.curve
        slideFrac = w.style.frac
        slideFade = w.style.fade
        slideVertical = w.style.vert

        const sp = anims["specialWorkspace"] || anims["specialWorkspaceIn"] || w
        spEnabled = sp.on
        spMs = Math.max(1, sp.ms)
        if (sp.curve) spCurve = sp.curve
        spFrac = sp.style.frac
        spFade = sp.style.fade
        if (debug) console.warn("[LB dbg] анимации из конфига: workspaces", slideMs, "мс, кривая", JSON.stringify(slideCurve),
                               "сдвиг", slideFrac, "fade", slideFade, "vert", slideVertical)
    }

    // спрашиваем у hyprctl мониторы и окна одним вызовом
    Process {
        id: dataProc
        command: ["sh", "-c", "hyprctl -j monitors; echo '@@SPLIT@@'; hyprctl -j clients"]
        stdout: StdioCollector {
            onStreamFinished: root.parse(text)
        }
    }

    // запросить свежие данные; если предыдущий запрос ещё идёт - запомнить и повторить после него
    function refresh() {
        if (debug && (!active || !screenObj)) console.warn("[LB dbg] refresh пропущен: active =", active, "screenObj =", screenObj ? screenObj.name : "нет")
        if (!active || !screenObj || !showWindows) return
        if (dataProc.running) { pending = true; return }
        dataProc.running = true
    }

    // когда запрос закончился и был отложенный - повторяем
    Connections {
        target: dataProc
        function onRunningChanged() {
            if (!dataProc.running && root.pending) {
                root.pending = false
                root.refresh()
            }
        }
    }

    // главная функция: по ответу hyprctl определяет что на экране, считает смену воркспейса и обновляет winModel.
    // Окна, которых нет в области, остаются "припаркованными", чтобы анимация не дёргалась
    function parse(text) {
        if (!screenObj || !showWindows) return
        const parts = text.split("@@SPLIT@@")
        if (parts.length < 2) {
            if (debug) console.warn("[LB dbg] parse: пустой ответ hyprctl, длина:", text.length)
            return
        }
        let mons, cls
        try {
            mons = JSON.parse(parts[0])
            cls = JSON.parse(parts[1])
        } catch (e) {
            if (debug) console.warn("[LB dbg] parse: не разобрался JSON hyprctl:", e)
            return
        }
        let mon = null
        for (let i = 0; i < mons.length; i++)
            if (mons[i].name === screenObj.name) mon = mons[i]
        if (!mon || !mon.activeWorkspace) {
            if (debug) console.warn("[LB dbg] parse: монитор не найден, ищем", screenObj.name, "есть:", mons.map(m => m.name).join(","))
            return
        }

        const wsNow = mon.activeWorkspace.id
        const changed = slideWorkspaces && curWs !== -1 && wsNow !== curWs
        if (changed) slideDir = wsNow > curWs ? 1 : -1
        curWs = wsNow

        const spId = (mon.specialWorkspace && mon.specialWorkspace.id) ? mon.specialWorkspace.id : 0
        const spChanged = spEnabled && curSp !== -1000000 && spId !== curSp
        curSp = spId
        const t0 = (changed || spChanged) ? stamp() : 0
        if (changed || spChanged) { startSlide(); resnap(); kick() }
        const spOff = slideOff(-1, spFrac, height)
        const dim = slideVertical ? height : width

        const tops = ToplevelManager.toplevels.values

        const byAddr = ({})
        try {
            const hts = Hyprland.toplevels ? Hyprland.toplevels.values : []
            for (let i = 0; i < hts.length; i++)
                if (hts[i] && hts[i].wayland && hts[i].address !== undefined)
                    byAddr[String(hts[i].address).replace(/^0x/, "")] = hts[i].wayland
        } catch (e) {}
        const taken = ({})
        const dbgSeen = []
        const dbgMiss = []
        let floatSeen = false
        const out = ({})

        const list = []
        for (let i = 0; i < cls.length; i++) {
            const c = cls[i]
            if (!c.mapped || c.hidden) continue
            if (!c.workspace) continue
            if (c.monitor !== mon.id) continue
            const isSp = spId !== 0 && c.workspace.id === spId
            const onScreen = isSp || c.workspace.id === mon.activeWorkspace.id
            if (onScreen && c.floating) floatSeen = true

            const x = c.at[0] - mon.x
            const y = c.at[1] - mon.y
            const w = c.size[0]
            const h = c.size[1]
            if (w < 1 || h < 1) continue
            const m = c.floating ? prewarm : 0
            const inRoi = !(x + w <= roi.x - m || x >= roi.x + roi.width + m || y + h <= roi.y - m || y >= roi.y + roi.height + m)
            list.push({ c: c, x: x, y: y, w: w, h: h, isSp: isSp, alive: onScreen && inRoi })
        }

        for (let pass = 0; pass < 2; pass++) {
            for (let n = 0; n < list.length; n++) {
                const it = list[n]
                if (it.alive !== (pass === 0)) continue
                if (!it.alive && !parkOthers) continue
                const c = it.c

                let tl = byAddr[String(c.address).replace(/^0x/, "")] || null
                for (let k = 0; k < tops.length && !tl; k++)
                    if (!taken[k] && tops[k].appId === c["class"] && tops[k].title === c.title) { tl = tops[k]; taken[k] = true }
                for (let k = 0; k < tops.length && !tl; k++)
                    if (!taken[k] && tops[k].appId === c["class"]) { tl = tops[k]; taken[k] = true }
                if (it.alive) dbgSeen.push(c["class"] + (tl ? "" : " (нет окна Wayland)"))
                if (!tl) { if (it.alive) dbgMiss.push(c["class"] + " | " + c.title); continue }

                out[c.address] = { x: it.x, y: it.y, w: it.w, h: it.h,
                                   z: (it.isSp ? 3000 : 0) + (c.floating ? 1000 - Math.max(0, c.focusHistoryID) : 0),
                                   sp: it.isSp, alive: it.alive,
                                   toplevel: tl, used: false }
            }
        }
        let nAlive = 0
        for (const a in out) if (out[a].alive) nAlive++
        aliveCount = nAlive

        hasFloat = floatSeen
        if (debug) console.warn("[LB dbg] roi", Math.round(roi.x), Math.round(roi.y), Math.round(roi.width), Math.round(roi.height),
                               "| ws", wsNow, "| окон в области:", dbgSeen.length, JSON.stringify(dbgSeen),
                               "| toplevels Wayland:", tops.length)

        const now = Date.now()
        const enterOf = o => o.sp ? (spChanged ? spOff : 0) : (changed ? slideOff(slideDir, slideFrac, dim) : 0)
        for (let i = 0; i < winModel.count; i++) {
            const row = winModel.get(i)
            const o = out[row.addr]
            if (o && o.alive) {
                if (!row.walive)
                    winModel.set(i, { wenter: enterOf(o), wstart: t0 })
                winModel.set(i, { wx: o.x, wy: o.y, ww: o.w, wh: o.h, wz: o.z, wtop: o.toplevel, walive: true, wleave: 0,
                                  wspecial: o.sp, wvert: o.sp ? true : slideVertical, wexists: true })
                o.used = true
            } else {
                if (o) {
                    o.used = true
                    if (row.wx !== o.x || row.wy !== o.y || row.ww !== o.w || row.wh !== o.h)
                        winModel.set(i, { wx: o.x, wy: o.y, ww: o.w, wh: o.h, wtop: o.toplevel, wexists: true })
                    else if (!row.wexists)
                        winModel.set(i, { wexists: true })
                } else if (row.wexists) {
                    winModel.set(i, { wexists: false })
                }
                if (row.walive) {
                    const lv = row.wspecial ? (spChanged ? spOff : 0) : (changed ? slideOff(-slideDir, slideFrac, dim) : 0)
                    winModel.set(i, { walive: false, wdead: now, wleave: lv })
                }
            }
        }
        for (const a in out) {
            const o = out[a]
            if (o.used) continue
            kick()
            winModel.append({
                addr: a, wx: o.x, wy: o.y, ww: o.w, wh: o.h, wz: o.z,
                wtop: o.toplevel, walive: o.alive, wdead: 0,
                wenter: o.alive ? enterOf(o) : 0,
                wleave: 0, wstart: o.alive ? t0 : 0,
                wspecial: o.sp, wvert: o.sp ? true : slideVertical,
                wexists: true
            })
        }
        if (!pruneTimer.running) pruneTimer.start()
        tex.scheduleUpdate()
    }

    // чистит из модели окна, которые давно уехали и закрылись
    Timer {
        id: pruneTimer
        interval: root.pruneMs + 50
        onTriggered: {
            const now = Date.now()
            for (let i = winModel.count - 1; i >= 0; i--) {
                const row = winModel.get(i)
                if (!row.walive && !row.wexists && now - row.wdead > root.pruneMs) winModel.remove(i)
            }
            for (let j = 0; j < winModel.count; j++)
                if (!winModel.get(j).walive && !winModel.get(j).wexists) { pruneTimer.restart(); break }
            tex.scheduleUpdate()
        }
    }

    // задержка на событие воркспейса (если wsDelay > 0)
    Timer {
        id: wsDebounce
        interval: root.wsDelay
        onTriggered: { root.wsEventAt = Date.now(); root.refresh() }
    }

    // небольшая задержка при смене roi, чтобы не дёргать hyprctl на каждый пиксель
    Timer {
        id: debounce
        interval: 20
        onTriggered: root.refresh()
    }

    Timer {
        // периодический опрос: чаще если окна движутся
        interval: (root.trackFast && (root.aliveCount > 0 || root.hasFloat)) ? root.fastPollMs : root.pollInterval
        repeat: true
        running: root.active && root.showWindows
        onTriggered: root.refresh()
    }

    // события Hyprland: перезагрузка конфига, смена воркспейса и вообще любое событие - повод обновиться
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "configreloaded") root.loadAnim()

            const wsEv = event.name === "workspace" || event.name === "workspacev2"
                || event.name === "focusedmon" || event.name === "focusedmonv2"
                || event.name === "activespecial" || event.name === "activespecialv2"
            if (wsEv && root.wsDelay > 0) { wsDebounce.restart(); return }
            if (wsEv) root.wsEventAt = Date.now()

            root.refresh()
        }
    }

    // сигнатура последних найденных обоев (путь + время изменения), чтобы не перезагружать зря
    property string lastSig: ""
    property int reloadTick: 0

    property double pushedAt: 0
    // обои пришли снаружи по IPC: ставим сразу и на 4 секунды отключаем автоопределение
    function pushWallpaper(path) {
        if (!path || path.indexOf("/") !== 0) return
        pushedAt = Date.now()
        lastSig = ""
        reloadTick++
        detected = path
        applyWall()
        console.log("[LiveBackdrop] обои (IPC):", path)
    }

    // IPC: qs ipc call backdrop setWallpaper <путь> / refresh
    IpcHandler {
        target: "backdrop"
        function setWallpaper(path: string): void { root.pushWallpaper(path) }
        function refresh(): void { root.pushedAt = 0; root.redetect() }
    }

    // запустить автоопределение обоев
    function redetect() {
        if (wallpaper !== "" || !autoDetect || detectProc.running) return
        detectProc.running = true
    }

    // shell-скрипт: ищет текущие обои у hyprpaper, потом swww/awww, потом в hyprpaper.conf
    Process {
        id: detectProc
        command: ["sh", "-c", [
            'find_wall() {',
            '  out=$(hyprctl hyprpaper listactive 2>/dev/null)',
            '  p=$(printf "%s\n" "$out" | grep -m1 -- "$1" || printf "%s\n" "$out" | head -n1)',
            '  p=$(printf "%s" "$p" | sed "s/^.*= *//")',
            '  case "$p" in /*) return;; esac',
            '  for tool in swww awww; do',
            '    out=$($tool query 2>/dev/null)',
            '    p=$(printf "%s\n" "$out" | grep -m1 -- "$1" || printf "%s\n" "$out" | head -n1)',
            '    p=$(printf "%s" "$p" | sed "s/.*image: //")',
            '    case "$p" in /*) return;; esac',
            '  done',
            '  f="$HOME/.config/hypr/hyprpaper.conf"',
            '  p=$(grep -m1 -E "^[[:space:]]*(wallpaper|preload|path)[[:space:]]*=" "$f" 2>/dev/null | sed "s/^.*[=,][[:space:]]*//; s/[[:space:]]*$//")',
            '  case "$p" in "~"*) p="$HOME${p#"~"}";; esac',
            '  case "$p" in /*) return;; esac',
            '  p=""',
            '}',
            'find_wall "$1"',
            '[ -n "$p" ] && { echo "$p"; stat -c %Y "$p" 2>/dev/null; }'
        ].join("\n"), "sh", root.screenObj ? root.screenObj.name : ""]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n")
                const p = lines[0] || ""
                if (Date.now() - root.pushedAt < 4000) return
                if (p.startsWith("/")) {
                    const sig = p + "|" + (lines[1] || "")
                    if (sig !== root.lastSig) {
                        root.lastSig = sig
                        root.reloadTick++

                        root.detected = p
                        root.applyWall()
                        console.log("[LiveBackdrop] обои:", p)
                    }
                } else if (root.detected === "") {
                    console.log("[LiveBackdrop] обои не найдены — задайте QS_WALLPAPER или wallpaper в Visual.qml")
                }
            }
        }
    }

    Timer {
        // пока обои не заданы вручную - регулярно проверяем не сменились ли
        interval: root.detectMs
        repeat: true
        running: root.autoDetect && root.active && root.wallpaper === ""
        onTriggered: root.redetect()
    }

    // на старте: обои, окна, анимации
    Component.onCompleted: {
        if (debug) console.warn("[LB dbg] LiveBackdrop создан, debug включён")
        applyWall()
        redetect()
        refresh()
        loadAnim()
    }
}
