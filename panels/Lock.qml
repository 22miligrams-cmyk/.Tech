// Lock.qml
//
// Зачем это: экран блокировки, как Win+L в Windows.
//   Экран 1: обои с блюром, крупное время (двоеточие мигает), день недели, шкала секунд и дата.
//   Экран 2 (панель входа): слева живые виджеты CPU / RAM / Temp / Disk / GPU, в центре аватар
//            (скругление avatarRadius, по умолчанию 6) и пароль, справа плеер (MPRIS).
//            Нажми любую клавишу / кликни / крутани колесо - время уезжает вверх и уменьшается,
//            фон размывается сильнее, снизу выезжает карточка входа (аватар, пароль, кнопка,
//            сон / перезагрузка / выключение). Всё, что нажимается кнопками и Enter, срабатывает только после
//   удержания holdMs (по умолчанию 2 с): пока держишь, кнопка наполняется водой.
//   Esc на экране пароля возвращает к часам (или само вернётся через 20 сек бездействия).
//
// При блокировке делается снимок экрана (grim) вместе с окнами: на него сверху вниз накатывает
// блюр волной. При разблокировке блюр так же сходит, открывая тот же резкий кадр.
// Нужен установленный grim (без него фоном будут обои).
//
// Блокировка настоящая: ext-session-lock-v1 (WlSessionLock) + PAM (Quickshell.Services.Pam).
// Пока сессия не разблокирована, композитор не покажет ничего кроме наших поверхностей.
//
// Вызывается через IPC (так её уже дёргает кнопка-замок в ControlCenter.qml):
//   quickshell ipc -p ~/.tech/shell call lock lock
// Для Win+L добавь в конфиг композитора, например Hyprland:
//   bind = SUPER, L, exec, quickshell ipc -p ~/.tech/shell call lock lock
//
// Подключение в Visual.qml:
//   Lock { wallpaper: visualRoot.wallpaper }
//
// Если PAM не пускает правильный пароль - смени pamConfig (например на "system-auth" или "su").

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam
import Quickshell.Services.Mpris
import Quickshell.Services.UPower
import "../lang"
import "../icons"

