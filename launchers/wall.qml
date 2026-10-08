// wall.qml
//
// Выбор обоев: лента скошенных карточек (параллелограммы) на весь экран.
// Как и laun.qml, работает демоном — запущен всегда, окно скрыто:
//     quickshell ipc -p wall.qml call wall toggle
//
// Что делает:
//   - сканирует папку с обоями (find) и показывает превью в ленте
//   - фильтр по цвету сверху (точки): палитры обоев берутся из palettes.json,
//     который считает colors.py (он лежит рядом с этим файлом)
//   - Enter / клик по активной карточке -> swww меняет обои + colors.py пересчитывает тему
//   - настройки перехода swww и интро берутся из qs-launchers/settings.json
//
// Лента едет от одного вещественного cursor — поэтому всё (ширины, позиции, затемнение)
// считается плавно, без рывков даже при быстрой прокрутке.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "common"          // симлинк launchers/common -> ../common (Paths.qml берётся оттуда)


PanelWindow {
    id: root

    // ── Режим демона (как у laun.qml) ────────────────────────────────
    // Пока окно не показано: не рисуется, ничего не опрашивает, карточек и картинок нет
    // (модель пустая -> память свободна).
    property bool shown: false
    visible: shown


    // Показывает окно и готовит всё с нуля: сброс фильтра, свежие настройки/палитры, пересканирование папки
    function openWall() {
        if (shown) return

        userMoved = false
        colorFilter = ""
        pendingFilter = ""
        switching = false
        filterSwapTimer.stop()
        introDone = false             // интро играет заново при каждом открытии
        revealed = false

        settingsFile.reload()         // свежие настройки (переход swww, интро)
        paletteFile.reload()
        rescan()                      // сразу сканируем текущую папку (не ждём файл настроек)
        wallDirFile.reload()          // если в настройках папка другая — applyWallDir пересканирует
        currentWallProc.running = false
        currentWallProc.running = true

        shown = true
        revealTimer.restart()
        Qt.callLater(() => {
            checkAndFocusCurrent()
            wallGrid.forceActiveFocus()
        })
    }

    // Путь -> file:// url с экранированием (иначе файлы с #, % или ? в имени не грузятся)
    function fileUrl(path) {
        return "file://" + path.split("/").map(encodeURIComponent).join("/")
    }

    // Сканирует папку с обоями (дёшево: один find)
    function rescan() {
        scanBuf = []
        wallScanProc.running = false
        wallScanProc.running = true
    }

    // Применяет папку из настроек (пусто/нет файла -> папка по умолчанию) и пересканирует
    function applyWallDir(raw) {
        let d = (raw || "").trim().replace(/\/+$/, "")
        if (d === "") d = Paths.wallpapers
        if (d === wallpaperDir) return   // папка та же — скан уже идёт/прошёл
        wallpaperDir = d
        rawWallpaperList = []            // старая папка — старые карточки не показываем
        if (shown) rescan()
    }

    FileView {
        id: wallDirFile
        path: Paths.wallDirFile
        onLoaded: root.applyWallDir(text())
        onLoadFailed: root.applyWallDir("")    // файла ещё нет — значит папка по умолчанию
    }

    // Прячет окно и глушит все таймеры
    function closeWall() {
        if (!shown) return
        shown = false
        switching = false
        filterSwapTimer.stop()
        revealed = false
        revealTimer.stop()
        introTimer.stop()
    }

    IpcHandler {
        target: "wall"
        function toggle(): void { root.shown ? root.closeWall() : root.openWall() }
        function show(): void { root.openWall() }
        function hide(): void { root.closeWall() }
    }

    WlrLayershell.layer: WlrLayer.Overlay
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    anchors { top: true; bottom: true; left: true; right: true }

    color: "transparent"

    Shortcut {
        enabled: root.shown
        sequences: ["Escape"]
        onActivated: root.closeWall()
    }

    // colors.py лежит рядом с этим файлом (путь считается от расположения wall.qml)
    readonly property string colorScript: decodeURIComponent(Qt.resolvedUrl("colors.py").toString().replace(/^file:\/\//, ""))

    // папка с обоями: берётся из настроек (карточка «Папка обоев»), по умолчанию Paths.wallpapers
    property string wallpaperDir: Paths.wallpapers
    property var rawWallpaperList: []
    property var scanBuf: []
    property var colorPalettes: ({})
    property string currentActiveWallpaper: ""
    property bool userMoved: false      // юзер уже листает — не перебиваем его автопереходом к текущим обоям


    // ── Интро: те же правила что в laun.qml ──────────────────────────
    // Карточки раскрываются от центра по очереди при КАЖДОМ открытии;
    // созданные позже (при прокрутке) появляются сразу.
    property bool revealed: false       // окно показано и устоялось -> можно раскрывать карточки
    property bool introDone: false
    property bool introEnabled: true    // настройка «Вступительная анимация» (общая с лаунчером)


    // ── Геометрия ленты (скошенные карточки) ─────────────────────────
    property int cardH: 520             // высота карточки
    property int activeW: 700           // ширина активной карточки (по нижнему краю)
    property int sideW: 170             // ширина боковых «долек»
    property int gap: -34               // зазор между карточками; минус = карточки заходят друг под друга
    property real skew: 0.36            // наклон боковых граней (dx / dy)
    readonly property real skewDx: skew * cardH
    property real cornerR: 6            // радиус скругления углов карточек
    property real depthScale: 0.10      // насколько уменьшается каждая следующая карточка (0 — без глубины)
    property real depthDrop: 12         // на сколько px опускается каждая следующая карточка (макс. 3 шага)
    property real liftY: 14             // на сколько px приподнята активная карточка

    // единичный вектор наклонной грани (нужен для скругления косых углов)
    readonly property real edgeLen: Math.sqrt(skewDx * skewDx + cardH * cardH)
    readonly property real edgeUx: skewDx / edgeLen
    readonly property real edgeUy: cardH / edgeLen


    // ── Фильтр по цвету ──────────────────────────────────────────────
    property string colorFilter: ""     // фильтр, по которому реально построен список
    property string pendingFilter: ""   // фильтр, который выбрал юзер (применится после «схлопывания» карточек)
    property bool switching: false      // идёт плавная смена набора карточек

    readonly property var colorKeys: [
        { key: "red",    col: "#ff5722" },
        { key: "orange", col: "#ffa000" },
        { key: "yellow", col: "#ffd600" },
        { key: "green",  col: "#4caf50" },
        { key: "blue",   col: "#2196f3" },
        { key: "purple", col: "#9c4dff" },
        { key: "pink",   col: "#ff69b4" },
        { key: "gray",   col: "#9e9e9e" }
    ]

    // Целевые оттенки точек (градусы). Поиск «по соседству»: подходят и близкие оттенки
    readonly property var colorHues: ({
        red: 0, orange: 28, yellow: 55, green: 120, blue: 215, purple: 275, pink: 325
    })
    property real hueTolerance: 40      // насколько далеко от целевого оттенка ещё считаем «рядом», °


    // Оценивает, насколько обои подходят под цвет: меньше — лучше, -1 — не подходит.
    // Смотрим все цвета палитры, дальние позиции в палитре чуть штрафуем (+8 за позицию)
    function colorScore(palette, key) {
        if (!palette || palette.length === 0) return -1

        let best = -1
        for (let i = 0; i < palette.length; i++) {
            let c = Qt.color(palette[i])
            let s = c.hsvSaturation, v = c.hsvValue
            let achromatic = (s < 0.18 || v < 0.12)
            let score

            if (key === "gray") {
                if (!achromatic) continue
                score = s * 100
            } else {
                if (achromatic) continue
                let d = Math.abs(c.hsvHue * 360 - colorHues[key])
                d = Math.min(d, 360 - d)
                if (d > hueTolerance) continue
                score = d
            }

            score += i * 8
            if (best < 0 || score < best) best = score
        }
        return best
    }

    // Список с учётом фильтра. Без фильтра отдаём тот же массив (модель не перезапускается)
    property var filteredList: {
        if (colorFilter === "") return rawWallpaperList

        let pal = colorPalettes
        let f = colorFilter
        let scored = []
        for (let it of rawWallpaperList) {
            let sc = colorScore(pal[it.path], f)
            if (sc >= 0) scored.push({ it: it, sc: sc })
        }
        scored.sort((x, y) => x.sc - y.sc)       // самые близкие — в начало
        return scored.map(x => x.it)
    }


    // Плавная смена фильтра: карточки уходят вниз и гаснут -> меняем набор -> раскрываются заново
    // каскадом от центра. Саму подмену набора делает filterSwapTimer
    function setFilter(key) {
        if (key === pendingFilter) return
        pendingFilter = key
        userMoved = true
        switching = true
        revealed = false            // запускает анимацию «ухода» у всех карточек
        filterSwapTimer.restart()
    }

    Timer {
        id: filterSwapTimer
        interval: 260
        onTriggered: {
            root.animateCursor = false
            root.currentIndex = 0
            root.colorFilter = root.pendingFilter
            restoreMoveTimer.restart()
            root.switching = false
            if (root.shown) root.revealed = true      // каскад появления (интро) играет заново
        }
    }


    // ── Плавный курсор ленты ─────────────────────────────────────────
    // Всё (позиции, ширины, затемнение) считается от одного вещественного cursor, поэтому лента
    // едет без рывков и не «съезжает», даже при быстрой прокрутке.
    property int currentIndex: 0
    property bool animateCursor: true
    property real cursor: currentIndex

    Behavior on cursor {
        enabled: root.animateCursor
        // время в пути ограничено: любой перелёт занимает ~220 мс после последнего шага
        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
    }

    readonly property int wallCount: filteredList.length
    readonly property real extraW: activeW - sideW
    readonly property int c0: Math.floor(cursor)
    readonly property real fr: cursor - c0
    readonly property real w0: sideW + extraW * (1 - fr)      // ширина карточки c0
    readonly property real w1: sideW + extraW * fr            // ширина карточки c0+1
    readonly property real p0: w0 + gap
    readonly property real p1: w1 + gap
    readonly property real anchorX: {
        let cc0 = (w0 + skewDx) / 2
        let cc1 = p0 + (w1 + skewDx) / 2
        return cc0 + (cc1 - cc0) * fr
    }


    // Левый край карточки i относительно карточки c0
    function cardLeft(i) {
        let k = i - c0
        let P = sideW + gap
        if (k <= 0) return k * P
        if (k === 1) return p0
        return p0 + p1 + (k - 2) * P
    }

    // Ширина карточки i: боковая «долька» + добавка, которая тем больше, чем ближе к курсору
    function cardWidth(i) {
        return sideW + extraW * Math.max(0, 1 - Math.abs(i - cursor))
    }

    // Сдвигает выбор на n карточек (не выходя за края списка)
    function moveBy(n) {
        userMoved = true
        currentIndex = Math.max(0, Math.min(wallCount - 1, currentIndex + n))
    }

    // Применяет выбранные обои: запоминает путь, запускает setWallProc (swww + colors.py)
    // и прячет окно (демон остаётся жить)
    function applyWallpaper(item) {
        if (!item) return
        selectedWallpaperPath = item.path
        setWallProc.running = true
        closeWall()
    }

    // Перезапускает интро (или сразу считает его пройденным, если выключено в настройках)
    function replayIntro() {
        introDone = false
        if (introEnabled) introTimer.restart()
        else introDone = true
    }
    onIntroEnabledChanged: if (!introEnabled) introDone = true
    onRevealedChanged: if (revealed) replayIntro()

    Timer {
        id: introTimer
        interval: 900
        onTriggered: root.introDone = true
    }
    Timer {
        id: revealTimer
        interval: 60
        onTriggered: root.revealed = true
    }


    // Текущие обои через swww (запускается только при открытии)
    Process {
        id: currentWallProc
        command: ["bash", "-c", "swww query | grep -oP 'image: \\K.*' || echo ''"]
        stdout: SplitParser {
            onRead: data => {
                let path = data.trim()
                if (path !== "") {
                    root.currentActiveWallpaper = path
                    root.checkAndFocusCurrent()
                }
            }
        }
    }

    FileView {
        id: paletteFile
        path: Paths.cache + "/palettes.json"

        onLoaded: {
            try {
                root.colorPalettes = JSON.parse(text())
            } catch (e) {}
        }
    }

    // Палитры досчитываем только если в папке появились обои, которых ещё нет в palettes.json
    Process {
        id: autoColorProc
        command: ["python3", root.colorScript]
        // colors.py должен брать папку отсюда (os.environ["WALLPAPER_DIR"]), а не из своей константы
        environment: ({ WALLPAPER_DIR: root.wallpaperDir })
        onExited: paletteFile.reload()
    }

    Component.onCompleted: {
        // холодный старт из бинда (демон ещё не запущен): сразу показываемся
        if (Quickshell.env("QS_WALL_SHOW") === "1") openWall()
    }

    // Плавный/мгновенный переход к карточке: на открытии встаём без анимации ленты
    Timer {
        id: restoreMoveTimer
        interval: 80
        onTriggered: root.animateCursor = true
    }


    // Находит активные обои в списке и встаёт на них (если не нашлись — на середину ленты).
    // Не трогает позицию, если юзер уже сам листает
    function checkAndFocusCurrent() {
        if (!root.shown || userMoved) return;
        let list = root.rawWallpaperList;
        if (list.length === 0) return;

        let targetIndex = -1;
        if (root.currentActiveWallpaper !== "") {
            targetIndex = list.findIndex(item => item.path === root.currentActiveWallpaper);
        }
        if (targetIndex === -1) targetIndex = Math.floor(list.length / 2);

        Qt.callLater(() => {
            if (!root.shown || root.wallCount <= 0) return;
            root.animateCursor = false;              // на открытии встаём мгновенно, интро само всё раскроет
            root.currentIndex = targetIndex;
            restoreMoveTimer.restart();
        });
    }

    // Сканирует папку с обоями одним find'ом и собирает отсортированный список
    Process {
        id: wallScanProc
        // путь передаётся аргументом (без bash и кавычек) — апострофы/пробелы в имени папки не страшны
        command: ["find", root.wallpaperDir, "-maxdepth", "1", "-type", "f",
                  "(", "-iname", "*.jpg", "-o", "-iname", "*.jpeg", "-o", "-iname", "*.png", "-o", "-iname", "*.webp", ")"]

        stdout: SplitParser {
            onRead: data => {
                let path = data.trim()
                if (path !== "") {
                    root.scanBuf.push({ path: path, name: path.split("/").pop() })
                }
            }
        }

        onExited: (exitCode) => {
            let list = root.scanBuf.slice().sort((a, b) => a.name.localeCompare(b.name))
            let same = list.length === root.rawWallpaperList.length &&
                       list.every((it, i) => it.path === root.rawWallpaperList[i].path)
            if (!same) {
                root.rawWallpaperList = list       // список изменился — пересобираем (иначе ничего не дёргаем)
                root.checkAndFocusCurrent()
            }
            // есть обои без палитры -> один раз досчитываем
            if (list.some(it => !root.colorPalettes[it.path]) && !autoColorProc.running)
                autoColorProc.running = true
        }
    }

    // Ставит обои через swww и отдельным процессом гоняет colors.py (пересчёт темы).
    // Оба запускаются через setsid, чтобы не умирали вместе с окном
    Process {
        id: setWallProc
        // пути приходят аргументами $1..$4, поэтому кавычки/пробелы/$ в имени файла ничего не ломают
        command: [
            "bash", "-c",
            "export XDG_RUNTIME_DIR=/run/user/$(id -u);" +
            "export WAYLAND_DISPLAY=$(ls /run/user/$(id -u)/wayland-* 2>/dev/null | head -n1 | xargs basename);" +
            "setsid -f swww img \"$1\" --transition-type \"$3\" --transition-pos 0.5,0.5 --transition-duration \"$4\" >/dev/null 2>&1; " +
            "setsid -f python3 \"$2\" \"$1\" > /tmp/color_error.log 2>&1",
            "_", root.selectedWallpaperPath, root.colorScript, root.transitionType, String(root.transitionDuration)
        ]
        onExited: paletteFile.reload()
    }

    property string selectedWallpaperPath: ""


    // ── Настройки из меню настроек (вкладка «Лаунчеры») ──────────────
    property string transitionType: "grow"
    property real transitionDuration: 1.5
    readonly property string settingsPath: Paths.launchers + "/settings.json"

    FileView {
        id: settingsFile
        path: root.settingsPath
        onLoaded: {
            try {
                let o = JSON.parse(text().trim())
                let w = o.wall || {}
                let l = o.laun || {}
                let types = ["grow", "fade", "wipe", "wave", "outer", "center", "simple", "any"]
                if (types.indexOf(w.transition) >= 0) root.transitionType = w.transition
                if (typeof w.duration === "number") root.transitionDuration = Math.max(0.3, Math.min(3.0, w.duration))
                if (typeof l.intro === "boolean") root.introEnabled = l.intro    // «Вступительная анимация» общая
            } catch (e) {}
        }
    }


    // ── Верхняя плашка: сброс фильтра + цветные точки ────────────────
    Rectangle {
        id: filterBar
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: wallGrid.top
        anchors.bottomMargin: -2
        height: 38
        width: barRow.implicitWidth + 24
        radius: 12
        color: Qt.rgba(0.08, 0.08, 0.09, 0.85)
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.08)
        opacity: (root.revealed || root.switching) ? 1 : 0
        z: 5
        Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

        RowLayout {
            id: barRow
            anchors.centerIn: parent
            spacing: 9

            // «все обои» (сброс фильтра)
            Rectangle {
                Layout.preferredWidth: 24
                Layout.preferredHeight: 24
                radius: 6
                color: "transparent"
                border.width: root.pendingFilter === "" ? 1.5 : 0
                border.color: Qt.rgba(1, 1, 1, 0.8)

                Image {
                    anchors.centerIn: parent
                    width: 16;  height: 16
                    source: "file://" + Paths.icons + "/grid.svg"
                    sourceSize: Qt.size(32, 32)
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    mipmap: true
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.setFilter(""); wallGrid.forceActiveFocus() }
                }
            }

            // разделитель
            Rectangle {
                Layout.preferredWidth: 1
                Layout.preferredHeight: 16
                color: Qt.rgba(1, 1, 1, 0.12)
            }

            // цветные точки
            Repeater {
                model: root.colorKeys
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool active: root.pendingFilter === modelData.key
                    Layout.preferredWidth: 16
                    Layout.preferredHeight: 16
                    radius: 6
                    color: modelData.col
                    border.width: active ? 2 : 0
                    border.color: "white"
                    Behavior on border.width { NumberAnimation { duration: 140 } }
                    scale: active || dotMouse.containsMouse ? 1.2 : 1.0
                    Behavior on scale { NumberAnimation { duration: 120 } }

                    MouseArea {
                        id: dotMouse
                        anchors.fill: parent
                        anchors.margins: -3
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.setFilter(parent.active ? "" : parent.modelData.key)
                            wallGrid.forceActiveFocus()
                        }
                    }
                }
            }
        }
    }


    // ============ Лента карточек ============
    Item {
        id: wallGrid
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: 600
        focus: true

        property real wheelAcc: 0

        Repeater {
            // пока окно скрыто — модель пустая: карточки и картинки уничтожены, память свободна
            model: root.shown ? root.filteredList : []

            delegate: Item {
                id: cardContainer
                required property var modelData
                required property int index

                readonly property bool isCurrent: index === root.currentIndex
                readonly property real dist: Math.abs(index - root.cursor)
                // грузим картинки с запасом за экраном, чтобы не декодировать на лету
                readonly property bool near: Math.abs(index - root.cursor) < 7

                // ограничивающий прямоугольник параллелограмма: ширина + боковой вынос
                width: root.cardWidth(index) + root.skewDx
                height: root.cardH
                x: wallGrid.width / 2 - root.anchorX + root.cardLeft(index)
                y: (wallGrid.height - height) / 2 + baseOffset - root.liftY * Math.max(0, 1 - dist) + Math.min(dist, 3) * root.depthDrop
                z: Math.round(100 - dist * 10)       // ближе к центру — выше

                // глубина: чем дальше от центра, тем карточка меньше (масштаб равномерный — наклон граней не меняется)
                scale: introScale * (dist < 1
                    ? 1.0 - root.depthScale * dist
                    : Math.max(0.6, 1.0 - root.depthScale - (dist - 1) * root.depthScale * 0.6))
                visible: near && x + width > 0 && x < wallGrid.width

                property bool staggerDone: false
                property bool timerDone: root.introDone || staggerDone
                property bool ready: timerDone && root.revealed


                // Запускает таймер каскада: чем дальше карточка от выбранной, тем позже раскроется
                function startStagger() {
                    let distance = Math.abs(index - root.currentIndex);
                    startTimer.interval = 50 + (Math.min(distance, 6) * 35);
                    startTimer.restart();
                }

                Component.onCompleted: if (root.revealed) startStagger()

                Connections {
                    target: root
                    function onRevealedChanged() {
                        if (!root.revealed) {
                            cardContainer.staggerDone = false
                            startTimer.stop()
                        } else {
                            cardContainer.startStagger()
                        }
                    }
                }

                Timer {
                    id: startTimer
                    onTriggered: cardContainer.staggerDone = true
                }

                // интро: карточки всплывают снизу и проявляются
                opacity: ready ? 1.0 : 0.0
                property real baseOffset: ready ? 0 : 30
                property real introScale: ready ? 1.0 : 0.92
                Behavior on introScale { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                Behavior on baseOffset { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                Behavior on opacity { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }


                Loader {
                    anchors.fill: parent
                    active: cardContainer.near

                    sourceComponent: Item {
                        id: content
                        readonly property real dx: root.skewDx
                        readonly property real w: cardContainer.width
                        readonly property real h: cardContainer.height
                        readonly property real rr: root.cornerR
                        readonly property real ux: root.edgeUx
                        readonly property real uy: root.edgeUy

                        // цвет рамки: у активной — осветлённый основной цвет палитры, у остальных — бледно-белый
                        property color edgeColor: {
                            if (!cardContainer.isCurrent) return Qt.rgba(1, 1, 1, 0.18)
                            let path = cardContainer.modelData ? cardContainer.modelData.path : ""
                            let pal = root.colorPalettes[path]
                            return (pal && pal.length > 0) ? Qt.lighter(pal[0], 1.6) : Qt.rgba(1, 1, 1, 0.5)
                        }

                        Image {
                            id: wallImage
                            anchors.fill: parent
                            source: cardContainer.modelData ? root.fileUrl(cardContainer.modelData.path) : ""
                            fillMode: Image.PreserveAspectCrop
                            sourceSize.height: 560           // не декодируем 4K ради карточки
                            asynchronous: true
                            smooth: true
                            visible: false
                        }

                        // тень от карточки на ту, что лежит позади: сдвинута «наружу» от центра и вниз
                        Shape {
                            anchors.fill: parent
                            x: Math.max(-1, Math.min(1, cardContainer.index - root.cursor)) * 12
                            y: 14
                            opacity: 0.38 * Math.min(1, cardContainer.dist)    // у активной карточки теней нет
                            preferredRendererType: Shape.CurveRenderer
                            ShapePath {
                                fillColor: "black"
                                strokeColor: "transparent"
                                strokeWidth: 0
                                startX: content.dx + content.rr; startY: 0
                                PathLine { x: content.w - content.rr; y: 0 }
                                PathQuad { x: content.w - content.rr * content.ux; y: content.rr * content.uy; controlX: content.w; controlY: 0 }
                                PathLine { x: content.w - content.dx + content.rr * content.ux; y: content.h - content.rr * content.uy }
                                PathQuad { x: content.w - content.dx - content.rr; y: content.h; controlX: content.w - content.dx; controlY: content.h }
                                PathLine { x: content.rr; y: content.h }
                                PathQuad { x: content.rr * content.ux; y: content.h - content.rr * content.uy; controlX: 0; controlY: content.h }
                                PathLine { x: content.dx - content.rr * content.ux; y: content.rr * content.uy }
                                PathQuad { x: content.dx + content.rr; y: 0; controlX: content.dx; controlY: 0 }
                            }
                        }

                        // тёмная подложка под картинкой: пока она грузится, карточка не «дырявая»
                        Shape {
                            anchors.fill: parent
                            preferredRendererType: Shape.CurveRenderer
                            ShapePath {
                                fillColor: Qt.rgba(0.08, 0.08, 0.1, 1.0)
                                strokeColor: "transparent"
                                strokeWidth: 0
                                startX: content.dx + content.rr; startY: 0
                                PathLine { x: content.w - content.rr; y: 0 }
                                PathQuad { x: content.w - content.rr * content.ux; y: content.rr * content.uy; controlX: content.w; controlY: 0 }
                                PathLine { x: content.w - content.dx + content.rr * content.ux; y: content.h - content.rr * content.uy }
                                PathQuad { x: content.w - content.dx - content.rr; y: content.h; controlX: content.w - content.dx; controlY: content.h }
                                PathLine { x: content.rr; y: content.h }
                                PathQuad { x: content.rr * content.ux; y: content.h - content.rr * content.uy; controlX: 0; controlY: content.h }
                                PathLine { x: content.dx - content.rr * content.ux; y: content.rr * content.uy }
                                PathQuad { x: content.dx + content.rr; y: 0; controlX: content.dx; controlY: 0 }
                            }
                        }

                        // маска: параллелограмм со скруглёнными углами.
                        // CurveRenderer сглаживает края сам, поэтому MSAA-слои не нужны
                        Shape {
                            id: maskShape
                            anchors.fill: parent
                            visible: false
                            layer.enabled: true
                            preferredRendererType: Shape.CurveRenderer
                            ShapePath {
                                fillColor: "black"
                                strokeColor: "transparent"
                                strokeWidth: 0
                                startX: content.dx + content.rr; startY: 0
                                PathLine { x: content.w - content.rr; y: 0 }
                                PathQuad { x: content.w - content.rr * content.ux; y: content.rr * content.uy; controlX: content.w; controlY: 0 }
                                PathLine { x: content.w - content.dx + content.rr * content.ux; y: content.h - content.rr * content.uy }
                                PathQuad { x: content.w - content.dx - content.rr; y: content.h; controlX: content.w - content.dx; controlY: content.h }
                                PathLine { x: content.rr; y: content.h }
                                PathQuad { x: content.rr * content.ux; y: content.h - content.rr * content.uy; controlX: 0; controlY: content.h }
                                PathLine { x: content.dx - content.rr * content.ux; y: content.rr * content.uy }
                                PathQuad { x: content.dx + content.rr; y: 0; controlX: content.dx; controlY: 0 }
                            }
                        }

                        OpacityMask {
                            anchors.fill: parent
                            source: wallImage
                            maskSource: maskShape
                        }

                        // затемнение дальних карточек: форма фиксирована, меняется только opacity
                        Shape {
                            anchors.fill: parent
                            opacity: cardContainer.dist < 1
                                ? 0.35 * cardContainer.dist
                                : Math.min(0.7, 0.35 + (cardContainer.dist - 1) * 0.12)
                            preferredRendererType: Shape.CurveRenderer
                            ShapePath {
                                fillColor: "black"
                                strokeColor: "transparent"
                                strokeWidth: 0
                                startX: content.dx + content.rr; startY: 0
                                PathLine { x: content.w - content.rr; y: 0 }
                                PathQuad { x: content.w - content.rr * content.ux; y: content.rr * content.uy; controlX: content.w; controlY: 0 }
                                PathLine { x: content.w - content.dx + content.rr * content.ux; y: content.h - content.rr * content.uy }
                                PathQuad { x: content.w - content.dx - content.rr; y: content.h; controlX: content.w - content.dx; controlY: content.h }
                                PathLine { x: content.rr; y: content.h }
                                PathQuad { x: content.rr * content.ux; y: content.h - content.rr * content.uy; controlX: 0; controlY: content.h }
                                PathLine { x: content.dx - content.rr * content.ux; y: content.rr * content.uy }
                                PathQuad { x: content.dx + content.rr; y: 0; controlX: content.dx; controlY: 0 }
                            }
                        }

                        // тонкая рамка по контуру (без слоя — рисуется прямо в сцену)
                        Shape {
                            anchors.fill: parent
                            preferredRendererType: Shape.CurveRenderer
                            ShapePath {
                                fillColor: "transparent"
                                strokeColor: content.edgeColor
                                strokeWidth: cardContainer.isCurrent ? 2 : 1
                                joinStyle: ShapePath.RoundJoin
                                startX: content.dx + content.rr; startY: 0
                                PathLine { x: content.w - content.rr; y: 0 }
                                PathQuad { x: content.w - content.rr * content.ux; y: content.rr * content.uy; controlX: content.w; controlY: 0 }
                                PathLine { x: content.w - content.dx + content.rr * content.ux; y: content.h - content.rr * content.uy }
                                PathQuad { x: content.w - content.dx - content.rr; y: content.h; controlX: content.w - content.dx; controlY: content.h }
                                PathLine { x: content.rr; y: content.h }
                                PathQuad { x: content.rr * content.ux; y: content.h - content.rr * content.uy; controlX: 0; controlY: content.h }
                                PathLine { x: content.dx - content.rr * content.ux; y: content.rr * content.uy }
                                PathQuad { x: content.dx + content.rr; y: 0; controlX: content.dx; controlY: 0 }
                            }
                        }
                    }
                }

                // клик только по самому параллелограмму (а не по всему прямоугольнику)
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    containmentMask: QtObject {
                        // Попадает ли точка внутрь скошенной карточки
                        function contains(p: point): bool {
                            if (p.y < 0 || p.y > cardContainer.height) return false
                            let left = root.skewDx * (1 - p.y / cardContainer.height)
                            return p.x >= left && p.x <= left + (cardContainer.width - root.skewDx)
                        }
                    }
                    onClicked: {
                        root.userMoved = true
                        if (cardContainer.isCurrent) root.applyWallpaper(cardContainer.modelData)
                        else root.currentIndex = cardContainer.index
                        wallGrid.forceActiveFocus()
                    }
                }
            }
        }

        // колесо мыши / тачпад
        WheelHandler {
            id: wheelHandler
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: (event) => {
                let delta = event.angleDelta.y !== 0 ? event.angleDelta.y : event.angleDelta.x;
                // копим дельту: колесо мыши = 1 шаг на щелчок, тачпад не улетает через всю ленту
                wallGrid.wheelAcc += delta;
                while (Math.abs(wallGrid.wheelAcc) >= 120) {
                    let dir = wallGrid.wheelAcc > 0 ? -1 : 1;
                    root.moveBy(dir);
                    wallGrid.wheelAcc -= (dir === -1 ? 120 : -120);
                }
                event.accepted = true;
            }
        }

        // стрелки листают, Enter применяет обои
        Keys.onPressed: (event) => {
            if (event.key === Qt.Key_Left) {
                root.moveBy(-1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Right) {
                root.moveBy(1);
                event.accepted = true;
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.applyWallpaper(root.filteredList[root.currentIndex]);
                event.accepted = true;
            }
        }
    }
}
