// Раздел «Лаунчеры»: настройки лаунчера приложений и смены обоев (блюр, затемнение,
// интро, терминал, тип и длительность перехода, папка с обоями). Любое изменение сразу
// сохраняется через SmStore (папка обоев хранится отдельно — см. wallDir ниже).
import QtQuick
import Quickshell
import Quickshell.Io
import "../common"

Scope {
    id: root
    required property var menu

    // блюр лаунчера, 0..1
    function setLnBlur(v)  { menu.lnBlur = menu.clamp01(v); menu.storeCtl.save() }
    // затемнение лаунчера, 0..1
    function setLnTint(v)  { menu.lnTint = menu.clamp01(v); menu.storeCtl.save() }
    // анимация появления лаунчера
    function setLnIntro(v) { menu.lnIntro = v; menu.storeCtl.save() }
    // длительность перехода обоев: слайдер 0..1 переводится в 0.3..3.0 секунды
    function setWlDuration01(v) { menu.wlDuration = 0.3 + menu.clamp01(v) * 2.7; menu.storeCtl.save() }

    // следующий терминал из списка
    function cycleLnTerminal()   { menu.lnTerminal = menu.cycleList(menu.lnTerminals, menu.lnTerminal); menu.storeCtl.save() }
    // следующий эффект перехода обоев
    function cycleWlTransition() { menu.wlTransition = menu.cycleList(menu.wlTransitions, menu.wlTransition); menu.storeCtl.save() }

    // для слайдеров по клику на карточку: прыгает к следующему пресету значения (то же, что cycleBlur)
    function cyclePreset(cur, setter) {
        const presets = [0.15, 0.35, 0.55, 0.8, 1.0]
        for (let i = 0; i < presets.length; i++)
            if (presets[i] > cur + 0.01) return setter(presets[i])
        setter(presets[0])
    }

    // стрелки вверх/вниз: двигают слайдер текущей карточки, если это слайдер
    function stepItem(d) {
        const item = menu.settingsGrid.model[menu.settingsGrid.currentIndex]
        if (item && item.kind === "slider") item.setValue(item.value() + d)
    }


    // ── Папка с обоями ───────────────────────────────────────────────
    // Хранится в отдельном файле Paths.wallDirFile (одна строка с путём), чтобы не трогать SmStore.
    // wall.qml читает тот же файл при каждом открытии.
    property string wallDir: Paths.wallpapers
    property bool pickerMissing: false      // не нашли ни zenity, ни kdialog

    FileView {
        id: wallDirFile
        path: Paths.wallDirFile
        onLoaded: { const d = text().trim(); if (d !== "") root.wallDir = d }
    }

    // короткое имя папки для карточки (последний каталог, длинное обрезаем)
    function dirName(p) {
        const parts = p.replace(/\/+$/, "").split("/")
        const n = parts[parts.length - 1] || p
        return n.length > 14 ? n.slice(0, 13) + "…" : n
    }

    // Открывает системный диалог выбора папки. Меню настроек лежит на слое Overlay и закрыло бы
    // диалог, поэтому на время выбора оно прячется и потом возвращается.
    function pickWallDir() {
        if (pickerProc.running) return
        pickerMissing = false
        menu.visible = false
        pickerProc.running = true
    }

    Process {
        id: pickerProc
        // $1 — с какой папки начать, $2 — файл, куда записать результат
        command: [
            "bash", "-c",
            "d='';" +
            "if command -v zenity >/dev/null 2>&1; then " +
            "  d=$(zenity --file-selection --directory --title='Папка с обоями' --filename=\"$1/\" 2>/dev/null);" +
            "elif command -v kdialog >/dev/null 2>&1; then " +
            "  d=$(kdialog --getexistingdirectory \"$1\" 2>/dev/null);" +
            "else exit 127; fi;" +
            "d=\"${d%/}\";" +
            "if [ -n \"$d\" ] && [ -d \"$d\" ]; then " +
            "  mkdir -p \"$(dirname \"$2\")\" && printf '%s' \"$d\" > \"$2\" && printf '%s' \"$d\";" +
            "fi",
            "_", root.wallDir, Paths.wallDirFile
        ]
        stdout: StdioCollector {
            onStreamFinished: { const d = text.trim(); if (d !== "") root.wallDir = d }
        }
        onExited: (code) => {
            root.pickerMissing = (code === 127)
            root.menu.visible = true
            Qt.callLater(() => root.menu.settingsGrid.forceActiveFocus())
        }
    }


    readonly property var launcherModel: [
        { id: "ln_blur", kind: "slider", svg: "blurpx",
          get: () => true, value: () => menu.lnBlur, setValue: v => root.setLnBlur(v),
          text: () => Math.round(menu.lnBlur * 100) + "%",
          set: v => root.cyclePreset(menu.lnBlur, root.setLnBlur) },
        { id: "ln_tint", kind: "slider", svg: "alpha",
          get: () => true, value: () => menu.lnTint, setValue: v => root.setLnTint(v),
          text: () => Math.round(menu.lnTint * 100) + "%",
          set: v => root.cyclePreset(menu.lnTint, root.setLnTint) },
        { id: "ln_intro", kind: "toggle", svg: "play",
          get: () => menu.lnIntro, set: v => root.setLnIntro(v) },
        { id: "ln_term", kind: "cycle", svg: "terminal",
          get: () => true, valueText: () => menu.lnTerminal === "auto" ? menu.tr("ui.auto") + ": " + (menu.parsed.vars.terminal || "kitty") : menu.lnTerminal,
          set: v => root.cycleLnTerminal() },
        { id: "wl_tr", kind: "cycle", svg: "wallpaper",
          get: () => true, valueText: () => menu.wlTransition, set: v => root.cycleWlTransition() },
        { id: "wl_dur", kind: "slider", svg: "clock12",
          get: () => true, value: () => (menu.wlDuration - 0.3) / 2.7, setValue: v => root.setWlDuration01(v),
          text: () => menu.wlDuration.toFixed(1) + " " + menu.tr("ui.sec"),
          set: v => root.cyclePreset((menu.wlDuration - 0.3) / 2.7, root.setWlDuration01) },
        // папка с обоями: клик / Enter открывает диалог выбора папки
        { id: "wl_dir", kind: "cycle", svg: "wallpaper",
          label: "Папка обоев", hint: "клик — выбрать папку",
          get: () => true,
          valueText: () => root.pickerMissing ? "нужен zenity" : root.dirName(root.wallDir),
          set: v => root.pickWallDir() }
    ]
}
