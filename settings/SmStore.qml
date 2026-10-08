// Сохранение и загрузка основных настроек (язык, лаунчеры, обои, бинды) в
// ~/.local/share/qs-launchers/settings.json. Сохранение отложенное, чтобы не писать файл на каждый шаг слайдера.
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root
    required property var menu

    readonly property string launchersFilePath: (Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")) + "/qs-launchers/settings.json"

    // читает настройки с диска. Каждое поле проверяется, битый json просто игнорируется
    function load() { lnLoadProc.running = true }

    // планирует запись настроек на диск (через 400 мс после последнего вызова)
    function save() { lnSaveTimer.restart() }

    Process {
        id: lnLoadProc
        command: ["sh", "-c", "cat \"" + root.launchersFilePath + "\" 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const o = JSON.parse(text)
                    if (menu.langs.indexOf(o.lang) >= 0) menu.lang = o.lang
                    const l = o.laun || {}, w = o.wall || {}
                    if (typeof l.blur === "number") menu.lnBlur = menu.clamp01(l.blur)
                    if (typeof l.tint === "number") menu.lnTint = menu.clamp01(l.tint)
                    if (typeof l.intro === "boolean") menu.lnIntro = l.intro
                    if (menu.lnTerminals.indexOf(l.terminal) >= 0) menu.lnTerminal = l.terminal
                    if (menu.wlTransitions.indexOf(w.transition) >= 0) menu.wlTransition = w.transition
                    if (typeof w.duration === "number") menu.wlDuration = Math.max(0.3, Math.min(3.0, w.duration))
                    const b = o.binds || {}
                    if (menu.bdMods.indexOf(b.mod) >= 0) menu.bdMod = b.mod
                    if (typeof b.enabled === "boolean") menu.bdEnabled = b.enabled
                    if (Array.isArray(b.custom))
                        menu.bdCustom = b.custom.filter(c => c && typeof c.id === "string" && typeof c.name === "string" && typeof c.cmd === "string")
                    if (b.keys) menu.bdKeys = Object.assign({}, menu.bdKeys, b.keys)
                    if (menu.bdEnabled) menu.bindsCtl.scheduleApply()
                } catch (e) {}
            }
        }
    }

    Process { id: lnSaveProc }

    Timer {
        id: lnSaveTimer
        interval: 400
        onTriggered: {
            lnSaveProc.command = ["sh", "-c", 'mkdir -p "$(dirname "$2")" && printf "%s" "$1" > "$2"', "sh",
                JSON.stringify({
                    lang: menu.lang,
                    laun: { blur: menu.lnBlur, tint: menu.lnTint, intro: menu.lnIntro, terminal: menu.lnTerminal },
                    wall: { transition: menu.wlTransition, duration: menu.wlDuration },
                    binds: { mod: menu.bdMod, enabled: menu.bdEnabled, keys: menu.bdKeys, custom: menu.bdCustom }
                }),
                root.launchersFilePath]
            lnSaveProc.running = true
        }
    }
}
