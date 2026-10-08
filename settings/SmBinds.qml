// Раздел «Бинды»: хоткеи для лаунчера, смены обоев, файлового менеджера и свои команды.
// Тут запись клавиш, проверка конфликтов с уже существующими биндами Hyprland и запуск qsbinds.py,
// который дописывает управляемый блок в hyprland.lua.
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root
    required property var menu

    readonly property string launchersDir: Quickshell.shellPath("launchers")
    readonly property string bdScript: Quickshell.shellPath("settings/qsbinds.py")

    // IPC-префикс, который явно указывает, к какому шеллу обращаться. Без -p/-c «quickshell ipc»
    // ищет конфиг «default» и не находит шелл, запущенный через «-c tech» (из-за этого бинды молчали)
    readonly property string ipcPrefix: "quickshell ipc -p '" + Quickshell.shellPath("shell.qml") + "'"

    // чинит старые сохранённые команды вида «quickshell ipc call shell X» / «quickshell ipc -c tech call shell X»
    function fixCmd(cmd) {
        return String(cmd || "").replace(/^quickshell ipc(\s+(-c|-p|--config|--path)\s+('[^']*'|\S+))?\s+call\s+shell\s/,
                                         ipcPrefix + " call shell ")
    }

    readonly property var bdDefs: [
        { id: "launcher", cmd: "sh -c \"quickshell ipc -p " + launchersDir + "/laun.qml call launcher toggle 2>/dev/null || QS_LAUNCHER_SHOW=1 quickshell -d -p " + launchersDir + "/laun.qml\"" },
        { id: "wall",     cmd: "sh -c \"quickshell ipc -p " + launchersDir + "/wall.qml call wall toggle 2>/dev/null || QS_WALL_SHOW=1 quickshell -d -p " + launchersDir + "/wall.qml\"" },
        { id: "files",    var: "fileManager" }
    ]

    // отложенное применение: если подряд меняют несколько вещей, скрипт запустится один раз
    function scheduleApply() { bdApplyTimer.restart() }

    // красивое имя клавиши (SUPER -> Super и т.д.)
    function pk(k) { return menu.hyprCtl.prettyKey(k) }

    // следующий основной модификатор из списка
    function cycleBdMod() { menu.bdMod = menu.cycleList(menu.bdMods, menu.bdMod); menu.storeCtl.save(); bdApplyTimer.restart() }

    // включает/выключает управление биндами целиком
    function setBdEnabled(v) { menu.bdEnabled = v; menu.storeCtl.save(); bdApplyTimer.restart() }

    // записывает клавишу для бинда id, сохраняет и пересобирает блок
    function setBdKey(id, k) {
        const o = Object.assign({}, menu.bdKeys)
        o[id] = k
        menu.bdKeys = o
        menu.storeCtl.save()
        bdApplyTimer.restart()
    }

    // убирает клавишу у бинда (и выходит из режима записи, если он был на нём)
    function clearBind(id) {
        if (menu.bdCapture === id) menu.bdCapture = ""
        setBdKey(id, "")
    }

    // включает режим «жду нажатие клавиши» для бинда
    function beginCapture(id) { menu.bdCapture = id }

    // по событию клавиши даёт её имя для hyprland: буквы, цифры, F1-F12, пробел.
    // Для остальных раскладок (кириллица) берёт букву по сканкоду
    function bdKeyName(ev) {
        const k = ev.key
        if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(k)
        if (k >= Qt.Key_0 && k <= Qt.Key_9) return String.fromCharCode(k)
        if (k >= Qt.Key_F1 && k <= Qt.Key_F12) return "F" + (k - Qt.Key_F1 + 1)
        if (k === Qt.Key_Space) return "SPACE"
        let sc = ev.nativeScanCode - 8
        const rows = [[16, "QWERTYUIOP"], [30, "ASDFGHJKL"], [44, "ZXCVBNM"]]
        for (const r of rows)
            if (sc >= r[0] && sc < r[0] + r[1].length) return r[1][sc - r[0]]
        return ""
    }

    // ловит нажатую комбинацию, пока включён режим записи. Esc отменяет.
    // Основной модификатор не пишется, он добавляется сам, остальные идут в комбинацию
    function captureKey(ev) {
        if (ev.key === Qt.Key_Escape) { menu.bdCapture = ""; return }
        const n = bdKeyName(ev)
        if (n === "") return

        const em = pk(bdEffectiveMod()).toUpperCase()
        const extra = []
        if ((ev.modifiers & Qt.MetaModifier) && em !== "SUPER") extra.push("SUPER")
        if ((ev.modifiers & Qt.ControlModifier) && em !== "CTRL") extra.push("CTRL")
        if ((ev.modifiers & Qt.AltModifier) && em !== "ALT") extra.push("ALT")
        if ((ev.modifiers & Qt.ShiftModifier) && em !== "SHIFT") extra.push("SHIFT")
        setBdKey(menu.bdCapture, extra.concat([n]).join("+"))
        menu.bdCapture = ""
    }

    // какой модификатор реально используется: выбранный вручную или найденный в конфиге (по умолчанию SUPER)
    function bdEffectiveMod() {
        return menu.bdMod === "auto" ? (menu.parsed.mod || "SUPER") : menu.bdMod
    }

    // список клавиш для показа в чипсах: модификатор, доп. модификаторы и сама клавиша
    function bdCombo(id) {
        if (menu.bdCapture === id) return ["…"]
        if (!menu.bdKeys[id]) return []
        const parts = (menu.bdKeys[id] || "").split("+")
        const base = parts.pop()
        return [pk(bdEffectiveMod())].concat(parts.filter(p => p).map(p => pk(p)), [pk(base)])
    }

    // если такая комбинация уже занята в hyprland.lua, возвращает описание того бинда, иначе пустую строку
    function bdConflict(id) {
        if (!menu.bdKeys[id] || menu.bdCapture === id) return ""
        const norm = a => a.map(x => x.toLowerCase()).sort().join("+")
        const want = norm(bdCombo(id))
        for (const b of menu.parsed.binds)
            if (norm(b.keys) === want) return b.desc
        return ""
    }

    // подсказка под карточкой встроенного бинда (нажми клавишу / не задан / занято / изменить)
    function bdHint(id) {
        if (menu.bdCapture === id) return menu.tr("bind.press")
        if (!menu.bdKeys[id]) return menu.tr("bind.nokey")
        if (id === "files" && !menu.parsed.vars.fileManager) return menu.tr("bind.nofm")
        const c = bdConflict(id)
        if (c) return menu.tr("bind.taken") + c
        return menu.tr("bind.change")
    }

    // выбирает русский или английский текст по текущему языку
    function atText(ru, en) { return menu.lang === "ru" ? ru : en }

    // то же что bdHint, только для своих биндов (там нет проверки файлового менеджера)
    function customHint(id) {
        if (menu.bdCapture === id) return menu.tr("bind.press")
        if (!menu.bdKeys[id]) return menu.tr("bind.nokey")
        const c = bdConflict(id)
        return c ? menu.tr("bind.taken") + c : menu.tr("bind.change")
    }

    readonly property var presetIcons: ["calendar", "sys", "volume", "player", "notifications", "clipboard",
                                        "tray", "bluetooth", "workspaces", "settings", "dnd", "alttab", "alttabPrev"]

    // иконка своего бинда: если команда вызывает известное окно шелла, берём его иконку, иначе общую
    function customIcon(c) {
        const m = /\scall shell (\w+)\s*$/.exec(c.cmd || "")
        return (m && presetIcons.indexOf(m[1]) >= 0) ? m[1] : "custom"
    }

    // собирает объект карточки для своего бинда
    function customCard(c) {
        return {
            id: c.id, custom: true, kind: "keybind", label: c.name, icon: "", svg: root.customIcon(c),
            get: () => false, keys: () => root.bdCombo(c.id), hint: () => root.customHint(c.id),
            set: v => root.beginCapture(c.id),
            edit: () => menu.bindEditor.openBindEditor(c.id), remove: () => root.removeCustomBind(c.id)
        }
    }

    property var pendingRemove: null
    property int pendingIdx: 0

    // удаление с анимацией: карточка сначала гаснет, потом через таймер выполняется fn
    function animatedRemove(fn) {
        if (rmTimer.running) return
        const grid = menu.settingsGrid
        const it = grid.itemAtIndex(grid.currentIndex)
        if (it) it.removing = true
        pendingIdx = grid.currentIndex
        pendingRemove = fn
        rmTimer.restart()
    }

    Timer {
        id: rmTimer
        interval: 280
        onTriggered: {
            menu.cardsInstant = true
            menu.removedAt = root.pendingIdx
            menu.removeSettling = true
            if (root.pendingRemove) root.pendingRemove()
            Qt.callLater(() => {
                const g = menu.settingsGrid
                g.currentIndex = Math.max(0, Math.min(root.pendingIdx, g.count - 1))
                g.forceActiveFocus()
                instantOff.restart()
            })
        }
    }

    Timer { id: instantOff; interval: 80; onTriggered: { menu.cardsInstant = false; menu.removeSettling = false } }

    // удаляет свой бинд: клавишу, саму запись, сохраняет и пересобирает блок
    function removeCustomBind(id) {
        animatedRemove(() => {
            const k = Object.assign({}, menu.bdKeys)
            delete k[id]
            menu.bdKeys = k
            menu.bdCustom = menu.bdCustom.filter(c => c.id !== id)
            if (menu.bdCapture === id) menu.bdCapture = ""
            menu.storeCtl.save(); bdApplyTimer.restart()
        })
    }

    // собирает json из всех биндов и запускает qsbinds.py. Если он ещё работает, пробует позже
    function applyBinds() {
        if (bdApplyProc.running) { bdApplyTimer.restart(); return }
        const binds = bdDefs.filter(d => menu.bdKeys[d.id]).map(d => d.var ? ({ key: menu.bdKeys[d.id], var: d.var }) : ({ key: menu.bdKeys[d.id], cmd: d.cmd }))
        for (const c of menu.bdCustom)
            if (menu.bdKeys[c.id]) binds.push({ key: menu.bdKeys[c.id], cmd: root.fixCmd(c.cmd) })
        bdApplyProc.command = ["python3", bdScript, JSON.stringify({ enabled: menu.bdEnabled, mod: menu.bdMod, lang: menu.lang, binds: binds,
                                                                alttab: { enabled: false } })]
        bdApplyProc.running = true
    }

    Timer { id: bdApplyTimer; interval: 700; onTriggered: root.applyBinds() }

    Process {
        id: bdApplyProc
        stdout: StdioCollector { id: bdOut }
        stderr: StdioCollector { id: bdErr }
        onExited: (code, status) => {
            menu.bdStatus = code === 0 ? bdOut.text.trim().split("\n").slice(-1)[0]
                                       : (menu.tr("bind.err") + (bdErr.text.trim() || menu.tr("bind.code") + code).slice(-160))
            menu.hyprCtl.reloadHypr()
        }
    }

    readonly property var bindModel: bindBase.concat(menu.bdCustom.map(c => customCard(c)), [
        { id: "bd_add", kind: "add", icon: String.fromCodePoint(0xF0415),
          get: () => false, hint: () => menu.tr("bind.add"), set: v => menu.bindEditor.openBindEditor("") }
    ])

    readonly property var bindBase: [
        { id: "bd_on", kind: "toggle", icon: String.fromCodePoint(0xF030C),
          get: () => menu.bdEnabled, set: v => root.setBdEnabled(v),
          hint: () => menu.bdStatus },
        { id: "bd_mod", kind: "cycle", icon: String.fromCodePoint(0xF0633),
          get: () => true,
          valueText: () => menu.bdMod === "auto"
              ? menu.tr("ui.auto") + ": " + (menu.parsed.mod ? menu.hyprCtl.prettyKey(menu.parsed.mod) : "Super")
              : menu.hyprCtl.prettyKey(menu.bdMod),
          set: v => root.cycleBdMod() },
        { id: "bd_launcher", kind: "keybind", bind: "launcher", icon: String.fromCodePoint(0xF003B),
          get: () => false, keys: () => root.bdCombo("launcher"), hint: () => root.bdHint("launcher"),
          set: v => root.beginCapture("launcher"), remove: () => root.clearBind("launcher") },
        { id: "bd_wall", kind: "keybind", bind: "wall", icon: String.fromCodePoint(0xF02E9),
          get: () => false, keys: () => root.bdCombo("wall"), hint: () => root.bdHint("wall"),
          set: v => root.beginCapture("wall"), remove: () => root.clearBind("wall") },
        { id: "bd_files", kind: "keybind", bind: "files", icon: String.fromCodePoint(0xF024B),
          get: () => false, keys: () => root.bdCombo("files"), hint: () => root.bdHint("files"),
          set: v => root.beginCapture("files"), remove: () => root.clearBind("files") }
    ]
}
