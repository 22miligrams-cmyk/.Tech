// Logic.qml — «мозги» шелла, интерфейса тут нет.
// Цвета темы, часы, cpu/ram/gpu, раскладка клавиатуры, активное окно,
// звук (pipewire) и эквалайзер. Всё это потом читают Bar и Visual.

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pipewire
import "common"

Item {
    id: logic

    property string colBg: "#181825"
    property string colAccent: "#a3cef1"
    property string colText: "#e0e1dd"
    property string colSecondary: "#3d5a80"

    property real glassAlpha: 0.6
    property color colGlass: Qt.alpha(colBg, glassAlpha)

    // значения для блока статистики в баре
    property string cpuVal: "00%"
    property string ramVal: "00%"
    property string gpuVal: "N/A"
    property string langVal: "EN"


    property bool pollStats: true

    property string activeAppClass: "~ desktop"
    property string pendingAppClass: "~ desktop"
    property string displayText: "~ desktop"
    property bool isDeleting: false
    property bool isBarUnified: false

    property string barPosition: "bottom"

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }
    property var currentTime: clock.date

    property Process btMenuProc: Process { command: ["blueman-manager"] }
    property Process settingsProc: Process { command: ["pavucontrol"] }

    // поиск из бара: yt: — ютуб, tt: — тикток, всё остальное — duckduckgo
    property Process searchProc: Process {
        property string query: ""
        command: {
            let q = query.trim()
            let targetUrl = ""

            if (q.startsWith("yt:")) {
                let ytQuery = q.substring(3).trim()
                targetUrl = "https://www.youtube.com/results?search_query=" + encodeURIComponent(ytQuery)
            } else if (q.startsWith("tt:")) {
                let ttQuery = q.substring(3).trim()
                targetUrl = "https://www.tiktok.com/search/video?q=" + encodeURIComponent(ttQuery)
            } else {
                targetUrl = "https://duckduckgo.com/?q=" + encodeURIComponent(q)
            }

            return ["xdg-open", targetUrl]
        }
    }

    function pct(v) {
        v = Math.max(0, Math.min(100, Math.round(v)))
        return (v < 10 ? "0" : "") + v + "%"
    }

    FileView {
        id: colorFile
        path: Paths.home + "/.cache/quickshell/colors.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                let json = JSON.parse(colorFile.text().trim())
                if (json.bg) logic.colBg = json.bg
                if (json.accent) logic.colAccent = json.accent
                if (json.text) logic.colText = json.text
                if (json.secondary) logic.colSecondary = json.secondary
            } catch (e) {
                console.warn("colors.json: не удалось разобрать:", e)
            }
        }
    }

    property real cpuPrevTotal: 0
    property real cpuPrevIdle: 0

    FileView {
        id: statFile
        path: "/proc/stat"
        onLoaded: {
            const t = statFile.text()
            const nl = t.indexOf("\n")
            const f = (nl > 0 ? t.substring(0, nl) : t).trim().split(/\s+/)
            if (f.length < 9) return

            let total = 0
            for (let i = 1; i <= 8; i++) total += Number(f[i])

            const idle = Number(f[4]) + Number(f[5])

            const dTotal = total - logic.cpuPrevTotal
            if (logic.cpuPrevTotal > 0 && dTotal > 0)
                logic.cpuVal = logic.pct(100 * (dTotal - (idle - logic.cpuPrevIdle)) / dTotal)

            logic.cpuPrevTotal = total
            logic.cpuPrevIdle = idle
        }
    }

    FileView {
        id: memFile
        path: "/proc/meminfo"
        onLoaded: {
            const t = memFile.text()
            const total = /MemTotal:\s+(\d+)/.exec(t)
            const avail = /MemAvailable:\s+(\d+)/.exec(t)
            if (total && avail && Number(total[1]) > 0)
                logic.ramVal = logic.pct(100 * (Number(total[1]) - Number(avail[1])) / Number(total[1]))
        }
    }

    Timer {
        interval: 1000
        running: logic.pollStats
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            statFile.reload()
            memFile.reload()
        }
    }

    property int gpuAvail: -1

    property Process gpuCheck: Process {
        command: ["sh", "-c", "command -v nvidia-smi >/dev/null 2>&1 || ls /sys/class/drm/card*/device/gpu_busy_percent >/dev/null 2>&1"]
        running: true
        onExited: (exitCode, exitStatus) => {
            logic.gpuAvail = exitCode === 0 ? 1 : 0
            if (logic.gpuAvail === 1 && logic.pollStats) logic.gpuProc.running = true
        }
    }

    property Process gpuProc: Process {
        command: ["bash", "-c", 'if command -v nvidia-smi >/dev/null 2>&1; then exec stdbuf -oL nvidia-smi -i 0 --query-gpu=utilization.gpu --format=csv,noheader,nounits -l 1 2>/dev/null; fi; f=$(ls /sys/class/drm/card*/device/gpu_busy_percent 2>/dev/null | head -n1); [ -n "$f" ] || exit 1; while :; do cat "$f"; sleep 1; done']
        running: false
        stdout: SplitParser {
            onRead: data => {
                let v = parseInt(data.trim())
                if (!isNaN(v)) logic.gpuVal = logic.pct(v)
            }
        }
        onExited: {
            if (logic.pollStats && logic.gpuAvail === 1) {
                logic.gpuVal = "N/A"
                gpuRetry.restart()
            }
        }
    }

    Timer {
        id: gpuRetry
        interval: 10000
        repeat: false
        onTriggered: if (logic.pollStats && logic.gpuAvail === 1) logic.gpuProc.running = true
    }

    onPollStatsChanged: {
        gpuProc.running = pollStats && gpuAvail === 1
        if (!pollStats) {
            cpuPrevTotal = 0
            cpuPrevIdle = 0
        }
    }

    function applyLang(raw) {
        const res = String(raw).trim()
        logic.langVal = (res !== "" && res !== "N/A" && res !== "null")
            ? res.substring(0, 2).toUpperCase()
            : "EN"
    }

    // раскладка при старте; дальше её приносит событие activelayout
    property Process langProc: Process {
        command: ["bash", "-c", "hyprctl devices -j | jq -r '.keyboards[] | select(.main == true) | .active_keymap' 2>/dev/null || echo 'N/A'"]
        running: true
        stdout: SplitParser {
            onRead: data => logic.applyLang(data)
        }
    }

    // класс активного окна через hyprctl (один раз при старте), дальше ловим события hyprland
    property Process appNameProc: Process {
        command: ["bash", "-c", "OUT=$(hyprctl activewindow -j 2>/dev/null | jq -r '.class // .initialClass // empty'); echo \"${OUT:-~ desktop}\""]
        running: true
        stdout: SplitParser {
            onRead: data => logic.applyWindowClass(data)
        }
    }

    function applyWindowClass(raw) {
        let clean = String(raw).replace(/.*\./, "").trim().toLowerCase()
        let nextApp = (clean.length > 0 && clean !== "null") ? clean : "~ desktop"

        if (nextApp !== logic.pendingAppClass) {
            logic.pendingAppClass = nextApp
            logic.isDeleting = true
            typewriterTimer.restart()
        }
    }
    // слушаем hyprland: смена окна и смена раскладки
    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event.name === "activewindow") {
                logic.applyWindowClass(event.data.split(",")[0])
            } else if (event.name === "activelayout") {
                // data: "имя_клавиатуры,раскладка"
                logic.applyLang(event.data.substring(event.data.lastIndexOf(",") + 1))
            }
        }
    }

    // эффект печатной машинки: стираем старое имя окна, печатаем новое
    Timer {
        id: typewriterTimer
        interval: 30
        repeat: true
        running: false
        onTriggered: {
            if (logic.isDeleting) {
                if (logic.displayText.length > 0) {
                    logic.displayText = logic.displayText.substring(0, logic.displayText.length - 1)
                } else {
                    logic.activeAppClass = logic.pendingAppClass
                    logic.isDeleting = false
                }
            } else {
                if (logic.displayText.length < logic.activeAppClass.length) {
                    logic.displayText = logic.activeAppClass.substring(0, logic.displayText.length + 1)
                } else {
                    stop()
                }
            }
        }
    }


    // звук и эквалайзер
    readonly property var sink: Pipewire.defaultAudioSink

    readonly property var sinks: {
        const out = []
        const all = Pipewire.nodes.values
        for (let i = 0; i < all.length; i++) {
            const n = all[i]
            if (n.isSink && !n.isStream) out.push(n)
        }
        return out
    }

    readonly property var realSinks: sinks.filter(n => n.name !== eqSinkName)

    readonly property string eqSinkName: "effect_input.audio_eq"
    readonly property var eqFreqs: ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    readonly property real eqRange: 12

    readonly property var eqPresets: [
        { name: "Плоский", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] },
        { name: "Бас",     gains: [12, 11, 9, 5, 1, 0, 0, 0, 0, 0] },
        { name: "Высокие", gains: [-3, -2, -1, 0, 0, 2, 5, 8, 10, 11] },
        { name: "Голос",   gains: [-6, -5, -3, 1, 4, 7, 8, 5, 1, -2] },
        { name: "Рок",     gains: [9, 7, 4, -2, -5, -3, 3, 7, 9, 9] },
        { name: "Клуб",    gains: [11, 9, 5, 0, -4, -4, 0, 5, 9, 11] }
    ]

    readonly property bool eqOn: eqProc.running
    property var eqGains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    property string eqTarget: ""
    property string eqPendingSelect: ""
    property real eqStartedAt: 0
    property int eqFails: 0

    Component.onCompleted: loadProc.running = true

    Process {
        id: loadProc
        command: ["bash", Quickshell.shellPath("assets/audio-eq.sh"), "load"]
        stdout: StdioCollector {
            onStreamFinished: {
                const v = text.trim().split(/\s+/).map(Number)
                if (v.length === 10 && v.every(x => isFinite(x)))
                    logic.eqGains = v
                bootTimer.start()
            }
        }
    }

    Timer {
        id: bootTimer
        interval: 800
        onTriggered: if (!logic.eqOn) logic.startEq("")
    }

    Timer {
        id: retryTimer
        interval: 3000
        onTriggered: if (!logic.eqOn) logic.startEq(logic.eqTarget)
    }

    readonly property var realSink: {
        if (!eqOn) return sink
        for (let i = 0; i < realSinks.length; i++)
            if (realSinks[i].name === eqTarget) return realSinks[i]
        return null
    }

    function gainArgs() {
        return eqGains.map(v => v.toFixed(1))
    }

    function startEq(target) {
        const t = target || (sink && sink.name !== eqSinkName ? sink.name : eqTarget)
        eqTarget = t || ""
        eqStartedAt = Date.now()
        eqProc.command = ["bash", Quickshell.shellPath("assets/audio-eq.sh"), "start", eqTarget].concat(gainArgs())
        eqProc.running = true
    }

    function setGain(i, v) {
        const g = Math.max(-eqRange, Math.min(eqRange, Math.round(v * 2) / 2))
        if (eqGains[i] === g) return
        const a = eqGains.slice()
        a[i] = g
        eqGains = a
        applyTimer.restart()
    }

    function setPreset(gains) {
        eqGains = gains.slice()
        applyTimer.restart()
    }

    function selectDevice(node) {
        if (eqOn) {
            if (node.name === eqTarget) return
            eqTarget = node.name
            runSelect(node.name)
        } else {
            Pipewire.preferredDefaultAudioSink = node
        }
    }

    function runSelect(name) {
        if (selectProc.running) { eqPendingSelect = name; return }
        selectProc.command = ["bash", Quickshell.shellPath("assets/audio-eq.sh"), "select", name]
        selectProc.running = true
    }

    Process {
        id: selectProc
        running: false
        onRunningChanged: {
            if (running || logic.eqPendingSelect === "") return
            const n = logic.eqPendingSelect
            logic.eqPendingSelect = ""
            logic.runSelect(n)
        }
    }

    Process {
        id: eqProc
        running: false
        onRunningChanged: {
            if (running) return

            if (Date.now() - logic.eqStartedAt < 5000) logic.eqFails++
            else logic.eqFails = 0
            if (logic.eqFails < 5) retryTimer.start()
        }
    }

    Process {
        id: applyProc
        running: false
    }

    Timer {
        id: applyTimer
        interval: 40
        onTriggered: {
            if (!logic.eqOn) return
            if (applyProc.running) {
                restart()
                return
            }
            applyProc.command = ["bash", Quickshell.shellPath("assets/audio-eq.sh"), "apply"].concat(logic.gainArgs())
            applyProc.running = true
        }
    }
}
