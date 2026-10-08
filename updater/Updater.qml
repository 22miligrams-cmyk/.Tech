// Updater.qml — фоновая проверка обновлений .Tech.
//
// Что делает:
//   1. Читает локальную версию из v.version в папке шелла.
//   2. Раз в несколько часов (и один раз вскоре после старта) скачивает v.version с GitHub.
//   3. Версии совпали — молчим (ответ только на ручную проверку).
//      Не совпали — карточка «йоу, есть апдейт, хочешь установим?» с кнопками «Обновить» / «Позже»
//      (по одному разу на каждую версию) и updateAvailable = true для значка в баре.
//
// Само обновление тут не ставится: apply() открывает терминал и запускает установщик,
// он сам сравнит версии и предложит переустановить.
//
// Уведомление идёт напрямую в Notify.pushSystem(), поэтому ПРОБИВАЕТ «Не беспокоить».
// Если notify не передан — запасной вариант через notify-send (тогда DND его заглушит).
// Настройки лежат в ~/.cache/qs-updater/state.json.
//
// Управление из терминала:
//   quickshell ipc -p ~/.tech/shell call updater check     проверить прямо сейчас (ответ придёт уведомлением)
//   quickshell ipc -p ~/.tech/shell call updater status    коротко вывести текущее состояние
//   quickshell ipc -p ~/.tech/shell call updater apply     открыть терминал и запустить установщик
//   quickshell ipc -p ~/.tech/shell call updater autoOn    включить автопроверку (по умолчанию включена)
//   quickshell ipc -p ~/.tech/shell call updater autoOff   выключить автопроверку (ручной check работает всегда)
//   quickshell ipc -p ~/.tech/shell call updater autoToggle  переключить

import QtQuick
import Quickshell
import Quickshell.Io
import "../common"
import "../lang"

