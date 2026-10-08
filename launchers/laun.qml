// laun.qml
//
// Лаунчер приложений (оверлей на весь экран, карточки «веером» как в настройках).
// Работает как демон: запущен всегда, но окно скрыто, пока его не позовут:
//     quickshell ipc -p laun.qml call launcher toggle
//
// Что тут есть:
//   - лента карточек из DesktopEntries (категории All / App / Sys / Fav)
//   - поиск «как в Dota»: просто печатаешь, лента сама прокручивается к совпадению
//   - ↑ — меню «Запустить через…» (терминал, root, файловый менеджер, копировать, избранное)
//   - ↓ — мини-консоль (команда уходит в фон, вывод пишется в лог)
//   - блюр на карточках: берём снимок экрана при открытии и размываем кусок под карточкой
//     шейдером bar_blur.frag (скомпилированный bar_blur.frag.qsb должен лежать рядом)
//   - цвета тянем из ~/.cache/quickshell/colors.json (его пишет colors.py)
//   - настройки лежат в qs-launchers/settings.json (вкладка «Лаунчеры» в меню настроек)
//
// Если что-то ломается — сначала смотри функции openLauncher / centerGrid / launchVia.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Io


PanelWindow {
    id: root

    // ── Режим демона ─────────────────────────────────────────────────
    // Пока окно не показано: не рисуется, не снимает экран и не опрашивает файлы.
    // Показ мгновенный (см. IPC ниже).
    property bool shown: false
    visible: shown


    // Открывает лаунчер и сбрасывает всё в чистое состояние (как rofi: каждый раз с нуля)
    function openLauncher() {
        if (shown) return

        searchQuery = ""
        currentCategory = "all"
        menuOpen = false
        consoleOpen = false
        consoleText = ""
        introDone = false             // интро играет заново при каждом открытии
        captured = false              // новый снимок экрана (см. capLoader)

        settingsFile.reload()         // подхватить свежие настройки, тему и конфиг Hyprland
        colorFile.reload()
        hyprFile.reload()

        shown = true
        centerGrid()
        globalTyper.forceActiveFocus()
    }

    // Прячет лаунчер (процесс остаётся жить)
    function closeLauncher() {
        if (!shown) return
        shown = false
        menuOpen = false
        consoleOpen = false
    }

    IpcHandler {
        target: "launcher"
        function toggle(): void { root.shown ? root.closeLauncher() : root.openLauncher() }
        function show(): void { root.openLauncher() }
        function hide(): void { root.closeLauncher() }
    }

    WlrLayershell.layer: WlrLayer.Overlay
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    anchors { top: true; bottom: true; left: true; right: true }

    color: "transparent"

    // цвета по умолчанию, потом перезаписываются из colors.json
    property string colBg: "#181825"
    property string colAccent: "#a3cef1"
    property string colText: "#e0e1dd"
    property string colSecondary: "#3d5a80"


    // ── Блюр на карточках ────────────────────────────────────────────
    // Источник — снимок экрана (то, что реально лежит под лаунчером: окна, обои, бар).
    // Делается один раз при запуске, пока сам лаунчер ещё ничего не нарисовал, и замораживается.
    property real blurPx: 32            // радиус размытия
    property real tintCurrent: 0.55     // сила цветного оттенка у активной карточки
    property real tintOther: 0.35       // у остальных
    property bool captured: false       // снимок готов -> можно показывать карточки

    // Расстановка в глубину: дальние карточки стягиваются к центру плотнее
    property real depthNear: 235        // активная -> соседняя (центр-центр), px
    property real depthStep: 90         // шаг до каждой следующей; меньше = плотнее «пачка»
    property bool introDone: false      // интро прошло: новые карточки появляются сразу

    // Интро (раскрытие по очереди) играет только при открытии; дальше новые карточки
    // появляются сразу, а смена списка идёт плавной прокруткой (см. centerGrid)
    property bool introEnabled: true    // настройка «Вступительная анимация»


    // Перезапускает интро (или сразу помечает его пройденным, если оно выключено в настройках)
    function replayIntro() {
        introDone = false
        if (introEnabled) introTimer.restart()
        else introDone = true
    }

    onIntroEnabledChanged: if (!introEnabled) introDone = true
    onCapturedChanged: if (captured) replayIntro()

    Timer {
        id: introTimer
        interval: 900
        onTriggered: root.introDone = true
    }


    // Снимок экрана живёт только пока лаунчер показан: Loader создаёт его заново на каждый показ,
    // а при скрытии освобождает буфер (в фоне ни память, ни GPU не заняты)
    Loader {
        id: capLoader
        anchors.fill: parent
        active: root.shown

        sourceComponent: ScreencopyView {
            anchors.fill: parent
            captureSource: root.screen
            live: true                       // ждём первый кадр, потом замораживаем

            onHasContentChanged: {
                if (hasContent && !root.captured) {
                    live = false
                    root.captured = true
                }
            }
        }
    }
    readonly property bool hasShot: capLoader.item ? capLoader.item.hasContent : false

    // Страховка: если захват экрана недоступен — карточки всё равно показываем
    Timer {
        interval: 400
        running: root.shown
        onTriggered: root.captured = true
    }

    ShaderEffectSource {
        id: wallpaperTex                 // имя старое, чтобы не трогать карточки
        sourceItem: capLoader.item
        hideSource: true                 // сам снимок не рисуем, только как текстура
        mipmap: true                     // шейдер берёт texture(..., bias) -> нужны мипы
        smooth: true
        visible: false
    }


    // Скрытый TextInput: ловит весь ввод (в стиле Dota 2) — печатаешь, и оно сразу идёт в поиск
    TextInput {
        id: globalTyper
        focus: true
        visible: false
        onActiveFocusChanged: if (!activeFocus) forceActiveFocus()

        Keys.onPressed: (event) => {
            // пока открыто меню «Запустить через…» — все клавиши идут только ему
            if (root.menuOpen) {
                let n = root.menuItems.length
                if (event.key === Qt.Key_Escape || event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
                    root.closeMenu()
                } else if (event.key === Qt.Key_Up) {
                    root.menuIndex = (root.menuIndex - 1 + n) % n
                } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
                    root.menuIndex = (root.menuIndex + 1) % n
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.activateMenuItem(root.menuIndex)
                } else if (event.key >= Qt.Key_1 && event.key < Qt.Key_1 + n) {
                    root.activateMenuItem(event.key - Qt.Key_1)
                }
                event.accepted = true
                return
            }

            // мини-консоль: набор идёт в строку консоли, а не в поиск
            if (root.consoleOpen) {
                if (event.key === Qt.Key_Escape || event.key === Qt.Key_Up) {
                    root.closeConsole()
                    event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.runConsole()
                    event.accepted = true
                } else if (event.key === Qt.Key_Backspace) {
                    root.consoleText = root.consoleText.slice(0, -1)
                    event.accepted = true
                } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_U) {
                    root.consoleText = ""
                    event.accepted = true
                } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right ||
                           event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
                    event.accepted = true
                }
                // остальное (буквы, Ctrl+V) уходит в TextInput -> onTextChanged
                return
            }

            // обычный режим
            if (event.key === Qt.Key_Up) {
                root.openMenu()
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                root.openConsole()
                event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
                if (root.searchQuery.length > 0) root.setSearch("")
                else root.closeLauncher()
                event.accepted = true
            } else if (event.key === Qt.Key_Backspace) {
                if (root.searchQuery.length > 0) {
                    root.setSearch(root.searchQuery.slice(0, -1))
                }
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (appGrid.count > 0) {
                    let app = appGrid.model[appGrid.currentIndex]
                    if (app) {
                        app.execute()
                        root.closeLauncher()
                    }
                }
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                if (appGrid.currentIndex > 0) appGrid.currentIndex--
                event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                if (appGrid.currentIndex < appGrid.count - 1) appGrid.currentIndex++
                event.accepted = true
            }
        }

        onTextChanged: {
            if (text.length > 0 && root.consoleOpen) {
                // в консоли управляющие символы заменяем пробелами
                root.consoleText += text.replace(/[\u0000-\u001f\u007f]+/g, " ")
                text = ""
            } else if (text.length > 0) {
                let char = text[text.length - 1]
                if (char >= " ") {
                    root.setSearch(root.searchQuery + char)
                }
                text = ""
            }
        }
    }

    property string searchQuery: ""


    // ── Меню «Запустить через…» (открывается по ↑) ───────────────────
    // Файловый менеджер и терминал берутся из hyprland.lua:
    //   local terminal    = "kitty"
    //   local fileManager = "quickshell -p /путь/FileManager.qml"
    // Терминал можно переопределить в настройках (вкладка «Лаунчеры»); "auto" = как в конфиге Hyprland
    property string fileManagerCmd: ""          // пусто -> откроем папку через xdg-open
    property string hyprTerminal: "kitty"       // значение local terminal из hyprland.lua
    property string termChoice: "auto"          // выбор в настройках: auto | kitty | foot | alacritty | wezterm
    readonly property var terminalExec: termExecFor(termChoice === "auto" ? hyprTerminal : termChoice)


    // Превращает команду терминала в аргументы запуска «терминал + команда».
    // Свои флаги (kitty --class x) сохраняются, а нужный «-e» для известных терминалов добавляем сами
    function termExecFor(cmdline) {
        let t = String(cmdline || "kitty").trim().split(/\s+/)
        let base = t[0].split("/").pop()
        let flags = { alacritty: ["-e"], wezterm: ["start", "--"], "gnome-terminal": ["--"], konsole: ["-e"],
                      xterm: ["-e"], ghostty: ["-e"], kitty: [], foot: [] }
        return t.concat(flags[base] !== undefined ? flags[base] : ["-e"])
    }

    readonly property string hyprConfPath: Quickshell.env("QS_HYPR_CONF") || (Quickshell.env("HOME") + "/.config/hypr/hyprland.lua")

    // читаем из hyprland.lua строки вида  local terminal = "kitty"  и  local fileManager = "..."
    FileView {
        id: hyprFile
        path: root.hyprConfPath
        onLoaded: {
            let src = text()
            let re = /^\s*(?:local\s+)?([A-Za-z_]\w*)\s*=\s*(["'])(.*?)\2\s*(?:--.*)?$/gm
            let m
            while ((m = re.exec(src)) !== null) {
                if (m[1] === "terminal" && m[3].trim()) root.hyprTerminal = m[3].trim()
                if (m[1] === "fileManager" && m[3].trim()) root.fileManagerCmd = m[3].trim()
            }
        }
    }

    property bool menuOpen: false
    property int menuIndex: 0
    property var menuApp: null

    readonly property var menuItems: [
        { id: "normal", icon: "\uf04b", label: "Обычный запуск",       hint: "как Enter" },
        { id: "fm",     icon: "\uf07b", label: "Файловый менеджер",    hint: "папка с .desktop / бинарником" },
        { id: "term",   icon: "\uf120", label: "Консоль (отладка)",    hint: "вывод и ошибки видны" },
        { id: "root",   icon: "\uf023", label: "От имени root",        hint: "через pkexec" },
        { id: "copy",   icon: "\uf0c5", label: "Скопировать команду",  hint: "в буфер обмена" },
        { id: "fav",    icon: "\uf005", label: "Добавить в избранное", hint: "" }
    ]
    // высота «продолжения» карточки: 6 строк по 36 + отступы
    readonly property real menuExtra: 236


    // ── Мини-консоль (открывается по ↓): команда запускается в фоне ──
    property bool consoleOpen: false
    property string consoleText: ""


    // Открывает мини-консоль (меню при этом закрываем)
    function openConsole() {
        closeMenu()
        consoleOpen = true
    }

    // Закрывает мини-консоль
    function closeConsole() {
        consoleOpen = false
    }

    // Запускает введённую команду отвязанно от лаунчера; вывод и ошибки пишет в
    // ~/.cache/launcher-console.log, чтобы потом можно было посмотреть что вышло
    function runConsole() {
        let c = consoleText.trim()
        if (c === "") return

        let script =
            'log="${XDG_CACHE_HOME:-$HOME/.cache}/launcher-console.log";' +
            'mkdir -p "$(dirname "$log")";' +
            'printf "\n$ %s\n" "$1" >> "$log";' +
            'exec sh -c "$1" >> "$log" 2>&1'
        Quickshell.execDetached(["sh", "-c", script, "sh", c])
        root.closeLauncher()
    }

    // Открывает меню «Запустить через…» для выбранной карточки
    function openMenu() {
        if (appGrid.count <= 0 || appGrid.currentIndex < 0) return
        consoleOpen = false
        menuApp = appGrid.model[appGrid.currentIndex]
        if (!menuApp) return
        menuIndex = 0
        menuOpen = true
    }

    // Закрывает меню
    function closeMenu() {
        menuOpen = false
    }

    // Запускает приложение выбранным способом: normal / fm / term / root / copy.
    // Для всех, кроме normal, берём голую команду приложения (app.command) и работаем с ней сами
    function launchVia(mode, app) {
        if (!app) return
        let cmd = app.command ? Array.from(app.command) : []
        let wd = app.workingDirectory ? app.workingDirectory : ""

        if (mode === "normal" || cmd.length === 0) {
            app.execute()

        } else if (mode === "fm") {
            // Ищем .desktop-файл приложения, если нет — папку с бинарником.
            // Путь отдаём файловому менеджеру через переменную FM_PATH.
            let script =
                'id="$1"; bin="$2"; t="";' +
                'for d in "$HOME/.local/share/applications" /usr/local/share/applications /usr/share/applications ' +
                '/var/lib/flatpak/exports/share/applications "$HOME/.local/share/flatpak/exports/share/applications"; do ' +
                '[ -f "$d/$id.desktop" ] && { t="$d"; break; }; done;' +
                'if [ -z "$t" ]; then p=$(command -v "$bin"); [ -n "$p" ] && t=$(dirname "$(readlink -f "$p")"); fi;' +
                '[ -z "$t" ] && t="$HOME";' +
                'export FM_PATH="$t"; exec ' + (root.fileManagerCmd || 'xdg-open "$t"')
            Quickshell.execDetached(["sh", "-c", script, "sh", app.id ? app.id : "", cmd[0]])

        } else if (mode === "term") {
            // В терминале; после выхода показываем код возврата и оставляем шелл открытым
            let script =
                'wd="$1"; shift; [ -n "$wd" ] && cd "$wd";' +
                '"$@"; code=$?; printf "\\n── exit code: %s ──\\n" "$code"; exec "${SHELL:-sh}"'
            Quickshell.execDetached(root.terminalExec.concat(["sh", "-c", script, "sh", wd].concat(cmd)))

        } else if (mode === "root") {
            let script =
                'wd="$1"; shift; [ -n "$wd" ] && cd "$wd";' +
                'exec pkexec env WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DISPLAY="$DISPLAY" "$@"'
            Quickshell.execDetached(["sh", "-c", script, "sh", wd].concat(cmd))

        } else if (mode === "copy") {
            Quickshell.execDetached(["sh", "-c", 'printf %s "$1" | wl-copy', "sh", cmd.join(" ")])
        }
    }

    // Выполняет пункт меню по номеру. «Избранное» — исключение: переключаем и остаёмся в лаунчере,
    // все остальные запускают приложение и закрывают лаунчер
    function activateMenuItem(i) {
        let app = menuApp
        let item = menuItems[i]
        closeMenu()
        if (!app || !item) return

        if (item.id === "fav") {
            toggleFav(app)
            return
        }
        launchVia(item.id, app)
        root.closeLauncher()
    }


    // ── Избранное ────────────────────────────────────────────────────
    property var favorites: []            // id приложений (имена .desktop-файлов)


    // Приложение в избранном?
    function isFav(app) {
        return !!app && !!app.id && favorites.indexOf(app.id) >= 0
    }

    // Пишет список избранного на диск (через sh, чтобы заодно создать папку)
    function saveFavorites() {
        Quickshell.execDetached(["sh", "-c",
            'mkdir -p "$(dirname "$2")"; printf %s "$1" > "$2"',
            "sh", JSON.stringify(favorites), favFile.path])
    }

    // Добавляет/убирает приложение из избранного. Если мы сейчас во вкладке Fav — список поменяется,
    // поэтому позицию запоминаем заранее и потом центрируем ленту заново
    function toggleFav(app) {
        if (!app || !app.id) return
        if (currentCategory === "fav") rememberCurrent()

        let list = favorites.slice()
        let i = list.indexOf(app.id)
        if (i >= 0) list.splice(i, 1)
        else list.push(app.id)

        favorites = list
        saveFavorites()
        if (currentCategory === "fav") centerGrid()
    }

    FileView {
        id: favFile
        path: Quickshell.env("HOME") + "/.local/share/launcher/favorites.json"
        onLoaded: {
            try {
                let a = JSON.parse(text().trim())
                if (Array.isArray(a)) root.favorites = a
            } catch(e) {}
        }
    }


    // Разбирает colors.json (его пишет colors.py) и применяет цвета темы
    function applyColors(raw) {
        try {
            let json = JSON.parse(raw.trim())
            if (json.bg) root.colBg = json.bg
            if (json.accent) root.colAccent = json.accent
            if (json.text) root.colText = json.text
            if (json.secondary) root.colSecondary = json.secondary
        } catch(e) {}
    }


    // ── Настройки из меню настроек (вкладка «Лаунчеры») ──────────────
    readonly property string settingsPath: (Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")) + "/qs-launchers/settings.json"

    FileView {
        id: settingsFile
        path: root.settingsPath
        onLoaded: {
            try {
                let l = (JSON.parse(text().trim()).laun) || {}
                if (typeof l.blur === "number") root.blurPx = 4 + Math.max(0, Math.min(1, l.blur)) * 56
                if (typeof l.tint === "number") {
                    root.tintCurrent = Math.max(0, Math.min(1, l.tint))
                    root.tintOther = Math.max(0, root.tintCurrent - 0.2)
                }
                if (typeof l.intro === "boolean") root.introEnabled = l.intro
                if (typeof l.terminal === "string" && l.terminal) root.termChoice = l.terminal
            } catch (e) {}
        }
    }

    FileView {
        id: colorFile
        path: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/quickshell/colors.json"
        onLoaded: root.applyColors(text())
    }

    // пока лаунчер открыт — раз в секунду перечитываем тему (вдруг сменили обои)
    Timer {
        interval: 1000
        running: root.shown
        repeat: true
        triggeredOnStart: true
        onTriggered: colorFile.reload()
    }

    property string currentCategory: "all"


    // ── Поиск / смена категории: плавная прокрутка к нужной карточке ──
    // Список пересобирается, но лента не должна «улетать»: сначала мгновенно встаём туда,
    // где была прежняя активная карточка (или ближайшая к её месту), потом плавно
    // едем к середине нового списка.
    property var prevApp: null
    property int prevIdx: -1
    property int pendingTarget: 0


    // Запоминает текущую карточку (и её индекс) перед сменой списка
    function rememberCurrent() {
        prevIdx = appGrid.currentIndex
        prevApp = (appGrid.count > 0 && appGrid.currentIndex >= 0) ? appGrid.model[appGrid.currentIndex] : null
    }

    // Ищет лучшее совпадение по всему списку: имя начинается с запроса (3) > содержит (2) > описание (1).
    // Возвращает индекс или -1
    function findMatch(q) {
        let query = q.trim().toLowerCase()
        if (!query) return -1

        let m = appGrid.model
        let best = -1, bestScore = 0
        for (let i = 0; i < m.length; i++) {
            let app = m[i]
            if (!app) continue
            let name = app.name ? app.name.toLowerCase() : ""
            let comment = (app.genericName || app.comment || "").toLowerCase()
            let score = name.startsWith(query) ? 3 : name.includes(query) ? 2 : comment.includes(query) ? 1 : 0
            if (score > bestScore) { best = i; bestScore = score; if (score === 3) break }
        }
        return best
    }

    // Меняет запрос и прокручивает ленту к лучшему совпадению (список при этом не фильтруется)
    function setSearch(q) {
        searchQuery = q
        let i = findMatch(q)
        if (i >= 0) scrollTo(i)
    }

    // Плавно доезжает до карточки «быстрой круткой»: ~10 коротких шагов независимо от расстояния.
    // Карточки по пути не пропадают — лента проходит через них как при обычной прокрутке
    property int pendingStep: 1
    function scrollTo(target) {
        let n = appGrid.count
        if (target < 0 || target >= n) return
        pendingTarget = target
        pendingStep = Math.max(1, Math.ceil(Math.abs(target - appGrid.currentIndex) / 10))
        if (!scrollTimer.running) scrollTimer.start()
    }

    // Центрирует ленту после смены списка: мгновенно встаём на прежнее место, потом плавно к середине
    function centerGrid() {
        Qt.callLater(() => {
            let n = appGrid.count
            if (n <= 0) return

            let start = prevApp ? appGrid.model.indexOf(prevApp) : -1
            if (start < 0) start = prevIdx >= 0 ? Math.min(prevIdx, n - 1) : Math.floor(n / 2)
            prevApp = null
            prevIdx = -1

            appGrid.highlightMoveDuration = 0      // мгновенно встаём на стартовую карточку
            appGrid.currentIndex = start
            scrollTo(Math.floor(n / 2))
        })
    }

    Timer {
        id: scrollTimer
        interval: 40
        repeat: true
        onTriggered: {
            let d = root.pendingTarget - appGrid.currentIndex
            if (d === 0) {
                stop()
                restoreMoveTimer.interval = 180
                restoreMoveTimer.restart()
                return
            }
            appGrid.highlightMoveDuration = 150
            let step = Math.min(root.pendingStep, Math.abs(d))
            appGrid.currentIndex += d > 0 ? step : -step
        }
    }
    Timer {
        id: restoreMoveTimer
        onTriggered: appGrid.highlightMoveDuration = 100
    }

    Component.onCompleted: {
        centerGrid()
        globalTyper.forceActiveFocus()
        // холодный старт из бинда (демон ещё не запущен): сразу показываемся
        if (Quickshell.env("QS_LAUNCHER_SHOW") === "1") openLauncher()
    }


    // Крупный полупрозрачный текст поиска с «поп-ап» анимацией
    Text {
        id: searchTextElem
        anchors.centerIn: parent
        z: 100
        text: root.searchQuery
        color: root.colText
        font.pixelSize: 52
        font.bold: true
        font.family: "JetBrainsMono Nerd Font, Monospace"
        visible: root.searchQuery.length > 0

        scale: 1.0
        opacity: visible ? 0.6 : 0.0

        Behavior on opacity { NumberAnimation { duration: 150 } }

        onTextChanged: scaleAnim.restart()

        NumberAnimation {
            id: scaleAnim
            target: searchTextElem
            property: "scale"
            from: 0.8
            to: 1.0
            duration: 200
            easing.type: Easing.OutBack
        }
    }


    ColumnLayout {
        id: mainCol
        anchors.centerIn: parent
        width: root.width
        spacing: 35

        // Сверху — только переключатель категорий
        RowLayout {
            Layout.alignment: Qt.AlignHCenter

            Rectangle {
                height: 48
                width: 290
                radius: 12
                color: root.colBg
                border.width: 0

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 4
                    spacing: 2

                    Repeater {
                        model: [
                            { id: "all", label: "All" },
                            { id: "app", label: "App" },
                            { id: "sys", label: "Sys" },
                            { id: "fav", label: "Fav" }
                        ]

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            radius: 8
                            color: root.currentCategory === modelData.id ? root.colSecondary : "transparent"

                            Text {
                                anchors.centerIn: parent
                                text: modelData.label
                                font.pixelSize: 13
                                font.bold: true
                                font.family: "JetBrainsMono Nerd Font, Monospace"
                                color: root.currentCategory === modelData.id ? root.colText : root.colSecondary
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.rememberCurrent()
                                    root.currentCategory = modelData.id
                                    root.centerGrid()
                                    globalTyper.forceActiveFocus()
                                }
                            }
                        }
                    }
                }
            }
        }


        // ============ Лента карточек ============
        ListView {
            id: appGrid
            Layout.fillWidth: true
            height: 440
            orientation: ListView.Horizontal
            spacing: 0
            clip: false

            cacheBuffer: Math.max(1600, count * 270)    // создаём все карточки заранее (в фоне, по одной)

            preferredHighlightBegin: width / 2 - 145
            preferredHighlightEnd: width / 2 + 145
            highlightRangeMode: ListView.StrictlyEnforceRange
            highlightMoveDuration: 100

            // Список приложений с учётом категории. Поиск ничего не скрывает,
            // он только прокручивает ленту к совпадению
            model: {
                let apps = DesktopEntries.applications.values;
                if (!apps) return [];

                return apps.filter(app => {
                    if (!app) return false;

                    let name = app.name ? app.name.toLowerCase() : "";
                    let comment = (app.genericName || app.comment || "").toLowerCase();
                    let categories = app.categories ? app.categories.join(" ").toLowerCase() : "";

                    let matchesSearch = true;

                    let isSys = categories.includes("system") || categories.includes("settings") || categories.includes("terminal");
                    let matchesCategory = true;

                    if (root.currentCategory === "sys") {
                        matchesCategory = isSys;
                    } else if (root.currentCategory === "app") {
                        matchesCategory = !isSys;
                    } else if (root.currentCategory === "fav") {
                        matchesCategory = root.favorites.indexOf(app.id) >= 0;
                    }

                    return matchesSearch && matchesCategory;
                });
            }

            delegate: Item {
                id: cardDelegate
                required property var modelData
                required property int index

                width: index === appGrid.currentIndex ? 290 : 260
                height: 420
                z: index === appGrid.currentIndex ? 100 : 50 - Math.abs(index - appGrid.currentIndex)

                Behavior on width { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

                Item {
                    id: cardContainer
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.horizontalCenterOffset: depthX
                    anchors.verticalCenter: parent.verticalCenter
                    width: 260

                    // «продолжение»: активная карточка сама вытягивается вниз, когда открыто меню
                    property real extra: (isCurrent && root.menuOpen) ? root.menuExtra : 0
                    Behavior on extra { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                    height: 380 + extra

                    property bool isCurrent: index === appGrid.currentIndex
                    // «глубина» карточки: 0 — активная, дальше — больше
                    property int dist: Math.abs(index - appGrid.currentIndex)
                    property bool staggerDone: false           // личный таймер каскада; сбрасывается на каждое открытие
                    property bool timerDone: root.introDone || staggerDone    // созданные при прокрутке сразу готовы (introDone)
                    property bool ready: timerDone && root.captured

                    // Где карточка лежит на экране (0..1) — именно этот кусок снимка и размываем.
                    // Угол и масштаб учитываются через mapToItem; перечисленные свойства нужны,
                    // чтобы биндинг пересчитывался при прокрутке и анимациях.
                    property rect srcRect: {
                        appGrid.contentX; appGrid.x; appGrid.y; appGrid.width;
                        cardDelegate.x; cardDelegate.width;
                        scale; x; y; depthX; rotAngle; root.width; root.height;
                        if (dist > 3) return Qt.rect(0, 0, 1, 1);    // дальним блюр не нужен — не считаем
                        let p0 = cardContainer.mapToItem(null, 0, 0);
                        let p1 = cardContainer.mapToItem(null, width, height);
                        let w = Math.max(1, root.width);
                        let h = Math.max(1, root.height);
                        return Qt.rect(p0.x / w, p0.y / h, (p1.x - p0.x) / w, (p1.y - p0.y) / h);
                    }

                    // Каскад появления на КАЖДОМ открытии: снимок готов -> карточки раскрываются от центра
                    Connections {
                        target: root
                        function onCapturedChanged() {
                            if (!root.captured) {
                                cardContainer.staggerDone = false
                                startTimer.stop()
                            } else {
                                let centerIdx = Math.floor(appGrid.count / 2);
                                let distance = Math.abs(cardDelegate.index - centerIdx);
                                startTimer.interval = 50 + (Math.min(distance, 6) * 35);    // дальние не ждут
                                startTimer.restart();
                            }
                        }
                    }

                    Timer {
                        id: startTimer
                        onTriggered: cardContainer.staggerDone = true
                    }

                    // совсем далёкие не рисуем (и блюр на них не считаем)
                    visible: dist <= 5

                    // ListView раскладывает карточки с шагом ~260px — дальние подтягиваем к центру
                    property real depthX: {
                        if (!ready || isCurrent) return 0;
                        let side = index > appGrid.currentIndex ? -1 : 1;
                        let actual = dist * 260 + 15;
                        let target = root.depthNear + (dist - 1) * root.depthStep;
                        return side * Math.max(0, actual - target);
                    }
                    Behavior on depthX { enabled: root.shown; NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

                    property real rotAngle: {
                        if (!ready) return 90;
                        if (isCurrent) return 0;
                        let diff = index - appGrid.currentIndex;
                        return diff > 0 ? -35 : 35;
                    }

                    // чем дальше от центра, тем карточка меньше, бледнее и ниже
                    opacity: {
                        if (!ready) return 0.0;
                        return isCurrent ? 1.0 : Math.max(0.12, 0.5 - (dist - 1) * 0.1);
                    }

                    scale: {
                        if (!ready) return 0.7;
                        return isCurrent ? 1.12 : Math.max(0.6, 0.85 - (dist - 1) * 0.06);
                    }

                    property real baseOffset: !ready ? 30 : (isCurrent ? -10 : Math.min(dist, 4) * 8)
                    Behavior on baseOffset { enabled: root.shown; NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                    anchors.verticalCenterOffset: baseOffset + extra * 0.56

                    transform: Rotation {
                        origin.x: cardContainer.width / 2
                        origin.y: cardContainer.height / 2
                        axis { x: 0; y: 1; z: 0 }
                        angle: cardContainer.rotAngle
                    }

                    Behavior on rotAngle {
                        enabled: root.shown
                        NumberAnimation { duration: 400; easing.type: Easing.OutBack }
                    }
                    Behavior on opacity {
                        enabled: root.shown
                        NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
                    }
                    Behavior on scale {
                        enabled: root.shown
                        NumberAnimation { duration: 400; easing.type: Easing.OutCubic }
                    }


                    Rectangle {
                        anchors.fill: parent
                        z: 1
                        radius: 16

                        // запасной вариант, пока снимка нет — обычный полупрозрачный фон
                        color: {
                            if (root.hasShot && cardContainer.dist <= 3) return "transparent";
                            let baseCol = root.colSecondary;
                            return Qt.rgba(
                                parseInt(baseCol.substr(1,2), 16)/255,
                                parseInt(baseCol.substr(3,2), 16)/255,
                                parseInt(baseCol.substr(5,2), 16)/255,
                                index === appGrid.currentIndex ? 0.75 : 0.45
                            );
                        }

                        border.width: 0

                        Behavior on color { ColorAnimation { duration: 150 } }

                        // Размытый фон строго внутри карточки (скругление делает шейдер)
                        ShaderEffect {
                            id: blurFx
                            anchors.fill: parent
                            visible: root.hasShot && cardContainer.dist <= 3
                            z: -1

                            property variant source: wallpaperTex
                            property size itemSize: Qt.size(width, height)
                            property real blurPx: Math.min(root.blurPx + cardContainer.dist * 5, 56)
                            Behavior on blurPx { NumberAnimation { duration: 250 } }
                            property size texel: Qt.size(1 / Math.max(1, root.width), 1 / Math.max(1, root.height))
                            property vector4d radii: Qt.vector4d(16, 16, 16, 16)
                            property rect region: cardContainer.srcRect

                            property real tintA: cardContainer.isCurrent ? root.tintCurrent : root.tintOther
                            Behavior on tintA { NumberAnimation { duration: 150 } }
                            property vector4d tintColor: {
                                let c = Qt.color(root.colSecondary);
                                return Qt.vector4d(c.r, c.g, c.b, tintA);
                            }

                            fragmentShader: Qt.resolvedUrl("bar_blur.frag.qsb")
                        }

                        // иконка + название + описание
                        ColumnLayout {
                            anchors.centerIn: parent
                            anchors.verticalCenterOffset: -cardContainer.extra / 2
                            width: parent.width - 40
                            spacing: 16

                            Image {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredWidth: 90
                                Layout.preferredHeight: 90
                                source: modelData && modelData.icon ? "image://icon/" + modelData.icon : ""
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                                sourceSize: Qt.size(128, 128)

                                smooth: true
                                mipmap: true
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Text {
                                    Layout.fillWidth: true
                                    text: (modelData && modelData.name) ? modelData.name : "App"
                                    color: root.colText
                                    font.pixelSize: 17
                                    font.bold: true
                                    font.family: "JetBrainsMono Nerd Font, Monospace"
                                    horizontalAlignment: Text.AlignHCenter
                                    elide: Text.ElideRight
                                    maximumLineCount: 2
                                    wrapMode: Text.Wrap
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: modelData ? (modelData.genericName || modelData.comment || "") : ""
                                    color: root.colText
                                    font.pixelSize: 11
                                    font.family: "JetBrainsMono Nerd Font, Monospace"
                                    horizontalAlignment: Text.AlignHCenter
                                    elide: Text.ElideRight
                                    visible: text !== ""
                                    opacity: 0.8
                                }
                            }
                        }

                        // звёздочка у избранных
                        Text {
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.topMargin: 12
                            anchors.rightMargin: 14
                            visible: !!modelData && root.favorites.indexOf(modelData.id) >= 0
                            text: "\uf005"
                            color: root.colAccent
                            font.pixelSize: 16
                            font.family: "JetBrainsMono Nerd Font, Monospace"
                        }


                        // ── Продолжение карточки: «Запустить через…» ──
                        Item {
                            id: optionsArea
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: cardContainer.extra
                            clip: true       // текст виден только внутри уже выросшей части плашки
                            visible: cardContainer.extra > 1
                            // проявляется вместе с ростом: первые ~30% роста пусто, дальше плавно до 1
                            opacity: Math.max(0, Math.min(1, (cardContainer.extra / root.menuExtra - 0.3) / 0.7))

                            Column {
                                anchors.fill: parent
                                anchors.topMargin: 12
                                anchors.bottomMargin: 8
                                anchors.leftMargin: 10
                                anchors.rightMargin: 10
                                spacing: 0

                                Repeater {
                                    model: root.menuItems

                                    Rectangle {
                                        required property var modelData
                                        required property int index

                                        width: parent.width
                                        height: 36
                                        radius: 10
                                        color: root.menuIndex === index ? Qt.rgba(0, 0, 0, 0.28) : "transparent"
                                        Behavior on color { ColorAnimation { duration: 100 } }

                                        Row {
                                            anchors.fill: parent
                                            anchors.leftMargin: 6
                                            spacing: 10

                                            // номер — клавиша быстрого выбора
                                            Rectangle {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 22;  height: 22
                                                radius: 6
                                                color: root.menuIndex === index ? root.colAccent : Qt.rgba(1, 1, 1, 0.12)

                                                Text {
                                                    anchors.centerIn: parent
                                                    text: (index + 1).toString()
                                                    color: root.menuIndex === index ? root.colBg : root.colText
                                                    font.pixelSize: 12
                                                    font.bold: true
                                                    font.family: "JetBrainsMono Nerd Font, Monospace"
                                                }
                                            }

                                            Text {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 16
                                                horizontalAlignment: Text.AlignHCenter
                                                text: modelData.icon
                                                color: root.menuIndex === index ? root.colText : root.colAccent
                                                font.pixelSize: 14
                                                font.family: "JetBrainsMono Nerd Font, Monospace"
                                            }

                                            Text {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: parent.width - 22 - 16 - 20 - 6
                                                text: modelData.id === "fav"
                                                      ? (root.isFav(root.menuApp) ? "Убрать из избранного" : "Добавить в избранное")
                                                      : modelData.label
                                                color: root.colText
                                                font.pixelSize: 12
                                                font.bold: true
                                                font.family: "JetBrainsMono Nerd Font, Monospace"
                                                elide: Text.ElideRight
                                            }
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onEntered: root.menuIndex = index
                                            onClicked: root.activateMenuItem(index)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // клик по карточке: если открыто меню/консоль — закрыть их, иначе запустить приложение
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.menuOpen || root.consoleOpen) {
                                root.closeMenu()
                                root.closeConsole()
                                return
                            }
                            if (modelData) {
                                modelData.execute()
                                root.closeLauncher()
                            }
                        }
                    }
                }
            }

            // колесо мыши / тачпад: копим дельту и листаем по шагу
            WheelHandler {
                id: wheelHandler
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                property real acc: 0
                property double lastStep: 0

                onWheel: (event) => {
                    if (root.menuOpen) { event.accepted = true; return }

                    let delta = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x;
                    acc = Math.max(-240, Math.min(240, acc + delta));
                    let now = Date.now();

                    // шаг на каждые ~120 единиц прокрутки и не чаще раза в 45 мс —
                    // быстрая крутка не заваливает интерфейс анимациями
                    if (Math.abs(acc) >= 120 && now - lastStep >= 45) {
                        if (acc > 0) {
                            if (appGrid.currentIndex > 0) appGrid.currentIndex--;
                        } else if (appGrid.currentIndex < appGrid.count - 1) {
                            appGrid.currentIndex++;
                        }
                        acc = 0;
                        lastStep = now;
                    }
                    event.accepted = true;
                }
            }
        }
    }


    // Подсказка на пустой вкладке «Fav»
    Text {
        anchors.centerIn: parent
        visible: root.currentCategory === "fav" && appGrid.count === 0
        text: "Избранное пусто\n↑ → «Добавить в избранное»"
        horizontalAlignment: Text.AlignHCenter
        color: root.colText
        opacity: 0.5
        font.pixelSize: 14
        font.family: "JetBrainsMono Nerd Font, Monospace"
    }


    // ── Мини-консоль ─────────────────────────────────────────────────
    Rectangle {
        id: consoleBar
        z: 150
        width: 560
        height: 52
        radius: 16

        // запасной вариант, пока нет снимка экрана — как у карточек
        color: root.hasShot
               ? "transparent"
               : Qt.rgba(Qt.color(root.colSecondary).r, Qt.color(root.colSecondary).g, Qt.color(root.colSecondary).b, 0.75)
        x: (root.width - width) / 2
        // под лентой карточек (лента при этом не двигается)
        y: Math.min(mainCol.y + appGrid.y + appGrid.height / 2 + 211, root.height - height - 16)

        opacity: root.consoleOpen ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

        // чтобы клик по консоли не закрывал её через фон
        MouseArea { anchors.fill: parent }

        // Размытый фон строго внутри консоли — тот же шейдер что у карточек
        ShaderEffect {
            anchors.fill: parent
            visible: root.hasShot
            z: -1

            property variant source: wallpaperTex
            property size itemSize: Qt.size(width, height)
            property real blurPx: root.blurPx
            property size texel: Qt.size(1 / Math.max(1, root.width), 1 / Math.max(1, root.height))
            property vector4d radii: Qt.vector4d(16, 16, 16, 16)
            property rect region: Qt.rect(consoleBar.x / Math.max(1, root.width),
                                          consoleBar.y / Math.max(1, root.height),
                                          consoleBar.width / Math.max(1, root.width),
                                          consoleBar.height / Math.max(1, root.height))
            property real tintA: root.tintCurrent
            property vector4d tintColor: {
                let c = Qt.color(root.colSecondary);
                return Qt.vector4d(c.r, c.g, c.b, tintA);
            }

            fragmentShader: Qt.resolvedUrl("bar_blur.frag.qsb")
        }

        Text {
            id: consolePrompt
            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            text: "\u276f"
            color: root.colAccent
            font.pixelSize: 16
            font.bold: true
            font.family: "JetBrainsMono Nerd Font, Monospace"
        }

        Item {
            id: consoleField
            anchors.left: consolePrompt.right
            anchors.leftMargin: 12
            anchors.right: parent.right
            anchors.rightMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            height: 24
            clip: true

            // подсказка, пока ничего не набрано
            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.consoleText === ""
                text: "команда (запустится в фоне)"
                color: root.colText
                opacity: 0.35
                font.pixelSize: 15
                font.family: "JetBrainsMono Nerd Font, Monospace"
            }

            Text {
                id: consoleLabel
                anchors.verticalCenter: parent.verticalCenter
                // длинная команда прокручивается так, чтобы конец был виден
                x: Math.min(0, consoleField.width - width - 4)
                text: root.consoleText
                color: root.colText
                font.pixelSize: 15
                font.bold: true
                font.family: "JetBrainsMono Nerd Font, Monospace"
            }

            // мигающий курсор
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                x: consoleLabel.x + consoleLabel.width + 1
                width: 2
                height: 18
                color: root.colAccent

                SequentialAnimation on opacity {
                    running: root.consoleOpen
                    loops: Animation.Infinite
                    NumberAnimation { to: 0; duration: 500 }
                    NumberAnimation { to: 1; duration: 500 }
                }
            }
        }
    }


    // клик по пустому месту закрывает меню/консоль
    MouseArea {
        anchors.fill: parent
        z: -10
        enabled: root.menuOpen || root.consoleOpen
        onClicked: { root.closeMenu(); root.closeConsole(); globalTyper.forceActiveFocus() }
    }
}
