// Настройки блюра фона меню: включён ли, сила, живой режим, предзагрузка.
// Читает и пишет всё это в отдельный json (~/.local/share/qs-blur/settings.json).
import QtQuick
import Quickshell
import Quickshell.Io

Scope {
    id: root
    required property var menu

    // читает сохранённые настройки блюра с диска
    function load() { blurLoadProc.running = true }

    // включает/выключает блюр и откладывает сохранение
    function setBlurEnabled(v) {
        menu.blurEnabled = v
        blurSaveTimer.restart()
    }

    // живой блюр (постоянный захват экрана) вкл/выкл
    function setBlurLive(v) {
        menu.blurLive = v
        blurSaveTimer.restart()
    }

    // предзагрузка воркспейсов вкл/выкл
    function setBlurPreload(v) {
        menu.blurPreload = v
        blurSaveTimer.restart()
    }

    // задаёт силу блюра, значение зажимается в 0..1
    function setBlurStrength(v) {
        menu.blurStrength = Math.max(0, Math.min(1, v))
        blurSaveTimer.restart()
    }

    // шаг по силе блюра с клавиатуры, работает только если выбрана карточка blurpx
    function stepBlur(d) {
        const item = menu.settingsGrid.model[menu.settingsGrid.currentIndex]
        if (item && item.id === "blurpx") setBlurStrength(menu.blurStrength + d)
    }

    // перескакивает на следующий пресет силы блюра, после последнего идёт первый
    function cycleBlur() {
        const presets = [0.15, 0.35, 0.55, 0.8, 1.0]
        for (let i = 0; i < presets.length; i++)
            if (presets[i] > menu.blurStrength + 0.01) return setBlurStrength(presets[i])
        setBlurStrength(presets[0])
    }

    Process {
        id: blurLoadProc
        command: ["sh", "-c", "cat \"" + menu.blurFilePath + "\" 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const o = JSON.parse(text)
                    if (typeof o.enabled === "boolean") menu.blurEnabled = o.enabled
                    if (typeof o.live === "boolean") menu.blurLive = o.live
                    if (typeof o.preload === "boolean") menu.blurPreload = o.preload
                    if (typeof o.strength === "number") menu.blurStrength = Math.max(0, Math.min(1, o.strength))
                } catch (e) {}
            }
        }
    }

    Process { id: blurSaveProc }

    Timer {
        id: blurSaveTimer
        interval: 400
        onTriggered: {
            blurSaveProc.command = ["sh", "-c", 'mkdir -p "$(dirname "$2")" && printf "%s" "$1" > "$2"', "sh",
                JSON.stringify({ enabled: menu.blurEnabled, strength: menu.blurStrength, live: menu.blurLive, preload: menu.blurPreload }),
                menu.blurFilePath]
            blurSaveProc.running = true
        }
    }
}