Item {
    id: upd
    visible: false

    // ── настройки (сохраняются в state.json) ────────────────────────────
    property bool autoCheck: true           // проверять самому, по таймеру
    property int intervalHours: 6           // как часто, в часах (1..168)

    // Notify.qml (сюда передаёт Visual.qml) — через него уведомление пробивает DND
    property var notify: null

    // откуда берём версию и установщик
    property string versionUrl: "https://raw.githubusercontent.com/22miligrams-cmyk/.Tech/main/v.version"
    property string installUrl: "https://raw.githubusercontent.com/22miligrams-cmyk/.Tech/main/install.sh"

    // ── состояние (читают бар, настройки, IPC) ──────────────────────────
    property string localVersion: ""
    property string remoteVersion: ""
    // idle — ещё не проверяли, checking — идёт запрос, latest — всё свежее,
    // available — есть новая версия, error — не удалось узнать
    property string phase: "idle"
    readonly property bool checking: phase === "checking"
    readonly property bool updateAvailable: phase === "available"
    property double lastCheck: 0            // когда проверяли в последний раз (мс)

    // Какую версию уже показывали карточкой в ЭТОМ запуске шелла (в файл не пишется):
    // после каждого старта напоминание приходит заново, пока не обновишься,
    // но по таймеру в течение одного сеанса не повторяется.
    property string sessionNotified: ""
    // оставлено только ради совместимости со старым state.json
    property string lastNotified: ""

    // true, если проверку запустил человек (тогда отвечаем уведомлением в любом случае)
    property bool manualRun: false

    readonly property string statePath: Paths.home + "/.cache/qs-updater/state.json"

    // нашлась новая версия
    signal updateFound(string localVer, string remoteVer)

    // ── тексты уведомлений ──────────────────────────────────────────────
    // Строки лежат в lang/LangRu.qml и lang/LangEn.qml (ключи upd.*), язык — тот, что выбран в настройках.

    // строка upd.<key> на языке из настроек, %1 и %2 заменяются на a и b
    function tr(key, a, b) {
        return Tr.fmt("upd." + key, [a === undefined ? "" : a, b === undefined ? "" : b])
    }

    // ── сравнение версий ────────────────────────────────────────────────
    // true, если версия a новее версии b. Версии вида "1", "1.1", "0.2.3".
    // Если в версии нет цифр (что-то нестандартное), просто считаем «не равно» = «новее».
    function isNewer(a, b) {
        a = String(a)
        b = String(b)
        if (!/\d/.test(a) || !/\d/.test(b)) return a !== b
        const pa = a.split(/[.\-]/)
        const pb = b.split(/[.\-]/)
        const n = Math.max(pa.length, pb.length)
        for (let i = 0; i < n; i++) {
            const x = i < pa.length ? (parseInt(pa[i]) || 0) : 0
            const y = i < pb.length ? (parseInt(pb[i]) || 0) : 0
            if (x !== y) return x > y
        }
        return false
    }

    // ── проверка ────────────────────────────────────────────────────────
    // manual = true: ответить уведомлением в любом случае (и «всё свежее», и «ошибка»)
    function check(manual) {
        if (checking) return
        manualRun = manual === true
        phase = "checking"
        localFile.reload()
        fetchProc.running = true
    }

    // сюда приходит ответ с GitHub (или __ERR__, если curl не справился)
    function onFetched(raw) {
        const v = String(raw).trim()
        lastCheck = Date.now()

        if (!/^[0-9A-Za-z._-]{1,32}$/.test(v) || v === "__ERR__") {
            phase = "error"
            if (manualRun) announce("info", tr("errorTitle"), tr("errorBody"))
            save()
            return
        }

        remoteVersion = v
        if (isNewer(v, localVersion)) {
            phase = "available"
            // автоматическую проверку показываем один раз за запуск шелла, ручную — всегда
            if (manualRun || v !== sessionNotified) {
                announce("update", tr("availTitle"), tr("availBody", localVersion || "?", v))
                sessionNotified = v
                lastNotified = v
            }
            updateFound(localVersion, v)
        } else {
            phase = "latest"
            if (manualRun) announce("info", tr("latestTitle"), tr("latestBody", localVersion))
        }
        save()
    }

    // короткая строка состояния для `quickshell ipc -p ~/.tech/shell call updater status`
    function statusText() {
        let st
        if (phase === "available") st = "available: " + (localVersion || "?") + " -> " + remoteVersion
        else if (phase === "latest") st = "latest: " + localVersion
        else if (phase === "checking") st = "checking"
        else if (phase === "error") st = "error: could not reach GitHub"
        else st = "idle: " + (localVersion || "?")
        return st + " | " + autoText()
    }

    // ── уведомление ─────────────────────────────────────────────────────
    // kind = "update" — карточка с кнопками, "info" — обычная. Идёт мимо DND.
    function announce(kind, title, body) {
        if (notify && typeof notify.pushSystem === "function") {
            notify.pushSystem(title, body, kind, tr("btnUpdate"), tr("btnLater"))
        } else {
            say(title, body)
        }
    }

    // запасной вариант: notify-send (DND такое глушит)
    function say(title, body) {
        if (notifyProc.running) return
        notifyProc.command = ["notify-send", "-a", ".Tech", "-i", "system-software-update", title, body]
        notifyProc.running = true
    }

    // ── обновиться: открыть терминал и запустить установщик ─────────────
    // Он сам сравнит версии и спросит, переустанавливать ли. Терминал берём из $TERMINAL,
    // иначе первый из kitty / foot / alacritty / xterm.
    function apply() {
        const script =
            'cmd=\'curl -fsSL "$1" | TECH_LANG="$3" bash; echo; printf "%s" "$2"; read -r _\'\n' +
            'for t in "${TERMINAL:-}" kitty foot alacritty xterm; do\n' +
            '  [ -n "$t" ] || continue\n' +
            '  command -v "$t" >/dev/null 2>&1 || continue\n' +
            '  exec "$t" -e bash -c "$cmd" bash "$1" "$2" "$3"\n' +
            'done\n' +
            'exit 1\n'
        applyProc.command = ["sh", "-c", script, "sh", installUrl, tr("pressEnter"), Tr.lang]
        applyProc.running = true
    }

    // ── настройки: изменить и сохранить ─────────────────────────────────
    function setAutoCheck(on) {
        autoCheck = on
        // включили — не ждём 6 часов, проверяем сразу (если ещё не проверяли)
        if (on && phase === "idle") check(false)
        save()
    }

    function autoText() {
        return "auto-check: " + (autoCheck ? "on" : "off")
    }

    function setIntervalHours(h) {
        intervalHours = Math.max(1, Math.min(168, Math.round(h)))
        save()
    }

    // пишем state.json не чаще раза в 300 мс (подряд идущие вызовы склеиваются)
    function save() {
        saveTimer.restart()
    }

    // ── внутренности ────────────────────────────────────────────────────

    // версия установленного шелла
    FileView {
        id: localFile
        path: Quickshell.shellPath("v.version")
        onLoaded: upd.localVersion = localFile.text().trim()
    }

    // сохранённые настройки
    FileView {
        id: stateFile
        path: upd.statePath
        onLoaded: {
            try {
                const j = JSON.parse(stateFile.text())
                if (typeof j.autoCheck === "boolean") upd.autoCheck = j.autoCheck
                if (typeof j.intervalHours === "number") upd.intervalHours = Math.max(1, Math.min(168, Math.round(j.intervalHours)))
                if (typeof j.lastNotified === "string") upd.lastNotified = j.lastNotified
                if (typeof j.lastCheck === "number") upd.lastCheck = j.lastCheck
            } catch (e) {
                console.warn("updater: не удалось разобрать state.json:", e)
            }
        }
    }

    // скачивает v.version с GitHub; при ошибке печатает __ERR__, чтобы ответ был всегда
    Process {
        id: fetchProc
        command: ["sh", "-c", 'curl -fsSL --max-time 10 "$1" 2>/dev/null || echo __ERR__', "sh", upd.versionUrl]
        stdout: StdioCollector {
            onStreamFinished: upd.onFetched(text)
        }
    }

    Process { id: notifyProc }
    Process {
        id: applyProc
        // терминал не нашёлся — скажем об этом, а не промолчим
        onExited: (code) => {
            if (code !== 0) upd.announce("info", upd.tr("errorTitle"), upd.tr("noTerminal"))
        }
    }
    Process { id: saveProc }

    Timer {
        id: saveTimer
        interval: 300
        onTriggered: {
            if (saveProc.running) {
                restart()
                return
            }
            const json = JSON.stringify({
                autoCheck: upd.autoCheck,
                intervalHours: upd.intervalHours,
                lastNotified: upd.lastNotified,
                lastCheck: upd.lastCheck
            })
            saveProc.command = ["sh", "-c", 'mkdir -p "$(dirname "$1")" && printf "%s" "$2" > "$1"', "sh", upd.statePath, json]
            saveProc.running = true
        }
    }

    // первая проверка — через 20 секунд после старта, когда сеть уже точно поднялась
    Timer {
        id: startDelay
        interval: 20000
        onTriggered: if (upd.autoCheck) upd.check(false)
    }

    // дальше — по расписанию
    Timer {
        interval: upd.intervalHours * 3600000
        repeat: true
        running: upd.autoCheck
        onTriggered: upd.check(false)
    }

    Component.onCompleted: startDelay.start()
}
