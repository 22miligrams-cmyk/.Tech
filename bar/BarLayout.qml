// BarLayout.qml
//
// Зачем это: мозг раскладки бара. Тут хранится какие блоки в какой зоне
// (left / center / right) и в каком порядке, какие из них "склеены" с соседом,
// и все настройки бара: позиция, автоскрытие, стекло, часы 12ч, текст песни и т.д.
// Всё сохраняется в ~/.cache/quickshell/layout.json (с задержкой, чтоб не писать
// на диск на каждый чих) и подхватывается при старте.

import QtQuick
import Quickshell.Io
import "../panels"
import "../notifications"
import "../settings"
import "../common"

Item {
    id: barLayout

    // куда сохраняем
    readonly property string savePath: Paths.home + "/.cache/quickshell/layout.json"
    // все блоки, которые вообще бывают
    readonly property var allBlocks: ["ws", "mpris", "bt", "app", "search", "sys", "notif", "vol", "battery", "clip", "tray", "lyrics"]
    // раскладка по умолчанию (для кнопки "сбросить")
    readonly property var defaults: ({
        left: ["ws", "mpris", "lyrics", "bt"],
        center: ["app", "search"],
        right: ["tray", "clip", "vol", "battery", "sys", "notif"]
    })

    // с какой стороны экрана бар
    readonly property var positions: ["bottom", "left", "top", "right"]
    property string position: "bottom"

    // настройки внешнего вида - все меняются через set*() ниже, чтобы сразу сохраняться
    property bool autoHide: false

    property bool solidBar: false

    property bool island: true

    property bool clock12: false

    property bool camEffect: true   // эффект «камеры» в меню настроек: интерфейс плавно следует за мышью

    property bool showLyrics: true;  property bool showLyricsDot: true
    property bool lyricsAutoHide: true   // false — плашка текста в баре не пропадает никогда (руками скрыть можно и так)

    property real subPush: 0

    property real glassAlpha: 0.6
    readonly property var glassPresets: [0.2, 0.4, 0.6, 0.8, 1.0]

    // прозрачность стекла 0..1, округляем до сотых
    function setGlassAlpha(v) {
        v = Math.round(Math.max(0, Math.min(1, v))*100)/100
        if (v === glassAlpha) return
        glassAlpha = v
        saveTimer.restart()
    }

    // переключает стекло по кругу по пресетам (кнопка в меню)
    function cycleGlass() {
        for (let i = 0; i < glassPresets.length; i++) {
            if (glassPresets[i] > glassAlpha + 0.001) { setGlassAlpha(glassPresets[i]); return }
        }
        setGlassAlpha(glassPresets[0])
    }

    // дальше однотипные сеттеры: если значение то же - ничего не делаем, иначе меняем и сохраняем
    function setClock12(v) {
        if (v === clock12) return
        clock12 = v
        saveTimer.restart()
    }

    function setCamEffect(v) {
        if (v === camEffect) return
        camEffect = v
        saveTimer.restart()
    }

    function setShowLyrics(v) {
        if (v === showLyrics) return
        showLyrics = v
        saveTimer.restart()
    }

    function setLyricsAutoHide(v) {
        if (v === lyricsAutoHide) return
        lyricsAutoHide = v
        saveTimer.restart()
    }

    function setShowLyricsDot(v) {
        if (v === showLyricsDot) return
        showLyricsDot = v
        saveTimer.restart()
    }

    function setSolidBar(v) {
        if (v === solidBar) return
        solidBar = v
        saveTimer.restart()
    }

    function setIsland(v) {
        if (v === island) return
        island = v
        saveTimer.restart()
    }

    function setAutoHide(v) {
        if (v === autoHide) return
        autoHide = v
        saveTimer.restart()
    }

    // позицию принимаем только из списка positions
    function setPosition(p) {
        if (positions.indexOf(p) < 0 || p === position) return
        position = p
        saveTimer.restart()
    }

    // сброс раскладки к дефолту (настройки внешнего вида не трогаем)
    function reset() {
        applySaved(JSON.stringify({ left: defaults.left, center: defaults.center, right: defaults.right }))
        saveTimer.restart()
    }

    // какие блоки склеены с левым соседом (id -> true)
    property var joins: ({})

    // счётчик изменений: его читают биндинги, чтобы пересчитаться когда раскладка поменялась
    property int rev: 0

    // три модели, по одной на зону (стартовые значения = дефолтная раскладка)
    property alias leftModel: lm
    property alias centerModel: cm
    property alias rightModel: rm

    ListModel {
        id: lm
        ListElement { blockId: "ws" }
        ListElement { blockId: "mpris" }
        ListElement { blockId: "lyrics" }
        ListElement { blockId: "bt" }
    }

    ListModel {
        id: cm
        ListElement { blockId: "app" }
        ListElement { blockId: "search" }
    }

    ListModel {
        id: rm
        ListElement { blockId: "tray" }
        ListElement { blockId: "clip" }
        ListElement { blockId: "vol" }
        ListElement { blockId: "battery" }
        ListElement { blockId: "sys" }
        ListElement { blockId: "notif" }
    }

    // модель зоны по её имени
    function model(zone) {
        return zone === "left" ? lm : (zone === "center" ? cm : rm)
    }

    // позиция блока в модели, -1 если его там нет
    function indexIn(m, id) {
        for (let i = 0; i < m.count; i++) {
            if (m.get(i).blockId === id) return i
        }
        return -1
    }

    // в какой зоне сейчас блок ("" если нигде)
    function zoneOf(id) {
        let dep = rev
        let zones = ["left", "center", "right"]
        for (let k = 0; k < zones.length; k++) {
            if (indexIn(model(zones[k]), id) >= 0) return zones[k]
        }
        return ""
    }

    // есть ли у блока сосед слева
    function hasLeft(id) {
        let dep = rev
        let z = zoneOf(id)
        if (z === "") return false
        return indexIn(model(z), id) > 0
    }

    // склеен ли блок с левым соседом
    function isJoined(id) {
        let dep = rev
        return joins[id] === true && hasLeft(id)
    }

    // склеить / расклеить блок с левым соседом
    function toggleJoin(id) {
        if (!hasLeft(id)) return
        let nj = Object.assign({}, joins)
        if (nj[id]) delete nj[id]
        else nj[id] = true
        joins = nj
        touch()
    }

    // id блока справа от данного ("" если он последний)
    function nextOf(id) {
        let z = zoneOf(id)
        if (z === "") return ""
        let m = model(z)
        let i = indexIn(m, id)
        return (i >= 0 && i + 1 < m.count) ? m.get(i + 1).blockId : ""
    }

    // расклеивает блок и его правого соседа, зовём перед любым перемещением
    function unjoinAround(id) {
        let nj = Object.assign({}, joins)
        let nx = nextOf(id)
        delete nj[id]
        if (nx !== "") delete nj[nx]
        joins = nj
    }

    // можно ли подвинуть блок на delta позиций в своей зоне
    function canShift(id, delta) {
        let dep = rev
        let z = zoneOf(id)
        if (z === "") return false
        let m = model(z)
        let j = indexIn(m, id) + delta
        return j >= 0 && j < m.count
    }

    // текущая раскладка как обычный объект {left, center, right}
    function snapshot() {
        let out = { left: [], center: [], right: [] }
        let zones = ["left", "center", "right"]
        for (let k = 0; k < zones.length; k++) {
            let m = model(zones[k])
            for (let i = 0; i < m.count; i++) out[zones[k]].push(m.get(i).blockId)
        }
        return out
    }

    // всё что пишем в файл: раскладка + настройки + склейки
    function savePayload() {
        let out = snapshot()
        out.position = position
        out.autoHide = autoHide
        out.solidBar = solidBar
        out.island = island
        out.clock12 = clock12
        out.camEffect = camEffect
        out.showLyrics = showLyrics
        out.showLyricsDot = showLyricsDot
        out.lyricsAutoHide = lyricsAutoHide
        out.glassAlpha = glassAlpha
        out.joined = Object.keys(joins).filter(k => joins[k] === true && allBlocks.indexOf(k) >= 0).sort()
        return out
    }

    // отметить что раскладка поменялась и запустить сохранение
    function touch() {
        rev++
        saveTimer.restart()
    }

    // перекинуть блок в конец другой зоны
    function moveTo(id, zone) {
        let from = zoneOf(id)
        if (from === "" || from === zone) return
        unjoinAround(id)
        let fm = model(from)
        fm.remove(indexIn(fm, id))
        model(zone).append({ blockId: id })
        unjoinAround(id)
        touch()
    }

    // поставить блок в зону на конкретный индекс (так работает перетаскивание)
    function place(id, zone, index) {
        let from = zoneOf(id)
        if (from === "") return
        let fm = model(from)
        let fi = indexIn(fm, id)
        if (from === zone) {
            let idx = Math.max(0, Math.min(index, fm.count - 1))
            if (idx === fi) return
            unjoinAround(id)
            fm.move(fi, idx, 1)
        } else {
            unjoinAround(id)
            fm.remove(fi)
            let tm = model(zone)
            tm.insert(Math.max(0, Math.min(index, tm.count)), { blockId: id })
        }
        unjoinAround(id)
        touch()
    }

    // сдвинуть блок на соседнюю позицию (кнопками)
    function shift(id, delta) {
        if (!canShift(id, delta)) return
        let m = model(zoneOf(id))
        let i = indexIn(m, id)
        unjoinAround(id)
        m.move(i, i + delta, 1)
        unjoinAround(id)
        touch()
    }

    // разбирает сохранённый json и применяет: мусор и дубли выкидываем, пропавшие блоки возвращаем из дефолта
    function applySaved(text) {
        let obj
        try { obj = JSON.parse(text) } catch (e) {
            console.warn("[BarLayout] layout.json не разобрался, оставляю текущую раскладку:", e)
            return
        }
        if (!obj) return

        if (positions.indexOf(obj.position) >= 0) position = obj.position
        if (typeof obj.autoHide === "boolean") autoHide = obj.autoHide
        if (typeof obj.solidBar === "boolean") solidBar = obj.solidBar
        if (typeof obj.island === "boolean") island = obj.island
        if (typeof obj.clock12 === "boolean") clock12 = obj.clock12
        if (typeof obj.camEffect === "boolean") camEffect = obj.camEffect
        if (typeof obj.showLyrics === "boolean") showLyrics = obj.showLyrics
        if (typeof obj.showLyricsDot === "boolean") showLyricsDot = obj.showLyricsDot
        if (typeof obj.lyricsAutoHide === "boolean") lyricsAutoHide = obj.lyricsAutoHide
        if (typeof obj.glassAlpha === "number") glassAlpha = Math.max(0, Math.min(1, obj.glassAlpha))

        let zones = ["left", "center", "right"]
        let seen = {}
        let next = { left: [], center: [], right: [] }

        for (let k = 0; k < zones.length; k++) {
            let list = obj[zones[k]]
            if (!Array.isArray(list)) continue
            for (let i = 0; i < list.length; i++) {
                let id = list[i]
                if (allBlocks.indexOf(id) >= 0 && !seen[id]) {
                    seen[id] = true
                    next[zones[k]].push(id)
                }
            }
        }

        for (let k = 0; k < zones.length; k++) {
            let d = defaults[zones[k]]
            for (let i = 0; i < d.length; i++) {
                if (!seen[d[i]]) {
                    seen[d[i]] = true
                    next[zones[k]].push(d[i])
                }
            }
        }

        let nj = {}
        if (Array.isArray(obj.joined)) {
            for (let i = 0; i < obj.joined.length; i++) {
                if (allBlocks.indexOf(obj.joined[i]) >= 0) nj[obj.joined[i]] = true
            }
        }
        let joinsChanged = JSON.stringify(Object.keys(nj).sort()) !== JSON.stringify(Object.keys(joins).filter(k => joins[k]).sort())
        if (joinsChanged) joins = nj

        if (JSON.stringify(next) === JSON.stringify(snapshot())) {
            if (joinsChanged) rev++
            return
        }

        for (let k = 0; k < zones.length; k++) {
            let m = model(zones[k])
            m.clear()
            for (let i = 0; i < next[zones[k]].length; i++) m.append({ blockId: next[zones[k]][i] })
        }
        rev++
    }

    // читаем сохранённый layout.json
    FileView {
        id: file
        path: barLayout.savePath
        blockLoading: true
        onLoaded: barLayout.applySaved(file.text())
    }

    // на старте применяем что успели прочитать
    Component.onCompleted: {
        try { applySaved(file.text()) } catch (e) {  }
    }

    // процесс, которым пишем файл
    Process { id: saveProc }

    // отложенное сохранение: ждём 400мс тишины, потом пишем файл атомарно (tmp + mv)
    Timer {
        id: saveTimer
        interval: 400;  repeat: false
        onTriggered: {
            if (saveProc.running) {
                saveTimer.restart()
                return
            }
            saveProc.command = ["bash", "-c",

                "mkdir -p \"$(dirname \"$1\")\" && t=\"$1.tmp.$$\" && " +
                "{ printf '%s' \"$2\" > \"$t\" && mv -f \"$t\" \"$1\"; } || { rm -f \"$t\"; exit 1; }",
                "_", barLayout.savePath, JSON.stringify(barLayout.savePayload())]
            saveProc.running = true
        }
    }
}
