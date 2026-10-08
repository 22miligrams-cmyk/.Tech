// Разбор hyprland.lua: достаёт оттуда hl.bind(...), переменные и главный модификатор,
// чтобы показывать занятые комбинации и подставлять mod в настройках биндов.
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root
    required property var menu

    // красивое название клавиши для показа (SUPER_L -> Super, RETURN -> Enter и т.п.)
    function prettyKey(k) {
        const map = {
            SUPER: "Super", SUPER_L: "Super", SUPER_R: "Super", WIN: "Super", MOD4: "Super",
            ALT: "Alt", MOD1: "Alt", CTRL: "Ctrl", CONTROL: "Ctrl", SHIFT: "Shift",
            RETURN: "Enter", ENTER: "Enter", SPACE: "Space", ESCAPE: "Esc", PRINT: "PrtSc", TAB: "Tab"
        }
        if (!k) return "—"
        const u = k.toUpperCase()
        if (map[u]) return map[u]
        return k.length === 1 ? u : k
    }

    // обрезает длинную строку до 60 символов с многоточием
    function shorten(s) { return s.length > 60 ? s.substring(0, 57) + "…" : s }

    // считает lua-выражение вида mainMod .. " + P": строки склеивает, имена заменяет значениями переменных
    function evalExpr(expr, vars) {
        let out = ""
        const re = /"([^"]*)"|'([^']*)'|([A-Za-z_][\w.]*)/g
        let m
        while ((m = re.exec(expr)) !== null) {
            if (m[1] !== undefined) out += m[1]
            else if (m[2] !== undefined) out += m[2]
            else out += (vars[m[3]] !== undefined ? vars[m[3]] : m[3])
        }
        return out
    }

    // читает аргументы вызова функции начиная с позиции start (сразу после открывающей скобки).
    // Учитывает вложенные скобки, кавычки и lua-комментарии, возвращает массив строк-аргументов
    function readCall(src, start) {
        let depth = 0, q = "", cur = ""
        const args = []
        for (let i = start; i < src.length; i++) {
            const c = src[i]
            if (q) { cur += c; if (c === q && src[i - 1] !== "\\") q = ""; continue }
            if (c === '"' || c === "'") { q = c; cur += c; continue }
            if (c === "-" && src[i + 1] === "-") { while (i < src.length && src[i] !== "\n") i++; cur += " "; continue }
            if (c === "(" || c === "{" || c === "[") depth++
            else if (c === ")" || c === "}" || c === "]") {
                if (depth === 0) { args.push(cur.trim()); return args }
                depth--
            } else if (c === "," && depth === 0) { args.push(cur.trim()); cur = ""; continue }
            cur += c
        }
        return args
    }

    // делает из действия бинда короткое описание: для exec_cmd «Запуск: команда», для остальных имя dispatcher'а с параметрами
    function describeAction(expr, vars) {
        const s = expr.replace(/\s+/g, " ").trim()
        let m = s.match(/exec_cmd\s*\((.*)\)\s*$/)
        if (m) return menu.tr("bind.run") + shorten(evalExpr(m[1], vars))
        m = s.match(/^(?:hl\.dsp\.)?([\w.]+)\s*\((.*)\)\s*$/)
        if (m) {
            const params = m[2].replace(/[{}"']/g, "").replace(/\s*=\s*/g, "=").trim()
            return shorten(m[1] + (params ? " · " + params : ""))
        }
        if (/^function/.test(s)) return menu.tr("bind.lua")
        return shorten(s.replace(/^hl\.dsp\./, ""))
    }

    // главная функция разбора: принимает текст конфига и выбранный модификатор (или "auto"),
    // возвращает { binds: [{keys, desc}], mod, vars }. Наш собственный блок qs-binds вырезается заранее
    function parseBinds(src, override) {
        src = src.replace(/-- >>> qs-binds[\s\S]*?-- <<< qs-binds[^\n]*/, "")
        const vars = {}
        const varRe = /^\s*(?:local\s+)?([A-Za-z_]\w*)\s*=\s*(["'])(.*?)\2\s*(?:--.*)?$/gm
        let m
        while ((m = varRe.exec(src)) !== null) vars[m[1]] = m[3]

        let modName = ""
        for (const k in vars) if (/^(mainmod|main_mod|modkey|mod)$/i.test(k)) { modName = k; break }
        if (override !== "auto") {
            if (!modName) modName = "mainMod"
            vars[modName] = override
        }

        const binds = []
        const callRe = /hl\.bind\s*\(/g
        while ((m = callRe.exec(src)) !== null) {
            const ls = src.lastIndexOf("\n", m.index) + 1
            if (src.substring(ls, m.index).indexOf("--") >= 0) continue
            const args = readCall(src, callRe.lastIndex)
            if (args.length < 2) continue
            const keys = evalExpr(args[0], vars).split(/[+,\s]+/).filter(x => x.length).map(prettyKey)
            if (!keys.length) continue
            binds.push({ keys: keys, desc: describeAction(args[1], vars) })
        }
        return { binds: binds, mod: modName ? vars[modName] : "", vars: vars }
    }

    // перечитывает hyprland.lua с диска (путь можно задать через QS_HYPR_CONF)
    function reloadHypr() { if (!hyprLoadProc.running) hyprLoadProc.running = true }

    Process {
        id: hyprLoadProc
        command: ["sh", "-c", 'cat "${QS_HYPR_CONF:-$HOME/.config/hypr/hyprland.lua}" 2>/dev/null']
        stdout: StdioCollector {
            onStreamFinished: menu.hyprSrc = text
        }
    }
}