Scope {
    id: root

    function tr(key) { return Tr.tr(key) }
    readonly property var daysFull: Tr.list("cal.daysFull")
    readonly property var monthsGen: Tr.list("cal.monthsGen")

    // ---- что приходит снаружи ----
    property var store: null              // Notify.qml: из него на экране часов берутся только имена приложений (текст уведомлений не читается)
    property string wallpaper: ""
    property bool blurEnabled: true       // false - обои без блюра, только затемнение
    property real dimAlpha: 0.45          // сила затемнения, когда blurEnabled: false
    // усреднённый (доминирующий) цвет текущих обоев: тонирует блюр и подложку затемнения.
    // Считается ниже, на Canvas 1x1 - пока не посчитан, используем акцент, чтобы не мелькало серым.
    property color wallColor: colAccent

    // эффект камеры (как в SettingsMenu): карточка входа слегка едет и наклоняется за мышкой
    property bool camEffect: true
    property real camStrength: 1.0
    property real camMoveX: 50
    property real camMoveY: 28
    property real camTilt: 3.5
    property string pamConfig: "login"
    property int holdMs: 2000             // сколько держать кнопку / Enter, чтобы сработало (мс)

    property color colBg: "#181825"
    property color colAccent: "#a3cef1"
    property color colText: "#e0e1dd"
    property color colSecondary: "#3d5a80"
    property color colDanger: "#f38ba8"
    property color colGlass: Qt.alpha(colBg, 0.6)

    // ---- аватар и виджеты ----
    property string avatar: ""            // путь к картинке; пусто = ~/.face
    property real avatarRadius: 6         // скругление аватарки
    property string tempPath: ""          // пусто = авто (hwmon k10temp / coretemp, потом thermal_zone); либо свой файл в миллиградусах

    readonly property string avatarSrc: avatar !== ""
        ? (avatar.startsWith("/") ? "file://" + avatar : avatar)
        : "file://" + Quickshell.env("HOME") + "/.face"

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"
    readonly property real cr: 6
    readonly property real coverRadius: 16   // скругление обложки плеера (кольцо cava идёт по тому же контуру)
    readonly property real pad: 16

    // ---- состояние (общее для всех мониторов) ----
    property bool locked: false       // идёт блокировка
    property bool showPrompt: false   // false - часы, true - ввод пароля
    property bool busy: false         // PAM проверяет пароль
    property bool unlocking: false    // пароль верный, играет анимация ухода
    property string errorText: ""
    property int failCount: 0
    property int shakeTick: 0         // инкремент = запустить тряску поля
    property bool showPw: false       // показать пароль открытым текстом
    property string armedAct: ""      // кнопка питания, ждущая второго нажатия
    property string hostName: ""

    readonly property string userName: Quickshell.env("USER") || "user"

    function lock() {
        if (locked || capturing) return
        showPrompt = false
        errorText = ""
        busy = false
        unlocking = false
        capturing = true

        let cmd = "mkdir -p -m 700 '" + shotDir + "' && rm -f '" + shotDir + "'/*.png; "
        for (let i = 0; i < Quickshell.screens.length; i++) {
            const n = Quickshell.screens[i].name
            cmd += "grim -o '" + n + "' '" + shotDir + "/" + n + ".png' & "
        }
        cmd += "wait"
        shotProc.command = ["sh", "-c", cmd]
        shotProc.running = true
        capTimeout.restart()
    }

    function openPrompt() { if (locked) showPrompt = true }
    function closePrompt() { showPrompt = false; errorText = ""; showPw = false; armedAct = "" }

    function submit(pw) {
        if (busy || unlocking || pw === "") return
        busy = true
        errorText = ""
        pamPassword = pw
        pam.start()
    }

    property string pamPassword: ""

    // ---- снимок рабочего стола (grim): блюр накатывает на «живой» кадр с окнами ----
    readonly property string shotDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/qs-lock"
    property bool capturing: false

    Process {
        id: shotProc
        onExited: root.engage()
    }

    // если grim завис или не установлен - всё равно блокируем (тогда фоном будут обои)
    Timer {
        id: capTimeout
        interval: 2000
        onTriggered: root.engage()
    }

    function engage() {
        if (!capturing) return
        capturing = false
        capTimeout.stop()
        locked = true
    }

    Process {
        id: cleanup
        command: ["rm", "-rf", root.shotDir]
    }

    // вызывается шторкой, когда анимация ухода дошла до конца
    function finishUnlock() {
        if (!locked) return
        locked = false
        showPrompt = false
        unlocking = false
        cleanup.running = true
    }

    // питание: перезагрузка и выключение - с подтверждением вторым нажатием
    Process { id: runner }

    Timer {
        id: armTimer
        interval: 3000
        onTriggered: root.armedAct = ""
    }

    function powerAction(id, cmd, confirm) {
        if (confirm && armedAct !== id) {
            armedAct = id
            armTimer.restart()
            return
        }
        armedAct = ""
        runner.command = cmd
        runner.running = true
    }

    Process {
        id: hostProc
        command: ["hostname"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: root.hostName = text.trim()
        }
    }

    IpcHandler {
        target: "lock"
        function lock(): void { root.lock() }
    }

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }

    // даём доиграть анимации ухода и только потом снимаем блокировку
    // запасной выход, если анимация ухода по какой-то причине не дошла до конца
    Timer {
        id: unlockTimer
        interval: 3500
        onTriggered: root.finishUnlock()
    }

    PamContext {
        id: pam
        config: root.pamConfig

        onPamMessage: {
            if (responseRequired) respond(root.pamPassword)
        }

        onCompleted: result => {
            root.pamPassword = ""
            root.busy = false
            if (result === PamResult.Success) {
                root.errorText = ""
                root.failCount = 0
                root.unlocking = true
                unlockTimer.restart()
            } else {
                root.failCount++
                root.errorText = root.tr("lock.wrongPass")
                root.shakeTick++
            }
        }

        onError: {
            root.pamPassword = ""
            root.busy = false
            root.errorText = root.tr("lock.errPam")
            root.shakeTick++
        }
    }


    // =====================================================================
    //  Живые данные для виджетов (опрос идёт только пока открыта панель входа)
    // =====================================================================
    readonly property bool sysActive: locked && showPrompt

    property string layoutCode: ""        // EN / RU / UA ...
    property string layoutName: ""        // полное имя раскладки
    property bool capsOn: false           // Caps Lock включён (Hyprland отдаёт его в hyprctl devices)

    property real cpuUse: 0
    property real ramUse: 0
    property real ramUsedGb: 0
    property real tempC: -1
    property real diskUse: 0
    property real diskUsedGb: 0
    property real diskTotalGb: 0
    property bool gpuHas: false           // видеокарта найдена и отдаёт загрузку
    property real gpuUse: 0               // 0..1
    property real gpuTemp: -1
    property real gpuVramUsed: 0          // МБ
    property real gpuVramTotal: 0         // МБ
    property var cpuPrev: null

    onSysActiveChanged: {
        if (!sysActive) { cpuPrev = null; gpuHas = false }
    }

    // ---- «откуда уведомления»: только приложения, количество и время последнего; ни заголовков, ни текста ----
    // store - Notify.qml, store.history - ListModel (uid, appName, appIcon, timeText ...), новые записи вставляются в начало
    property var notifApps: []            // [{ app, icon, count, time, hue }], сначала те, от кого пришло последним
    property int notifTotal: 0

    // "dd.MM HH:mm" -> "HH:mm" если сегодня, иначе "dd.MM"
    function shortTime(t) {
        const p = String(t || "").split(" ")
        if (p.length < 2) return String(t || "")
        return p[0] === Qt.formatDateTime(new Date(), "dd.MM") ? p[1] : p[0]
    }

    // цвет-заглушка у приложения без иконки: оттенок из имени, чтобы у одного приложения он всегда был один
    function appHue(name) {
        let h = 0
        for (let i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) % 360
        return h / 360
    }

    function refreshNotifs() {
        const hist = store ? store.history : null
        if (!hist) { notifApps = []; notifTotal = 0; return }

        const byApp = {}
        const list = []
        for (let i = 0; i < hist.count; i++) {
            const it = hist.get(i)
            const app = String(it.appName || "")
            if (app === "") continue
            if (byApp[app]) {
                byApp[app].count++
                if (byApp[app].icon === "" && it.appIcon) byApp[app].icon = String(it.appIcon)
                continue
            }
            const g = { app: app, icon: String(it.appIcon || ""), count: 1, time: shortTime(it.timeText), hue: appHue(app) }
            byApp[app] = g
            list.push(g)
        }

        // не трогаем модель, если ничего не изменилось: иначе строки пересоздавались бы зря
        if (JSON.stringify(list) !== JSON.stringify(notifApps)) notifApps = list
        notifTotal = hist.count
    }

    function gpuLine2() {
        let a = []
        if (gpuVramTotal > 0)
            a.push((gpuVramUsed / 1024).toFixed(1) + "/" + (gpuVramTotal / 1024).toFixed(gpuVramTotal >= 10240 ? 0 : 1) + "G")
        if (gpuTemp > 0) a.push(Math.round(gpuTemp) + "°")
        return a.join("  ")
    }

    function fmtTime(s) {
        s = Math.max(0, Math.floor(s))
        return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2)
    }

    function parseCpu(t) {
        const l = t.split("\n")[0].trim().split(/\s+/).slice(1).map(Number)
        if (l.length < 5) return
        const idle = l[3] + l[4]
        const total = l.slice(0, 8).reduce((a, b) => a + b, 0)
        if (cpuPrev) {
            const dt = total - cpuPrev.total
            const di = idle - cpuPrev.idle
            if (dt > 0) cpuUse = Math.max(0, Math.min(1, 1 - di / dt))
        }
        cpuPrev = { idle: idle, total: total }
    }

    function parseMem(t) {
        const tot = /MemTotal:\s+(\d+)/.exec(t)
        const av = /MemAvailable:\s+(\d+)/.exec(t)
        if (!tot || !av) return
        const total = Number(tot[1])
        const used = total - Number(av[1])
        ramUse = used / total
        ramUsedGb = used / 1048576
    }

    // файл в миллиградусах (sysfs) или уже в градусах
    function parseTemp(t) {
        const v = parseFloat(t)
        if (isNaN(v) || v <= 0) return
        tempC = v > 1000 ? v / 1000 : v
    }

    // вывод gpuScript: "загрузка% температура VRAM_used_MB VRAM_total_MB", -1 = нет данных
    function parseGpu(t) {
        const f = t.trim().split(/\s+/).map(Number)
        if (f.length < 4 || f.some(isNaN) || f[0] < 0) { gpuHas = false; return }
        gpuHas = true
        gpuUse = Math.max(0, Math.min(1, f[0] / 100))
        gpuTemp = f[1]
        gpuVramUsed = f[2]
        gpuVramTotal = f[3]
    }

    function layoutShort(name) {
        if (!name) return ""
        const n = name.toLowerCase()
        const map = {
            "english": "EN", "russian": "RU", "ukrainian": "UA", "belarusian": "BY",
            "german": "DE", "french": "FR", "spanish": "ES", "italian": "IT",
            "polish": "PL", "czech": "CZ", "turkish": "TR", "portuguese": "PT",
            "japanese": "JP", "korean": "KR", "chinese": "ZH", "arabic": "AR",
            "hebrew": "HE", "greek": "GR", "swedish": "SE", "norwegian": "NO"
        }
        for (const k in map) if (n.indexOf(k) === 0) return map[k]
        if (n === "us") return "EN"
        return name.substring(0, 2).toUpperCase()
    }

    // Hyprland: hyprctl devices -j, Sway: swaymsg -t get_inputs
    function parseLayout(t) {
        try {
            const j = JSON.parse(t)
            let name = ""
            if (j.keyboards) {
                const kb = j.keyboards.find(k => k.main) || j.keyboards[0]
                name = kb ? kb.active_keymap : ""
                capsOn = !!(kb && kb.capsLock)
            } else if (Array.isArray(j)) {
                const kb = j.find(i => i.type === "keyboard" && i.xkb_active_layout_name)
                name = kb ? kb.xkb_active_layout_name : ""
            }
            const c = layoutShort(name)
            if (c !== "") { layoutName = name; layoutCode = c }
        } catch (e) {}
    }

    Process {
        id: layoutProc
        command: ["sh", "-c", "hyprctl devices -j 2>/dev/null || swaymsg -t get_inputs -r 2>/dev/null"]
        stdout: StdioCollector { onStreamFinished: root.parseLayout(text) }
    }

    Timer {
        interval: 600
        repeat: true
        running: root.sysActive
        triggeredOnStart: true
        onTriggered: layoutProc.running = true
    }

    // список приложений пересчитываем, когда store меняется или экран блокируется
    Connections {
        target: root.store ? root.store.history : null
        ignoreUnknownSignals: true
        function onCountChanged() { root.refreshNotifs() }
    }

    Connections {
        target: root
        function onLockedChanged() { if (root.locked) root.refreshNotifs() }
        function onStoreChanged() { root.refreshNotifs() }
    }

    FileView { id: statFile; path: "/proc/stat";         onLoaded: root.parseCpu(text()) }
    FileView { id: memFile;  path: "/proc/meminfo";      onLoaded: root.parseMem(text()) }

    // температура CPU: сначала hwmon (k10temp / coretemp / zenpower), потом thermal_zone с типом cpu, потом zone0
    readonly property string tempScript:
        "for h in /sys/class/hwmon/hwmon*; do "
        + "case \"$(cat $h/name 2>/dev/null)\" in k10temp|coretemp|zenpower|cpu_thermal) "
        + "for f in $h/temp1_input $h/temp2_input; do [ -r $f ] && { cat $f; exit; }; done;; esac; done; "
        + "for z in /sys/class/thermal/thermal_zone*; do "
        + "case \"$(cat $z/type 2>/dev/null)\" in x86_pkg_temp|cpu*|soc*) cat $z/temp; exit;; esac; done; "
        + "cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null"

    Process {
        id: tempProc
        command: root.tempPath !== "" ? ["cat", root.tempPath] : ["sh", "-c", root.tempScript]
        stdout: StdioCollector { onStreamFinished: root.parseTemp(text) }
    }

    // видеокарта: AMD - sysfs, NVIDIA - nvidia-smi (только если драйвер загружен), Intel - только температура недоступна, считаем "нет данных"
    readonly property string gpuScript:
        "for c in /sys/class/drm/card[0-9]; do d=$c/device; "
        + "if [ \"$(cat $d/vendor 2>/dev/null)\" = 0x1002 ] && [ -r $d/gpu_busy_percent ]; then "
        + "u=$(cat $d/gpu_busy_percent); mu=$(cat $d/mem_info_vram_used 2>/dev/null || echo 0); "
        + "mt=$(cat $d/mem_info_vram_total 2>/dev/null || echo 0); "
        + "t=$(cat $d/hwmon/hwmon*/temp1_input 2>/dev/null | head -1); "
        + "echo \"$u $(( ${t:-0} / 1000 )) $(( mu / 1048576 )) $(( mt / 1048576 ))\"; exit; fi; done; "
        + "if [ -d /proc/driver/nvidia ] && command -v nvidia-smi >/dev/null 2>&1; then "
        + "nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ','; exit; fi; "
        + "echo '-1 -1 0 0'"

    Process {
        id: gpuProc
        command: ["sh", "-c", root.gpuScript]
        stdout: StdioCollector { onStreamFinished: root.parseGpu(text) }
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.sysActive
        triggeredOnStart: true
        onTriggered: {
            statFile.reload()
            memFile.reload()
            tempProc.running = true
            gpuProc.running = true
        }
    }

    Process {
        id: diskProc
        command: ["df", "-B1", "--output=size,used", "/"]
        stdout: StdioCollector {
            onStreamFinished: {
                const l = text.trim().split("\n")
                if (l.length < 2) return
                const f = l[1].trim().split(/\s+/)
                const size = Number(f[0]), used = Number(f[1])
                if (size > 0) {
                    root.diskUse = used / size
                    root.diskUsedGb = used / 1073741824
                    root.diskTotalGb = size / 1073741824
                }
            }
        }
    }

    Timer {
        interval: 30000
        repeat: true
        running: root.sysActive
        triggeredOnStart: true
        onTriggered: diskProc.running = true
    }

    // ---- плеер ----
    readonly property var player: {
        const l = Mpris.players.values
        for (let i = 0; i < l.length; i++) if (l[i].isPlaying) return l[i]
        return l.length > 0 ? l[0] : null
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.sysActive && root.player !== null && root.player.isPlaying
        onTriggered: root.player.positionChanged()
    }

    // ---- реальный звук для кольца вокруг обложки ----
    // тот же audio_levels.py, что использует MprisPanel.qml (по строке на кадр: числа через пробел).
    // Путь считается от этой папки; если скрипт лежит в другом месте - задай audioScript снаружи
    property string audioScript: decodeURIComponent(Qt.resolvedUrl("../panels/audio_levels.py").toString().replace(/^file:\/\//, ""))
    property var audioLv: []
    property double audioStamp: 0
    readonly property bool wantAudio: sysActive && player !== null && player.isPlaying

    onWantAudioChanged: {
        audioProc.running = wantAudio
        if (!wantAudio) audioLv = []
    }

    Process {
        id: audioProc
        command: ["python3", "-u", root.audioScript]
        stdout: SplitParser {
            onRead: line => {
                const p = line.trim().split(" ")
                const a = new Array(p.length)
                for (let i = 0; i < p.length; i++) a[i] = parseFloat(p[i]) || 0
                root.audioLv = a
                root.audioStamp = Date.now()
            }
        }
        onExited: if (root.wantAudio) audioRetry.restart()
    }

    Timer {
        id: audioRetry
        interval: 2000
        onTriggered: if (root.wantAudio) audioProc.running = true
    }

    // =====================================================================
    //  Inline-компоненты
    // =====================================================================

    // вода удержания: тот же шейдер WaterFill.frag.qsb, что и в плитках; кладётся ребёнком в кнопку
    component HoldWater: ShaderEffect {
        id: hw
        property real level: 0               // 0..1
        property bool active: false          // идёт удержание: поверхность плещется
        property color fillColor: "#a3cef1"
        property real cornerRadius: 6

        anchors.fill: parent
        visible: level > 0.002
        fragmentShader: Qt.resolvedUrl("WaterFill.frag.qsb")

        property size tileSize: Qt.size(width, height)
        property real time: 0
        property real slosh: active ? 0.25 : 0
        property real radiusPx: cornerRadius
        property real fillAlpha: 0.9
        Behavior on slosh { NumberAnimation { duration: 300 } }

        NumberAnimation on time {
            from: 0
            to: 6.283185307
            duration: 8000
            loops: Animation.Infinite
            running: hw.visible
        }
    }

    // управление удержанием: press() наливает с постоянной скоростью от текущего уровня,
    // release() быстро сливает, дошло до верха - fired() и всё сбрасывается
    component HoldCtl: Item {
        id: hc
        property real hold: 0                // 0..1
        property real duration: 4000
        readonly property bool holding: fillAnim.running
        signal fired()

        function press() {
            if (fillAnim.running) return
            drainAnim.stop()
            fillAnim.duration = Math.max(1, duration * (1 - hold))
            fillAnim.start()
        }

        function release() {
            if (!fillAnim.running) return
            fillAnim.stop()
            drainAnim.restart()
        }

        NumberAnimation {
            id: fillAnim
            target: hc
            property: "hold"
            to: 1
            easing.type: Easing.Linear
            onFinished: { hc.fired(); hc.hold = 0 }
        }

        NumberAnimation {
            id: drainAnim
            target: hc
            property: "hold"
            to: 0
            duration: 350
            easing.type: Easing.OutCubic
        }
    }

    // кольцо-эквалайзер (cava) вокруг прямоугольника со скруглёнными углами.
    // Кладётся ребёнком в Item размером с обложку: палочки растут наружу от её контура.
    component CoverRing: Item {
        id: ring

        property var lv: []                  // уровни полос от audio_levels.py
        property double stamp: 0             // когда они пришли
        property bool playing: false
        property real cornerRadius: 12
        property color color: "#a3cef1"
        property color peakColor: "#e0e1dd"

        readonly property int nBands: 20
        readonly property real gap: 3        // зазор между обложкой и палочками
        readonly property real maxLen: 8
        readonly property real minLen: 1.5
        readonly property real pitch: 6      // шаг между палочками по контуру
        readonly property real thick: 2.4

        property real level: playing ? 1.0 : 0.0
        Behavior on level { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
        visible: level > 0.01

        property var vals: new Array(20).fill(0)
        property var peaks: new Array(20).fill(0)
        property real bass: 0
        property double lastT: 0

        // точки и нормали по контуру скруглённого прямоугольника W x H (вместе с углами)
        readonly property var geo: buildGeo(width, height, Math.min(cornerRadius, Math.min(width, height) / 2))

        function buildGeo(W, H, r) {
            if (W <= 0 || H <= 0) return []
            const Lx = W - 2 * r
            const Ly = H - 2 * r
            const A = Math.PI * r / 2
            const P = 2 * Lx + 2 * Ly + 4 * A
            const n = Math.max(24, Math.round(P / pitch))
            const lens = [Lx, A, Ly, A, Lx, A, Ly, A]
            const out = []
            for (let i = 0; i < n; i++) {
                // старт с середины верхней стороны: тихий верх (высокие), низ - басы
                let s = (i * P / n + Lx / 2) % P
                let seg = 0
                while (seg < 7 && s >= lens[seg]) { s -= lens[seg]; seg++ }
                let px = 0, py = 0, nx = 0, ny = 0
                if (seg % 2 === 0) {
                    const f = Math.min(s, lens[seg])
                    if (seg === 0)      { px = r + f;     py = 0;         nx = 0;  ny = -1 }
                    else if (seg === 2) { px = W;         py = r + f;     nx = 1;  ny = 0 }
                    else if (seg === 4) { px = W - r - f; py = H;         nx = 0;  ny = 1 }
                    else                { px = 0;         py = H - r - f; nx = -1; ny = 0 }
                } else {
                    const a0 = (seg - 1) / 2 * Math.PI / 2 - Math.PI / 2
                    const a = a0 + Math.min(s / A, 1) * Math.PI / 2
                    const cx = (seg === 1 || seg === 3) ? W - r : r
                    const cy = (seg === 1 || seg === 7) ? r : H - r
                    nx = Math.cos(a)
                    ny = Math.sin(a)
                    px = cx + r * nx
                    py = cy + r * ny
                }
                out.push({
                    px: px + nx * gap,
                    py: py + ny * gap,
                    rot: Math.atan2(nx, -ny) * 180 / Math.PI,
                    u: i / n
                })
            }
            return out
        }

        // уровень для палочки: зеркально по вертикали, низ = басы, верх = высокие
        function valAt(u, vs) {
            const d = Math.min(u, 1 - u) * 2
            const f = (1 - d) * (nBands - 1)
            const i0 = Math.floor(f)
            const i1 = Math.min(nBands - 1, i0 + 1)
            const a = vs[i0] || 0
            const b = vs[i1] || 0
            const t = f - i0
            const sm = t * t * (3 - 2 * t)
            return a + (b - a) * sm
        }

        function step() {
            const now = Date.now()
            let dt = (now - lastT) / 1000
            lastT = now
            if (!(dt > 0)) dt = 0.016
            dt = Math.min(dt, 0.05)

            const fresh = (now - stamp) < 400
            const nv = new Array(nBands)
            const np = new Array(nBands)
            for (let i = 0; i < nBands; i++) {
                const cur = vals[i] || 0
                const tg = (fresh && lv && lv.length > i) ? (lv[i] || 0) : 0
                // быстрая атака, плавный спад
                const k = tg > cur ? 38 : 7
                const v = cur + (tg - cur) * Math.min(1, dt * k)
                nv[i] = v
                // пик: сразу вверх, потом плавно падает
                const pk = peaks[i] || 0
                np[i] = v >= pk ? v : Math.max(v, pk - dt * 0.55)
            }
            vals = nv
            peaks = np

            const bt = (nv[0] + nv[1] + nv[2]) / 3
            bass = bass + (bt - bass) * Math.min(1, dt * (bt > bass ? 25 : 6))
        }

        FrameAnimation {
            running: ring.visible || ring.playing
            onTriggered: ring.step()
        }

        // контур обложки подсвечивается от басов
        Rectangle {
            anchors.fill: parent
            anchors.margins: -1
            radius: ring.cornerRadius + 1
            color: "transparent"
            border.width: 1.5
            border.color: ring.color
            opacity: ring.bass * 0.7 * ring.level
            scale: 1 + ring.bass * 0.02
        }

        Repeater {
            model: ring.geo

            Item {
                id: bar
                required property var modelData
                readonly property real v: ring.valAt(modelData.u, ring.vals)
                readonly property real pv: ring.valAt(modelData.u, ring.peaks)

                x: modelData.px
                y: modelData.py
                rotation: modelData.rot

                Rectangle {
                    width: ring.thick
                    height: ring.minLen + bar.v * ring.maxLen
                    radius: width / 2
                    x: -width / 2
                    y: -height
                    color: Qt.lighter(ring.color, 1 + bar.v * 0.35)
                    opacity: (0.3 + 0.7 * bar.v) * ring.level
                }

                // удерживаемый пик
                Rectangle {
                    width: ring.thick
                    height: 1.6
                    radius: 0.8
                    x: -width / 2
                    y: -(ring.minLen + bar.pv * ring.maxLen) - 3.5
                    color: ring.peakColor
                    visible: bar.pv > bar.v + 0.05
                    opacity: Math.min(0.6, (bar.pv - bar.v) * 3) * ring.level
                }
            }
        }
    }

    // картинка со скруглением (аватар, обложка)
    component RoundImage: Item {
        id: ri
        property string source: ""
        property real cornerRadius: 6
        property color fallbackColor: "#3d5a80"
        property color glyphColor: "#a3cef1"
        property string glyph: "\uf007"
        property string iconName: ""          // если задано - вместо глифа рисуется svg из icons/
        property string fontFamily: "Monospace"
        property real glyphSize: 40
        readonly property bool ready: img.status === Image.Ready

        Rectangle {
            id: msk
            anchors.fill: parent
            radius: ri.cornerRadius
            visible: false
            layer.enabled: true
        }

        Image {
            id: img
            anchors.fill: parent
            source: ri.source
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            visible: false
            sourceSize.width: ri.width * 2
            sourceSize.height: ri.height * 2
        }

        // картинка проявляется поверх заглушки, а не выскакивает рывком
        MultiEffect {
            id: imgFx
            anchors.fill: parent
            source: img
            maskEnabled: true
            maskSource: msk
            opacity: ri.ready ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutQuad } }
        }

        Rectangle {
            anchors.fill: parent
            radius: ri.cornerRadius
            color: ri.fallbackColor
            visible: !(ri.ready && imgFx.opacity >= 1)

            Text {
                anchors.centerIn: parent
                visible: ri.iconName === ""
                text: ri.glyph
                color: ri.glyphColor
                font.pixelSize: ri.glyphSize
                font.family: ri.fontFamily
            }

            Icon {
                anchors.centerIn: parent
                visible: ri.iconName !== ""
                name: ri.iconName
                size: ri.glyphSize
                color: Qt.rgba(ri.glyphColor.r, ri.glyphColor.g, ri.glyphColor.b, 1)
                opacity: ri.glyphColor.a
            }
        }
    }

    // маска для волны: сверху вниз идёт мягкий фронт (inv - наоборот, сходит).
    // Градиент неизменный (кэшируется), по кадрам меняются только y/height прямоугольников -
    // раньше на каждом кадре пересобирались стопы градиента, отсюда были микрорывки.
    component WaveMask: Item {
        id: wm
        property real w: 0
        property bool inv: false
        property real soft: 0.14
        property real phase: 0
        property real time: 0
        property real amp: height * 0.11      // размах волны фронта (px)

        readonly property real edgeH: height * soft
        readonly property real frontY: w * height * (1 + soft)   // нижняя граница фронта, px (запасной вариант)
        readonly property real edgeY: frontY - edgeH             // верхняя граница фронта, px (запасной вариант)

        visible: false
        clip: true
        layer.enabled: true
        layer.smooth: true
        // маска - плавный градиент, ей хватает четверти разрешения (слоёв несколько, так дешевле по кадрам)
        layer.textureSize: Qt.size(Math.max(1, Math.round(width / 4)), Math.max(1, Math.round(height / 4)))

        // основной вариант: шейдер с волнистым «водяным» фронтом (WaveMask.frag.qsb)
        ShaderEffect {
            id: sh
            anchors.fill: parent
            fragmentShader: Qt.resolvedUrl("WaveMask.frag.qsb")
            onStatusChanged: {
                if (status === ShaderEffect.Error)
                    console.warn("Lock: WaveMask.frag.qsb не загрузился (" + fragmentShader + "), волна будет прямой:\n" + log)
                else if (status === ShaderEffect.Compiled)
                    console.info("Lock: WaveMask шейдер загружен")
            }

            property size maskSize: Qt.size(width, height)
            property real w: wm.w
            property real invF: wm.inv ? 1 : 0
            property real soft: wm.soft
            property real phase: wm.phase
            property real time: wm.time
            property real amp: wm.amp
        }

        // запасной вариант (если WaveMask.frag.qsb не собран): прямой фронт, как раньше.
        // Сплошная часть: сверху (блюр наезжает) или снизу (блюр сходит)
        Rectangle {
            visible: sh.status === ShaderEffect.Error
            color: "white"
            width: parent.width
            y: wm.inv ? wm.frontY : 0
            height: wm.inv ? Math.max(0, wm.height - wm.frontY) : Math.max(0, wm.edgeY)
        }

        Rectangle {
            visible: sh.status === ShaderEffect.Error
            width: parent.width
            y: wm.edgeY
            height: wm.edgeH
            gradient: Gradient {
                GradientStop { position: 0.0; color: wm.inv ? Qt.rgba(1, 1, 1, 0) : Qt.rgba(1, 1, 1, 1) }
                GradientStop { position: 1.0; color: wm.inv ? Qt.rgba(1, 1, 1, 1) : Qt.rgba(1, 1, 1, 0) }
            }
        }
    }

    // плитка-«стакан»: заливка поднимается снизу по значению
    component FillTile: Rectangle {
        id: tile
        property string icon: ""
        property string glyph: ""          // глиф из шрифта: если задан, рисуется вместо svg-иконки
        property string title: ""
        property string value: ""
        property string sub: ""
        property real fraction: 0
        property bool revealed: true
        property color fillColor: "#a3cef1"
        property color textColor: "#e0e1dd"
        property color darkColor: "#181825"
        property string fontFamily: "Monospace"
        property real cornerRadius: 6

        radius: cornerRadius
        color: Qt.alpha(textColor, 0.07)
        Behavior on fillColor { ColorAnimation { duration: 400 } }

        // сколько пикселей занимает вода (для выбора цвета подписей)
        readonly property real fillPx: water.status === ShaderEffect.Error ? fillRect.height : water.waterH

        // значение пришло - вода «плещется» сильнее тем больше, чем сильнее оно изменилось
        property real prevFraction: 0
        onFractionChanged: {
            if (revealed) water.splash(Math.min(1, 0.25 + Math.abs(fraction - prevFraction) * 8))
            prevFraction = fraction
        }
        onRevealedChanged: { if (revealed) water.splash(0.7) }

        // вода: шейдер WaterFill.frag (собери: qsb --qt6 -o WaterFill.frag.qsb WaterFill.frag)
        ShaderEffect {
            id: water
            anchors.fill: parent
            visible: level > 0.002
            fragmentShader: Qt.resolvedUrl("WaterFill.frag.qsb")
            onStatusChanged: {
                if (status === ShaderEffect.Error)
                    console.warn("Lock: WaterFill.frag.qsb не загрузился (" + fragmentShader + "), заливка будет плоской:\n" + log)
                else if (status === ShaderEffect.Compiled)
                    console.info("Lock: WaterFill шейдер загружен")
            }

            property color fillColor: Qt.alpha(tile.fillColor, 1.0)
            property size tileSize: Qt.size(width, height)
            property real level: tile.revealed
                ? Math.max(4 / Math.max(1, tile.height), Math.max(0, Math.min(1, tile.fraction))) : 0
            property real time: 0
            property real slosh: 0
            property real radiusPx: tile.cornerRadius
            property real fillAlpha: 0.88

            property real kick: 0.3
            readonly property real waterH: level * height

            // тот же ease-in-out, что и раньше: данные приходят раз в секунду, стыки без подёргиваний
            Behavior on level { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }

            // время зациклено на 2π, в шейдере все частоты целые - шва нет; идёт только пока вода видна
            NumberAnimation on time {
                from: 0
                to: 6.283185307
                duration: 8000
                loops: Animation.Infinite
                running: tile.revealed && water.visible
            }

            function splash(k) {
                kick = k
                sloshAnim.restart()
            }

            SequentialAnimation {
                id: sloshAnim
                NumberAnimation { target: water; property: "slosh"; to: water.kick; duration: 160; easing.type: Easing.OutQuad }
                NumberAnimation { target: water; property: "slosh"; to: 0; duration: 1600; easing.type: Easing.OutCubic }
            }
        }

        // запасной вариант: если WaterFill.frag.qsb не найден или не скомпилировался - плоская заливка как раньше
        Rectangle {
            id: fillRect
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: tile.revealed ? Math.max(4, parent.height * Math.max(0, Math.min(1, tile.fraction))) : 0
            radius: Math.min(tile.cornerRadius, height / 2)
            visible: water.status === ShaderEffect.Error && height > 0.5
            color: Qt.alpha(tile.fillColor, 0.88)
            // данные приходят раз в секунду: ease-in-out стартует и кончает «с нуля по скорости»,
            // поэтому перезапуск на новом значении не даёт подёргивания (OutCubic каждый раз стартовал на максимуме)
            Behavior on height { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
        }

        Icon {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: 10
            visible: tile.glyph === ""
            name: tile.icon
            size: 16
            color: tile.textColor
            opacity: 0.55
        }

        Text {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: 10
            visible: tile.glyph !== ""
            text: tile.glyph
            color: tile.textColor
            opacity: 0.55
            font.pixelSize: 16
            font.family: tile.fontFamily
        }

        Text {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 10
            text: tile.title
            color: Qt.alpha(tile.textColor, 0.8)
            font.pixelSize: 10
            font.family: tile.fontFamily
        }

        Text {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 10
            text: tile.value
            color: tile.fillPx > 36 ? tile.darkColor : tile.textColor
            font.pixelSize: 16
            font.bold: true
            font.family: tile.fontFamily
            Behavior on color { ColorAnimation { duration: 250 } }
        }

        Text {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: 10
            text: tile.sub
            color: tile.fillPx > 36 ? Qt.alpha(tile.darkColor, 0.75) : Qt.alpha(tile.textColor, 0.6)
            font.pixelSize: 9
            font.family: tile.fontFamily
            Behavior on color { ColorAnimation { duration: 250 } }
        }
    }

    WlSessionLock {
        id: sessionLock
        locked: root.locked

        WlSessionLockSurface {
            id: surf
            color: "black"

            // ---------- прогресс перехода: 0 = часы, 1 = пароль ----------
            property real prog: root.showPrompt ? 1 : 0
            Behavior on prog {
                NumberAnimation { duration: 950; easing.type: Easing.InOutCubic }
            }

            // ---------- эффект камеры: карточка входа едет/наклоняется за мышкой ----------
            HoverHandler { id: camHover }

            readonly property real camTargetX: (root.camEffect && camHover.hovered && surf.width > 0)
                ? Math.max(0, Math.min(1, camHover.point.position.x / surf.width)) * 2 - 1 : 0
            readonly property real camTargetY: (root.camEffect && camHover.hovered && surf.height > 0)
                ? Math.max(0, Math.min(1, camHover.point.position.y / surf.height)) * 2 - 1 : 0
            property real camX: camTargetX
            property real camY: camTargetY
            Behavior on camX { SmoothedAnimation { velocity: 2.2; maximumEasingTime: 300 } }
            Behavior on camY { SmoothedAnimation { velocity: 2.2; maximumEasingTime: 300 } }

            // ---------- ВОЛНА БЛЮРА ----------
            // На резком снимке рабочего стола сверху вниз проходит волна: сначала лёгкий блюр
            // (передний фронт), следом - сильный (задний). Блюр считается один раз и лежит в
            // текстуре, во время анимации двигаются только маски, поэтому плавно.
            property real wave: 0            // 0..1
            property real waveTime: 0        // 0..2π, фаза течения волн на фронте
            property bool maskInv: false     // false: блюр наезжает, true: сходит (разблокировка)
            property real contentOn: 0       // видимость часов и панели

            // Ступени блюра от лёгкого к сильному. Раньше их было две, и волна между «резким» и «лёгким»
            // просто смешивала кадр с его размытой копией - получалось матовое стекло с просвечивающей
            // чёткой картинкой, а не блюр. С несколькими близкими ступенями соседние слои почти не отличаются,
            // и фронт выглядит как реальное нарастание размытия.
            readonly property var blurLevels: [0.16, 0.36, 0.64, 1.0]

            // положение фронта ступени с номером rank (1 - идёт первой, N - последней); 0..1
            function front(rank) {
                const n = blurLevels.length
                const d = 0.22 / (n - 1)          // суммарное отставание заднего фронта от переднего (было 0.35: полоса была слишком широкой, изгиб терялся)
                return Math.max(0, Math.min(1, wave * (1 + (n - 1) * d) - (rank - 1) * d))
            }

            readonly property string shotPath: root.shotDir + "/" + (surf.screen ? surf.screen.name : "") + ".png"
            readonly property bool haveShot: shotImg.status === Image.Ready
            property var backSrc: haveShot ? shotImg : bgImg

            // фронт волны «плывёт», пока идёт анимация блокировки или разблокировки
            NumberAnimation on waveTime {
                from: 0
                to: 6.283185307
                duration: 3500
                loops: Animation.Infinite
                running: lockAnim.running || unlockAnim.running
            }

            ParallelAnimation {
                id: lockAnim

                NumberAnimation {
                    target: surf; property: "wave"
                    from: 0; to: 1
                    duration: 1700
                    easing.type: Easing.InOutQuad
                }

                SequentialAnimation {
                    PauseAnimation { duration: 650 }
                    NumberAnimation {
                        target: surf; property: "contentOn"
                        from: 0; to: 1
                        duration: 1000
                        easing.type: Easing.OutCubic
                    }
                }
            }

            SequentialAnimation {
                id: unlockAnim

                // часы и панель уезжают вниз
                NumberAnimation {
                    target: surf; property: "contentOn"
                    to: 0
                    duration: 450
                    easing.type: Easing.InCubic
                }

                // блюр сходит волной сверху вниз - в конце остаётся резкий снимок
                ScriptAction { script: { surf.maskInv = true; surf.wave = 0 } }

                NumberAnimation {
                    target: surf; property: "wave"
                    from: 0; to: 1
                    duration: 1300
                    easing.type: Easing.InOutQuad
                }

                ScriptAction { script: root.finishUnlock() }
            }

            // пауза: поверхность и текстуры блюра успевают прогреться до старта волны
            Timer {
                interval: 150
                running: true
                onTriggered: lockAnim.start()
            }

            // ВРЕМЕННАЯ ДИАГНОСТИКА мыла иконок: через 2.5 с после открытия панели пишет в лог
            // масштаб экрана и позиции иконок в окне. Потом удалить этот Timer целиком.
            Timer {
                interval: 2500
                running: root.showPrompt
                repeat: false
                onTriggered: {
                    const sc = surf.screen
                    const p1 = layoutChip.mapToItem(null, 0, 0)
                    const p2 = card.mapToItem(null, 0, 0)
                    console.log("[Lock dbg] dpr=" + (sc ? sc.devicePixelRatio : "?")
                        + " surf=" + surf.width + "x" + surf.height
                        + " card@" + p2.x + "," + p2.y
                        + " layoutChip@" + p1.x + "," + p1.y
                        + " contentOn=" + surf.contentOn + " prog=" + surf.prog)
                }
            }

            // ---------- фон ----------
            Rectangle {
                anchors.fill: parent
                gradient: Gradient {
                    GradientStop { position: 0.0; color: Qt.lighter(root.colBg, 1.4) }
                    GradientStop { position: 1.0; color: root.colBg }
                }
            }

            // снимок экрана (если grim отработал); без него - обои
            Image {
                id: shotImg
                anchors.fill: parent
                source: "file://" + surf.shotPath
                cache: false
                asynchronous: false
                fillMode: Image.PreserveAspectCrop
                visible: false
            }

            Image {
                id: bgImg
                anchors.fill: parent
                source: root.wallpaper !== "" ? (root.wallpaper.startsWith("/") ? "file://" + root.wallpaper : root.wallpaper) : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                visible: false
            }

            // усредняем обои в 1x1 пиксель (сплющиваем картинку - смешивается в средний цвет) и
            // кладём результат в root.wallColor: его используют тонировка блюра и затемнение без блюра
            Canvas {
                id: wallSampler
                width: 1
                height: 1
                visible: false

                onPaint: {
                    if (bgImg.status !== Image.Ready) return
                    const ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.drawImage(bgImg, 0, 0, width, height)
                    try {
                        const d = ctx.getImageData(0, 0, 1, 1).data
                        root.wallColor = Qt.rgba(d[0] / 255, d[1] / 255, d[2] / 255, 1)
                    } catch (e) {
                        // картинка ещё не прогрелась для чтения пикселей - оставляем прежний цвет
                    }
                }

                Connections {
                    target: bgImg
                    function onStatusChanged() { if (bgImg.status === Image.Ready) wallSampler.requestPaint() }
                }
                Component.onCompleted: if (bgImg.status === Image.Ready) wallSampler.requestPaint()
            }

            Item {
                id: bgStack
                anchors.fill: parent
                visible: surf.haveShot || bgImg.status === Image.Ready
                // лёгкий «наезд» камеры вместе с волной; в начале и в конце ровно 1.0, чтобы кадр совпадал с рабочим столом
                scale: 1.0 + 0.03 * (surf.maskInv ? 1 - surf.wave : surf.wave)

                // резкий слой
                MultiEffect {
                    anchors.fill: parent
                    source: surf.backSrc
                }

                // ступени блюра: размытые копии считаются один раз, дальше двигаются только маски.
                // При наезде первой идёт самая лёгкая ступень, при разблокировке - наоборот, первой уходит самая сильная.
                // Если блюр выключен, эти слои всё равно выйдут резкими (MultiEffect.blurEnabled: false
                // ниже) и неотличимыми друг от друга - считать их незачем, волну рисует блок ниже.
                Repeater {
                    model: root.blurEnabled ? surf.blurLevels : []

                    delegate: Item {
                        id: lvl
                        required property int index
                        required property var modelData
                        anchors.fill: parent

                        readonly property int rank: surf.maskInv ? surf.blurLevels.length - index : index + 1

                        MultiEffect {
                            id: blurred
                            anchors.fill: parent
                            visible: false
                            source: surf.backSrc
                            autoPaddingEnabled: false
                            blurEnabled: root.blurEnabled
                            blurMax: 64
                            blur: lvl.modelData
                            // тонируем блюр цветом обоев - сильнее на поздних (более размытых) ступенях
                            colorization: lvl.modelData * 0.35
                            colorizationColor: root.wallColor
                        }

                        MultiEffect {
                            anchors.fill: parent
                            source: blurred
                            maskEnabled: true
                            maskSource: waveMask
                        }

                        WaveMask {
                            id: waveMask
                            anchors.fill: parent
                            w: surf.front(lvl.rank)
                            inv: surf.maskInv
                            phase: lvl.index * 0.45
                            time: surf.waveTime
                        }
                    }
                }

                // блюр выключен: вместо наплыва размытия - та же волна, но затемнением
                // (комментарий у root.blurEnabled: "обои без блюра, только затемнение")
                Item {
                    anchors.fill: parent
                    visible: !root.blurEnabled

                    Rectangle {
                        id: dimFlat
                        anchors.fill: parent
                        color: Qt.darker(root.wallColor, 2.2)
                        visible: false
                    }

                    MultiEffect {
                        anchors.fill: parent
                        source: dimFlat
                        maskEnabled: true
                        maskSource: dimMask
                        opacity: root.dimAlpha
                    }

                    WaveMask {
                        id: dimMask
                        anchors.fill: parent
                        w: surf.wave
                        inv: surf.maskInv
                        phase: 0.3
                        time: surf.waveTime
                    }
                }
            }

            // маска появления панели: тот же водяной фронт, что и у блюра, идёт сверху вниз.
            // При уходе (unlocking) маска полностью белая - уход не меняется.
            WaveMask {
                id: uiMask
                width: surf.width
                height: surf.height
                w: root.unlocking ? 1 : surf.contentOn
                soft: 0.35
                amp: height * 0.06
                phase: 1.1
                time: surf.waveTime
            }

            // всё, что поверх фона: часы, подсказка, панель входа
            Item {
                id: ui
                width: surf.width
                height: surf.height
                // при появлении прозрачность нарастает быстро: проявление делает волна, а не общий fade
                opacity: root.unlocking ? surf.contentOn : Math.min(1, surf.contentOn * 3)
                // появляется сверху вниз, уходит вниз
                transform: Translate { y: (root.unlocking ? (1 - surf.contentOn) : (surf.contentOn - 1)) * 60 }
                layer.enabled: surf.contentOn > 0 && surf.contentOn < 1
                layer.smooth: true
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: uiMask
                }

                // ---------- ввод: клавиши / клик / колесо ----------
                Item {
                    id: keys
                    anchors.fill: parent
                    focus: true

                    Component.onCompleted: forceActiveFocus()

                    Keys.onPressed: event => {
                        idle.restart()

                        if (!root.showPrompt) {
                            if (event.key === Qt.Key_Shift || event.key === Qt.Key_Control
                                || event.key === Qt.Key_Alt || event.key === Qt.Key_Meta
                                || event.key === Qt.Key_CapsLock) return
                            root.openPrompt()
                            // печатный символ сразу попадает в поле
                            if (event.text.length > 0 && event.key !== Qt.Key_Escape
                                && event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter) {
                                pwField.text += event.text
                            }
                            event.accepted = true
                            return
                        }

                        if (event.key === Qt.Key_Escape) {
                            pwField.text = ""
                            root.closePrompt()
                            event.accepted = true
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: { if (!root.showPrompt) root.openPrompt(); else pwField.forceActiveFocus() }
                        onWheel: { if (!root.showPrompt) root.openPrompt() }
                    }
                }

                // автовозврат к часам, если ничего не вводят
                Timer {
                    id: idle
                    interval: 20000
                    running: root.showPrompt && !root.busy
                    onTriggered: { pwField.text = ""; root.closePrompt() }
                }

                // при открытии панели даём фокус полю, при закрытии - возвращаем общему обработчику
                Connections {
                    target: root
                    function onShowPromptChanged() {
                        if (root.showPrompt) Qt.callLater(() => pwField.forceActiveFocus())
                        else { pwField.text = ""; Qt.callLater(() => keys.forceActiveFocus()) }
                    }
                    function onUnlockingChanged() {
                        if (root.unlocking) { lockAnim.stop(); unlockAnim.restart() }
                    }
                    function onLockedChanged() {
                        if (root.locked) Qt.callLater(() => keys.forceActiveFocus())
                    }
                    function onShakeTickChanged() {
                        pwField.text = ""
                        shake.restart()
                        Qt.callLater(() => pwField.forceActiveFocus())
                    }
                }

                // ---------- экран 1: время ----------
                Item {
                    id: clockBlock
                    width: 520
                    height: 300
                    anchors.horizontalCenter: parent.horizontalCenter

                    // из центра экрана уезжает вверх и уменьшается
                    // (крупный текст рисуется Text.QtRendering: NativeRendering при scale мылится и «дрожит» по пикселям)
                    y: (surf.height - height) / 2 * (1 - surf.prog) + surf.height * 0.05 * surf.prog
                    scale: (1.0 - 0.42 * surf.prog)
                    transformOrigin: Item.Top

                    // день недели: капсом, с разрядкой
                    Text {
                        id: dayLbl
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 0
                        text: (root.daysFull[(clock.date.getDay() + 6) % 7] || "").toUpperCase()
                        color: root.colAccent
                        font.pixelSize: 17
                        font.bold: true
                        font.letterSpacing: 4
                        font.family: root.fontFamily
                    }

                    // время: часы и минуты, двоеточие акцентом и мигает
                    Row {
                        id: timeRow
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: 34
                        spacing: 0

                        Text {
                            text: Qt.formatDateTime(clock.date, "HH")
                            color: root.colText
                            font.pixelSize: 168
                            font.weight: Font.DemiBold
                            font.letterSpacing: -6
                            font.family: root.fontFamily
                            renderType: Text.QtRendering
                        }

                        Text {
                            id: colon
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: -12
                            text: ":"
                            color: root.colAccent
                            font.pixelSize: 150
                            font.weight: Font.Light
                            font.family: root.fontFamily
                            renderType: Text.QtRendering
                            opacity: (clock.date.getSeconds() % 2 === 0) ? 1.0 : 0.25
                            Behavior on opacity { NumberAnimation { duration: 450; easing.type: Easing.InOutSine } }
                        }

                        Text {
                            text: Qt.formatDateTime(clock.date, "mm")
                            color: root.colText
                            font.pixelSize: 168
                            font.weight: Font.DemiBold
                            font.letterSpacing: -6
                            font.family: root.fontFamily
                            renderType: Text.QtRendering
                        }
                    }

                    // тонкая шкала секунд
                    Item {
                        id: secTrack
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: timeRow.y + timeRow.height + 8
                        width: 360
                        height: 2

                        Rectangle {
                            anchors.fill: parent
                            color: Qt.alpha(root.colText, 0.16)
                        }

                        // шкала едет линейно ровно секунду; на смене минуты прыгает в ноль,
                        // а не «откатывается» назад через всю ширину, как раньше
                        Rectangle {
                            id: secFill
                            height: parent.height
                            color: root.colAccent

                            readonly property int sec: clock.date.getSeconds()
                            readonly property real goal: parent.width * (sec + 1) / 60

                            onGoalChanged: {
                                secAnim.stop()
                                if (sec === 0) width = 0
                                secAnim.to = goal
                                secAnim.start()
                            }
                            Component.onCompleted: width = goal

                            NumberAnimation {
                                id: secAnim
                                target: secFill
                                property: "width"
                                duration: 1000
                                easing.type: Easing.Linear
                            }
                        }
                    }

                    // дата
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: secTrack.y + 22
                        text: clock.date.getDate() + " " + (root.monthsGen[clock.date.getMonth()] || "") + " " + clock.date.getFullYear()
                        color: Qt.alpha(root.colText, 0.8)
                        font.pixelSize: 22
                        font.letterSpacing: 1
                        font.family: root.fontFamily
                    }
                }

                // откуда пришли уведомления: стеклянная карточка, по строке на приложение (иконка, имя, счётчик, время).
                // Содержимое уведомлений не показывается
                Rectangle {
                    id: notifCard

                    readonly property int rowH: 34
                    readonly property int headH: 30
                    // позиция считаем для экрана часов (prog = 0), чтобы карточка не прыгала вместе с часами
                    readonly property real topY: (surf.height - clockBlock.height) / 2 + clockBlock.height + 30
                    // сколько строк влезает между датой и подсказкой внизу
                    readonly property int rows: Math.max(0, Math.min(root.notifApps.length, 4,
                        Math.floor((surf.height - 110 - topY - headH - 8) / rowH)))

                    width: 250
                    height: headH + rows * rowH + 8
                    // целые координаты: иначе svg-иконки приложений мылятся
                    x: Math.round((parent.width - width) / 2)
                    y: Math.round(topY)
                    radius: root.cr
                    // приглушённо: почти прозрачная подложка, без рамки и акцентов, чтобы не спорить с часами
                    color: Qt.alpha(root.colText, 0.05)
                    opacity: Math.max(0, 1 - surf.prog * 2) * 0.85
                    visible: opacity > 0 && rows > 0

                    // шапка: колокольчик + сколько всего
                    Row {
                        x: 12
                        y: 9
                        spacing: 7

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "\uf0f3"
                            color: Qt.alpha(root.colText, 0.45)
                            font.pixelSize: 11
                            font.family: root.fontFamily
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.notifTotal
                            color: Qt.alpha(root.colText, 0.5)
                            font.pixelSize: 10
                            font.letterSpacing: 1
                            font.family: root.fontFamily
                        }
                    }

                    // тонкая линия под шапкой
                    Rectangle {
                        x: 12
                        y: notifCard.headH - 1
                        width: parent.width - 24
                        height: 1
                        color: Qt.alpha(root.colText, 0.05)
                    }

                    Column {
                        x: 0
                        y: notifCard.headH

                        Repeater {
                            model: root.notifApps.slice(0, notifCard.rows)

                            delegate: Item {
                                id: nrow
                                required property var modelData
                                width: notifCard.width
                                height: notifCard.rowH

                                // плитка приложения: иконка, а без неё - первая буква на цветной подложке
                                Rectangle {
                                    id: ntile
                                    x: 12
                                    y: 5
                                    width: 24
                                    height: 24
                                    radius: root.cr
                                    color: nicon.status === Image.Ready
                                        ? "transparent"
                                        : Qt.alpha(Qt.hsla(nrow.modelData.hue, 0.35, 0.65, 1), 0.14)

                                    Image {
                                        id: nicon
                                        anchors.centerIn: parent
                                        width: 20
                                        height: 20
                                        opacity: 0.85
                                        sourceSize.width: 40
                                        sourceSize.height: 40
                                        smooth: true
                                        source: {
                                            const ic = nrow.modelData.icon
                                            if (ic === "") return ""
                                            if (ic.startsWith("/")) return "file://" + ic
                                            if (ic.startsWith("file:") || ic.startsWith("image:")) return ic
                                            return Quickshell.iconPath(ic, true)
                                        }
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        visible: nicon.status !== Image.Ready
                                        text: nrow.modelData.app.charAt(0).toUpperCase()
                                        color: Qt.hsla(nrow.modelData.hue, 0.35, 0.78, 1)
                                        font.pixelSize: 12
                                        font.bold: true
                                        font.family: root.fontFamily
                                    }
                                }

                                // справа: счётчик (если больше одного) и время последнего
                                Row {
                                    id: nright
                                    anchors.right: parent.right
                                    anchors.rightMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 8

                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: nrow.modelData.count > 1
                                        width: Math.round(ncnt.implicitWidth + 12)
                                        height: 16
                                        radius: 8
                                        color: Qt.alpha(root.colText, 0.1)

                                        Text {
                                            id: ncnt
                                            anchors.centerIn: parent
                                            text: nrow.modelData.count
                                            color: Qt.alpha(root.colText, 0.7)
                                            font.pixelSize: 9
                                            font.bold: true
                                            font.family: root.fontFamily
                                        }
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: nrow.modelData.time
                                        color: Qt.alpha(root.colText, 0.35)
                                        font.pixelSize: 9
                                        font.family: root.fontFamily
                                    }
                                }

                                Text {
                                    x: 44
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: nright.x - 44 - 8
                                    text: nrow.modelData.app
                                    color: Qt.alpha(root.colText, 0.8)
                                    font.pixelSize: 11
                                    font.family: root.fontFamily
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }

                // подсказка на экране часов
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 48
                    spacing: 10
                    opacity: Math.max(0, 1 - surf.prog * 2)
                    visible: opacity > 0

                    Text {
                        text: "\uf023"
                        color: Qt.alpha(root.colText, 0.5)
                        font.pixelSize: 13
                        font.family: root.fontFamily
                    }

                    Text {
                        text: root.tr("lock.hint")
                        color: Qt.alpha(root.colText, 0.5)
                        font.pixelSize: 12
                        font.letterSpacing: 2
                        font.family: root.fontFamily
                    }
                }

                // ---------- экран 2: панель входа с виджетами ----------
                Rectangle {
                    id: card

                    readonly property bool compact: surf.width < 800
                    readonly property real sideW: 270

                    width: Math.min(880, surf.width - 48)
                    height: 400

                    // привязка к физическим пикселям: при дробной позиции карточки все svg-иконки внутри мылятся
                    readonly property real dpr: surf.screen ? surf.screen.devicePixelRatio : 1
                    function snap(v) { return Math.round(v * dpr) / dpr }

                    // чтобы не наезжать на уехавшие вверх часы
                    readonly property real restY: Math.max((surf.height - height) / 2 + 60, surf.height * 0.05 + 185)
                    x: snap((surf.width - width) / 2)
                    y: snap(restY + (1 - surf.prog) * 40)
                    opacity: Math.min(1, surf.prog * 1.6)
                    visible: opacity > 0.01

                    radius: root.cr
                    color: root.colGlass

                    transform: [
                        Translate {
                            x: -surf.camX * root.camMoveX * root.camStrength
                            y: -surf.camY * root.camMoveY * root.camStrength
                        },
                        Rotation {
                            origin.x: card.width / 2
                            origin.y: card.height / 2
                            axis { x: 0; y: 1; z: 0 }
                            angle: surf.camX * root.camTilt * root.camStrength
                        },
                        Rotation {
                            origin.x: card.width / 2
                            origin.y: card.height / 2
                            axis { x: 1; y: 0; z: 0 }
                            angle: -surf.camY * root.camTilt * root.camStrength
                        }
                    ]

                    // клики по панели не возвращают к часам
                    MouseArea {
                        anchors.fill: parent
                        onClicked: (mouse) => { mouse.accepted = true; pwField.forceActiveFocus() }
                    }

                    Row {
                        id: cols
                        anchors.fill: parent
                        anchors.margins: root.pad
                        spacing: 10

                        // ============ левая колонка: системные виджеты ============
                        Item {
                            width: card.sideW
                            height: parent.height
                            visible: !card.compact

                            Column {
                                anchors.fill: parent
                                spacing: 8

                                Row {
                                    width: parent.width
                                    height: (parent.height - 8) / 2
                                    spacing: 8
                                    readonly property real w3: (width - spacing * 2) / 3

                                    FillTile {
                                        width: parent.w3; height: parent.height
                                        icon: "sys"; title: "CPU"
                                        fraction: root.cpuUse
                                        revealed: root.showPrompt && surf.prog > 0.6
                                        value: Math.round(root.cpuUse * 100) + "%"
                                        fillColor: root.colAccent; textColor: root.colText; darkColor: root.colBg
                                        fontFamily: root.fontFamily; cornerRadius: root.cr
                                    }

                                    FillTile {
                                        width: parent.w3; height: parent.height
                                        icon: "ram"; title: "RAM"
                                        fraction: root.ramUse
                                        revealed: root.showPrompt && surf.prog > 0.6
                                        value: root.ramUsedGb.toFixed(1) + "G"
                                        fillColor: root.colAccent; textColor: root.colText; darkColor: root.colBg
                                        fontFamily: root.fontFamily; cornerRadius: root.cr
                                    }

                                    FillTile {
                                        width: parent.w3; height: parent.height
                                        icon: "temp"; title: "Temp"
                                        fraction: root.tempC > 0 ? root.tempC / 100 : 0
                                        revealed: root.showPrompt && surf.prog > 0.6
                                        value: root.tempC > 0 ? Math.round(root.tempC) + "°" : "—"
                                        fillColor: root.tempC > 80 ? root.colDanger : root.colAccent
                                        textColor: root.colText; darkColor: root.colBg
                                        fontFamily: root.fontFamily; cornerRadius: root.cr
                                    }
                                }

                                Row {
                                    width: parent.width
                                    height: (parent.height - 8) / 2
                                    spacing: 8
                                    readonly property real w2: (width - spacing) / 2

                                    FillTile {
                                        width: parent.w2; height: parent.height
                                        icon: "disk"; title: root.diskTotalGb.toFixed(1) + "G"
                                        fraction: root.diskUse
                                        revealed: root.showPrompt && surf.prog > 0.6
                                        value: Math.round(root.diskUse * 100) + "%"
                                        sub: root.diskUsedGb.toFixed(1) + "G"
                                        fillColor: root.diskUse > 0.9 ? root.colDanger : root.colAccent
                                        textColor: root.colText; darkColor: root.colBg
                                        fontFamily: root.fontFamily; cornerRadius: root.cr
                                    }

                                    // видеокарта: заливка «водой» по загрузке, внизу VRAM и температура
                                    FillTile {
                                        width: parent.w2; height: parent.height
                                        icon: "gpu"; title: "GPU"
                                        fraction: root.gpuHas ? root.gpuUse : 0
                                        revealed: root.showPrompt && surf.prog > 0.6
                                        value: root.gpuHas ? Math.round(root.gpuUse * 100) + "%" : "—"
                                        sub: root.gpuHas ? root.gpuLine2() : "нет данных"
                                        fillColor: root.gpuTemp > 85 ? root.colDanger : root.colAccent
                                        textColor: root.colText; darkColor: root.colBg
                                        fontFamily: root.fontFamily; cornerRadius: root.cr
                                    }
                                }
                            }
                        }

                        // ============ центр: аватар + вход ============
                        Item {
                            width: cols.width - (card.compact ? 0 : card.sideW * 2 + cols.spacing * 2)
                            height: parent.height

                            Column {
                                width: Math.min(parent.width - 16, 320)
                                x: card.snap((parent.width - width) / 2)
                                y: card.snap((parent.height - height) / 2)
                                spacing: 12

                                RoundImage {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    width: 150
                                    height: 150
                                    source: root.avatarSrc
                                    cornerRadius: root.avatarRadius
                                    fallbackColor: root.colSecondary
                                    glyphColor: root.colAccent
                                    fontFamily: root.fontFamily
                                    glyphSize: 56
                                }

                                // чип с именем пользователя
                                Rectangle {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    height: 28
                                    width: userRow.width + 24
                                    radius: root.cr
                                    color: Qt.alpha(root.colText, 0.08)

                                    Row {
                                        id: userRow
                                        anchors.centerIn: parent
                                        spacing: 8

                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: "\uf007"
                                            color: Qt.alpha(root.colText, 0.7)
                                            font.pixelSize: 11
                                            font.family: root.fontFamily
                                        }

                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: root.userName + (root.hostName !== "" ? " · " + root.hostName : "")
                                            color: root.colText
                                            font.pixelSize: 11
                                            font.family: root.fontFamily
                                        }
                                    }
                                }

                                // поле пароля
                                Item {
                                    id: fieldWrap
                                    width: parent.width
                                    height: 44

                                    property real shakeX: 0
                                    transform: Translate { x: fieldWrap.shakeX }

                                    SequentialAnimation {
                                        id: shake
                                        NumberAnimation { target: fieldWrap; property: "shakeX"; to: -12; duration: 55; easing.type: Easing.InOutSine }
                                        NumberAnimation { target: fieldWrap; property: "shakeX"; to: 12; duration: 90; easing.type: Easing.InOutSine }
                                        NumberAnimation { target: fieldWrap; property: "shakeX"; to: -8; duration: 80; easing.type: Easing.InOutSine }
                                        NumberAnimation { target: fieldWrap; property: "shakeX"; to: 4; duration: 70; easing.type: Easing.InOutSine }
                                        NumberAnimation { target: fieldWrap; property: "shakeX"; to: 0; duration: 55; easing.type: Easing.InOutSine }
                                    }

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: root.cr
                                        // без рамки: ошибка - красноватая подложка, фокус - чуть светлее
                                        color: root.errorText !== "" ? Qt.alpha(root.colDanger, 0.16)
                                            : Qt.alpha(root.colText, pwField.activeFocus ? 0.11 : 0.07)
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                    }

                                    // замок: svg padlock.svg, размер 24 - родной (обводка ровно 2 px, не мылится)
                                    Icon {
                                        id: lockIco
                                        anchors.left: parent.left
                                        anchors.leftMargin: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: "padlock"
                                        size: 24
                                        color: root.errorText !== "" ? root.colDanger
                                            : (pwField.activeFocus ? root.colAccent : root.colText)
                                        opacity: root.errorText !== "" || pwField.activeFocus ? 1.0 : 0.5
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        Behavior on opacity { NumberAnimation { duration: 150 } }
                                    }

                                    // Кубики вместо стандартных кружочков (radius 6, анимация появления и исчезновения)
                                    ListModel { id: cubeModel }

                                    Connections {
                                        target: pwField
                                        function onTextChanged() {
                                            const len = pwField.text.length
                                            let alive = 0
                                            for (let i = 0; i < cubeModel.count; i++)
                                                if (!cubeModel.get(i).dying) alive++
                                            while (alive < len) { cubeModel.append({dying: false}); alive++ }
                                            // лишние живые (с конца) помечаем на удаление; каждый кубик удаляет себя сам после анимации
                                            for (let i = cubeModel.count - 1; i >= 0 && alive > len; i--) {
                                                if (!cubeModel.get(i).dying) { cubeModel.setProperty(i, "dying", true); alive-- }
                                            }
                                        }
                                    }

                                    // окно под кубики: обрезает всё, что не влезло между замком и глазом.
                                    // Высота с запасом, чтобы овершут анимации появления не резался
                                    Item {
                                        id: cubesClip
                                        anchors.left: lockIco.right
                                        anchors.leftMargin: 10
                                        anchors.right: capsBadge.visible ? capsBadge.left : eyeBtn.left
                                        anchors.rightMargin: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        height: 28
                                        clip: true
                                        visible: !root.showPw

                                    Row {
                                        id: cubesRow
                                        // длинный пароль: лента уезжает влево, чтобы последние кубики и курсор были видны
                                        x: Math.min(0, cubesClip.width - width)
                                        Behavior on x { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 0

                                        Repeater {
                                            model: cubeModel

                                            // ячейка 16 + 5 отступа; при удалении схлопывается по ширине,
                                            // поэтому курсор сразу едет влево, а не ждёт конца анимации
                                            delegate: Item {
                                                id: cell
                                                required property int index
                                                required property bool dying
                                                width: dying ? 0 : 21
                                                height: 16
                                                Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

                                                Rectangle {
                                                    id: cube
                                                    width: 16
                                                    height: 16
                                                    radius: 6
                                                    color: root.colAccent
                                                    scale: 0
                                                }

                                                // появление: расширение с места
                                                NumberAnimation {
                                                    id: cubeAppear
                                                    target: cube; property: "scale"
                                                    to: 1.0; duration: 150
                                                    easing.type: Easing.OutBack; easing.overshoot: 1.4
                                                }

                                                // исчезновение: сжатие в точку, затем кубик убирает себя из модели
                                                NumberAnimation {
                                                    id: cubeDisappear
                                                    target: cube; property: "scale"
                                                    to: 0; duration: 120
                                                    easing.type: Easing.InBack; easing.overshoot: 1.4
                                                    onFinished: cubeModel.remove(cell.index)
                                                }

                                                Component.onCompleted: cubeAppear.start()
                                                onDyingChanged: if (dying) { cubeAppear.stop(); cubeDisappear.start() }
                                            }
                                        }

                                        // Курсор («палочка»), следующий за кубиками - горит ровно, без мигания
                                        Rectangle {
                                            id: cursorBar
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 2
                                            height: 16
                                            radius: 1
                                            color: root.colAccent
                                            visible: pwField.activeFocus && !root.busy && !root.unlocking
                                            opacity: 1
                                        }
                                    }
                                    }

                                    TextInput {
                                        id: pwField
                                        anchors.left: lockIco.right
                                        anchors.right: capsBadge.visible ? capsBadge.left : eyeBtn.left
                                        anchors.leftMargin: 10
                                        anchors.rightMargin: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        echoMode: root.showPw ? TextInput.Normal : TextInput.NoEcho
                                        // родной курсор TextInput рисуем только когда пароль виден;
                                        // иначе (NoEcho) он торчит слева и дублирует нашу «палочку» cursorBar.
                                        // cursorVisible биндить нельзя - TextInput сам его перезаписывает по фокусу,
                                        // поэтому прячем через delegate (opacity, а не visible: visible им управляет мигание)
                                        cursorDelegate: Rectangle {
                                            width: 2
                                            color: root.colAccent
                                            opacity: root.showPw ? 1 : 0
                                        }
                                        color: root.colText
                                        font.pixelSize: 13
                                        font.family: root.fontFamily
                                        enabled: !root.busy && !root.unlocking
                                        clip: true
                                        selectByMouse: false

                                        onTextChanged: { idle.restart(); if (text !== "") root.errorText = "" }

                                        // Enter, как и кнопка «войти», работает только удержанием (goHold)
                                        Keys.onPressed: event => {
                                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                                if (!event.isAutoRepeat && goBtn.ready) goHold.press()
                                                event.accepted = true
                                            }
                                        }
                                        Keys.onReleased: event => {
                                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                                if (!event.isAutoRepeat) goHold.release()
                                                event.accepted = true
                                            }
                                        }

                                        Keys.onEscapePressed: { text = ""; root.closePrompt() }

                                        Text {
                                            visible: pwField.text === "" && !root.busy
                                            anchors.left: parent.left
                                            anchors.leftMargin: pwField.activeFocus && !root.showPw ? 6 : 0
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: root.tr("lock.password")
                                            color: Qt.alpha(root.colText, 0.4)
                                            font.pixelSize: 12
                                            font.letterSpacing: 0
                                            font.family: root.fontFamily
                                        }
                                    }

                                    // предупреждение: включён Caps Lock
                                    Rectangle {
                                        id: capsBadge
                                        anchors.right: eyeBtn.left
                                        anchors.rightMargin: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: root.capsOn
                                        width: Math.round(capsTxt.implicitWidth)
                                        height: 18
                                        color: "transparent"

                                        Text {
                                            id: capsTxt
                                            anchors.centerIn: parent
                                            text: "CAPS"
                                            color: root.colDanger
                                            font.pixelSize: 10
                                            font.family: root.fontFamily
                                        }
                                    }

                                    // показать / скрыть пароль
                                    Rectangle {
                                        id: eyeBtn
                                        anchors.right: goBtn.left
                                        anchors.rightMargin: 2
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 28
                                        height: 28
                                        radius: root.cr
                                        color: Qt.alpha(root.colText, eyeMouse.containsMouse ? 0.14 : 0.0)
                                        Behavior on color { ColorAnimation { duration: 150 } }

                                        Text {
                                            anchors.centerIn: parent
                                            text: root.showPw ? "\uf070" : "\uf06e"
                                            color: root.showPw ? root.colAccent : Qt.alpha(root.colText, 0.6)
                                            font.pixelSize: 12
                                            font.family: root.fontFamily
                                        }

                                        MouseArea {
                                            id: eyeMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: { root.showPw = !root.showPw; pwField.forceActiveFocus() }
                                        }
                                    }

                                    // кнопка «войти»
                                    Rectangle {
                                        id: goBtn
                                        anchors.right: parent.right
                                        anchors.rightMargin: 5
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 34
                                        height: 34
                                        radius: root.cr
                                        readonly property bool ready: pwField.text !== "" && !root.busy
                                        color: Qt.alpha(root.colText, goMouse.containsMouse && ready ? 0.14 : 0.08)
                                        opacity: ready || root.busy ? 1.0 : 0.45

                                        HoldCtl {
                                            id: goHold
                                            duration: root.holdMs
                                            onFired: root.submit(pwField.text)
                                        }

                                        HoldWater {
                                            level: goHold.hold
                                            active: goHold.holding
                                            fillColor: root.colAccent
                                            cornerRadius: root.cr
                                        }
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        Behavior on opacity { NumberAnimation { duration: 150 } }

                                        // стрелка и спиннер - отдельные тексты: раньше глиф менялся на лету,
                                        // а повёрнутый спиннером текст оставался под случайным углом
                                        Text {
                                            anchors.centerIn: parent
                                            text: "\uf061"
                                            color: goHold.hold > 0.5 ? root.colBg : root.colAccent
                                            font.pixelSize: 13
                                            font.family: root.fontFamily
                                            opacity: root.busy ? 0 : 1
                                            Behavior on opacity { NumberAnimation { duration: 150 } }
                                        }

                                        Text {
                                            anchors.centerIn: parent
                                            text: "\uf110"
                                            color: root.colAccent
                                            font.pixelSize: 13
                                            font.family: root.fontFamily
                                            opacity: root.busy ? 1 : 0
                                            Behavior on opacity { NumberAnimation { duration: 150 } }

                                            RotationAnimator on rotation {
                                                running: root.busy
                                                loops: Animation.Infinite
                                                from: 0
                                                to: 360
                                                duration: 900
                                            }
                                        }

                                        MouseArea {
                                            id: goMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: goBtn.ready ? Qt.PointingHandCursor : Qt.ArrowCursor
                                            onPressed: { if (goBtn.ready) goHold.press() }
                                            onReleased: goHold.release()
                                            onCanceled: goHold.release()
                                        }
                                    }
                                }

                                // ошибка: место резервируем, чтобы панель не прыгала
                                Text {
                                    id: errTxt
                                    width: parent.width
                                    height: 12
                                    horizontalAlignment: Text.AlignHCenter
                                    // держим последний текст, пока он гаснет (иначе при очистке ошибки он исчезал рывком)
                                    property string kept: ""
                                    text: kept
                                    color: root.colDanger
                                    font.pixelSize: 10
                                    font.family: root.fontFamily
                                    opacity: root.errorText !== "" ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 200 } }

                                    Connections {
                                        target: root
                                        function onErrorTextChanged() { if (root.errorText !== "") errTxt.kept = root.errorText }
                                    }
                                }

                                // низ: батарея + сон / перезагрузка / выключение
                                Row {
                                    id: bottomRow
                                    // целый x: иначе чипы (и svg-иконка в них) оказываются на дробной позиции и мылятся
                                    x: card.snap((parent.width - width) / 2)
                                    spacing: 8

                                    Rectangle {
                                        id: layoutChip
                                        visible: root.layoutCode !== ""
                                        height: 30
                                        width: Math.round(layoutRow.width + 20)
                                        radius: root.cr
                                        color: Qt.alpha(root.colText, 0.08)

                                        Row {
                                            id: layoutRow
                                            // центр с округлением до целых пикселей: при дробной позиции svg-иконка мылится
                                            x: Math.round((parent.width - width) / 2)
                                            y: Math.round((parent.height - height) / 2)
                                            spacing: 4

                                            // общий Icon, акцентный цвет с dim 1.3; размер 24 - родной для svg (обводка ровно 2 px, не мылится)
                                            Icon {
                                                name: "lang"
                                                size: 24
                                                color: root.colAccent
                                                dim: 1.3
                                                anchors.verticalCenter: parent.verticalCenter
                                            }

                                            Item {
                                                width: 22
                                                height: 16
                                                anchors.verticalCenter: parent.verticalCenter

                                                Text {
                                                    text: root.layoutCode
                                                    color: root.colText
                                                    font.pixelSize: 11
                                                    font.bold: true
                                                    font.family: root.fontFamily
                                                    anchors.centerIn: parent
                                                    horizontalAlignment: Text.AlignHCenter
                                                }
                                            }
                                        }
                                    }

                                    Rectangle {
                                        id: batChip
                                        visible: UPower.displayDevice.isPresent
                                        height: 30
                                        width: Math.round(batRow.width + 20)
                                        radius: root.cr
                                        color: Qt.alpha(root.colText, 0.08)

                                        readonly property real pct: UPower.displayDevice.percentage * 100
                                        readonly property bool charging: UPower.displayDevice.state === UPowerDeviceState.Charging

                                        Row {
                                            id: batRow
                                            anchors.centerIn: parent
                                            spacing: 6

                                            Icon {
                                                anchors.verticalCenter: parent.verticalCenter
                                                name: "battery"
                                                size: 16
                                                color: batChip.charging ? root.colAccent
                                                    : (batChip.pct <= 12 ? root.colDanger : root.colText)
                                                opacity: batChip.charging || batChip.pct <= 12 ? 1.0 : 0.7
                                            }

                                            Text {
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: Math.round(batChip.pct) + "%"
                                                color: root.colText
                                                font.pixelSize: 10
                                                font.family: root.fontFamily
                                            }
                                        }
                                    }

                                    Repeater {
                                        model: [
                                            { id: "suspend",  svg: "dnd",   g: "\uf186", cmd: ["systemctl", "suspend"],  confirm: false },
                                            { id: "reboot",   svg: "",      g: "\uf021", cmd: ["systemctl", "reboot"],   confirm: true },
                                            { id: "poweroff", svg: "power", g: "\uf011", cmd: ["systemctl", "poweroff"], confirm: true }
                                        ]

                                        delegate: Rectangle {
                                            id: pbtn
                                            required property var modelData
                                            width: 36
                                            height: 30
                                            radius: root.cr
                                            color: Qt.alpha(root.colText, pMouse.containsMouse ? 0.14 : 0.08)
                                            Behavior on color { ColorAnimation { duration: 150 } }

                                            // сон, перезагрузка и выключение - только удержанием
                                            HoldCtl {
                                                id: pHold
                                                duration: root.holdMs
                                                onFired: root.powerAction(pbtn.modelData.id, pbtn.modelData.cmd, false)
                                            }

                                            HoldWater {
                                                level: pHold.hold
                                                active: pHold.holding
                                                fillColor: root.colDanger
                                                cornerRadius: root.cr
                                            }

                                            Icon {
                                                anchors.centerIn: parent
                                                visible: pbtn.modelData.svg !== ""
                                                name: pbtn.modelData.svg
                                                size: 24
                                                color: pHold.hold > 0.5 ? root.colBg : root.colText
                                                Behavior on color { ColorAnimation { duration: 200 } }
                                            }

                                            // для перезагрузки svg нет - остаётся глиф из шрифта
                                            Text {
                                                anchors.centerIn: parent
                                                visible: pbtn.modelData.svg === ""
                                                text: pbtn.modelData.g
                                                color: pHold.hold > 0.5 ? root.colBg : root.colText
                                                font.pixelSize: 13
                                                font.family: root.fontFamily
                                                Behavior on color { ColorAnimation { duration: 200 } }
                                            }

                                            MouseArea {
                                                id: pMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onPressed: pHold.press()
                                                onReleased: pHold.release()
                                                onCanceled: pHold.release()
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // ============ правая колонка: плеер ============
                        Rectangle {
                            width: card.sideW
                            height: parent.height
                            visible: !card.compact
                            radius: root.cr
                            color: Qt.alpha(root.colText, 0.07)

                            // нет плеера
                            Column {
                                anchors.centerIn: parent
                                spacing: 8
                                visible: root.player === null

                                Icon {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    name: "player"
                                    size: 32
                                    color: root.colText
                                    opacity: 0.35
                                }

                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: root.tr("lock.noMedia")
                                    color: Qt.alpha(root.colText, 0.5)
                                    font.pixelSize: 11
                                    font.family: root.fontFamily
                                }
                            }

                            // есть плеер
                            Column {
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 8
                                visible: root.player !== null

                                // обложка с кольцом-эквалайзером: палочки растут наружу от контура,
                                // поэтому вокруг оставлен запас (отступ колонки 12 > gap + maxLen)
                                Item {
                                    id: lockCover
                                    width: parent.width
                                    height: 160   // квадрат 152 + запас снизу под палочки кольца

                                    // квадратная обложка по центру (целый x, чтобы не мылилась)
                                    Item {
                                        id: coverSq
                                        width: 152
                                        height: 152
                                        x: Math.round((parent.width - width) / 2)

                                        CoverRing {
                                            anchors.fill: parent
                                            lv: root.audioLv
                                            stamp: root.audioStamp
                                            playing: root.player !== null && root.player.isPlaying
                                            cornerRadius: root.coverRadius
                                            color: root.colAccent
                                            peakColor: root.colText
                                        }

                                        RoundImage {
                                            anchors.fill: parent
                                            source: root.player ? root.player.trackArtUrl : ""
                                            cornerRadius: root.coverRadius
                                            fallbackColor: Qt.alpha(root.colText, 0.08)
                                            glyphColor: Qt.alpha(root.colText, 0.4)
                                            iconName: "player"
                                            fontFamily: root.fontFamily
                                            glyphSize: 40
                                        }
                                    }
                                }

                                Text {
                                    width: parent.width
                                    text: root.player && root.player.trackTitle !== "" ? root.player.trackTitle : root.tr("mp.untitled")
                                    color: root.colText
                                    font.pixelSize: 13
                                    font.bold: true
                                    font.family: root.fontFamily
                                    elide: Text.ElideRight
                                }

                                Text {
                                    width: parent.width
                                    text: root.player ? root.player.trackArtist : ""
                                    color: Qt.alpha(root.colText, 0.6)
                                    font.pixelSize: 10
                                    font.family: root.fontFamily
                                    elide: Text.ElideRight
                                }

                                // прогресс
                                Item {
                                    width: parent.width
                                    height: 4

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 2
                                        color: Qt.alpha(root.colText, 0.14)
                                    }

                                    Rectangle {
                                        height: parent.height
                                        radius: 2
                                        color: root.colAccent
                                        width: root.player && root.player.length > 0
                                            ? parent.width * Math.min(1, root.player.position / root.player.length) : 0
                                        Behavior on width { NumberAnimation { duration: 1000; easing.type: Easing.Linear } }
                                    }
                                }

                                Item {
                                    width: parent.width
                                    height: 12

                                    Text {
                                        anchors.left: parent.left
                                        text: root.player ? root.fmtTime(root.player.position) : "0:00"
                                        color: Qt.alpha(root.colText, 0.5)
                                        font.pixelSize: 9
                                        font.family: root.fontFamily
                                    }

                                    Text {
                                        anchors.right: parent.right
                                        text: root.player ? root.fmtTime(root.player.length) : "0:00"
                                        color: Qt.alpha(root.colText, 0.5)
                                        font.pixelSize: 9
                                        font.family: root.fontFamily
                                    }
                                }

                                Row {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    spacing: 10

                                    Rectangle {
                                        width: 34; height: 30; radius: root.cr
                                        color: Qt.alpha(root.colText, prevMouse.containsMouse ? 0.16 : 0.08)
                                        opacity: root.player && root.player.canGoPrevious ? 1 : 0.35
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        Behavior on opacity { NumberAnimation { duration: 150 } }
                                        Icon { anchors.centerIn: parent; name: "skipPrev"; size: 16; color: root.colText }
                                        MouseArea {
                                            id: prevMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: { if (root.player && root.player.canGoPrevious) root.player.previous() }
                                        }
                                    }

                                    Rectangle {
                                        width: 44; height: 30; radius: root.cr
                                        color: Qt.alpha(root.colAccent, playMouse.containsMouse ? 1.0 : 0.9)
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        Icon {
                                            anchors.centerIn: parent
                                            name: root.player && root.player.isPlaying ? "mediaPause" : "mediaPlay"
                                            size: 16
                                            color: root.colBg
                                        }
                                        MouseArea {
                                            id: playMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: { if (root.player && root.player.canTogglePlaying) root.player.togglePlaying() }
                                        }
                                    }

                                    Rectangle {
                                        width: 34; height: 30; radius: root.cr
                                        color: Qt.alpha(root.colText, nextMouse.containsMouse ? 0.16 : 0.08)
                                        opacity: root.player && root.player.canGoNext ? 1 : 0.35
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                        Behavior on opacity { NumberAnimation { duration: 150 } }
                                        Icon { anchors.centerIn: parent; name: "skipNext"; size: 16; color: root.colText }
                                        MouseArea {
                                            id: nextMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: { if (root.player && root.player.canGoNext) root.player.next() }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

            }
        }
    }
}
