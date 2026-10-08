// LrcGen.qml
//
// Зачем это: окошко-обёртка над auto_lrc.py. Раньше каждый раз приходилось
// лезть в терминал, вспоминать ключи и гонять скрипт руками, а тут всё в одном
// окне: вставил текст песни, кинул ссылку/файл с аудио, нажал "запустить" и
// на выходе готовый .lrc с таймингами для LyricsPanel. Лог идёт прямо в окне.
//
// Это обычное окно (xdg toplevel), не layer-shell, так что Hyprland видит его
// как нормальное приложение. Один запуск = одно окно = один процесс:
//   quickshell -n -p ~/.tech/shell/lrc/LrcGen.qml
// Закрыл (✕, Esc или обычный keybind) - процесс сам завершается.
//
// Чтоб всегда открывалось плавающим, а не влетало в тайлинг, в hyprland.conf:
//   windowrulev2 = float, title:^(Auto LRC)$
//   windowrulev2 = center, title:^(Auto LRC)$
//   windowrulev2 = blur, title:^(Auto LRC)$
// (заголовок окна специально НЕ переводится, иначе правила сломаются)
//
// Язык интерфейса берётся из настроек шелла (словари в ~/.tech/shell/lang,
// ключи lrc.* в LangRu / LangEn), отдельной кнопки языка нет.
//
// Нужно: auto_lrc.py лежит рядом, плюс python3 и stable-ts
// (pip install --user stable-ts yt-dlp)

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io


Window {
    id: root

    title: "Auto LRC"
    visible: true
    color: "transparent"

    width: 640
    height: 780
    minimumWidth: width;  minimumHeight: height
    maximumWidth: width
    maximumHeight: height


    // закрывает окно: если скрипт ещё крутится - сначала убиваем его, потом выходим
    function closePanel() {
        if (proc.running) proc.running = false
        Qt.quit()
    }

    Shortcut { sequence: "Escape"; onActivated: root.closePanel() }

    // ── палитра и размеры, те же что у LyricsPanel ──
    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"
    readonly property real cr: 6
    readonly property real pad: 14
    readonly property real labelW: 100

    property string colBg: "#181825"
    property string colAccent: "#a3cef1"
    property string colText: "#e0e1dd"
    property string colSecondary: "#3d5a80"
    property real glassAlpha: 0.88
    readonly property color colGlass: Qt.alpha(colBg, glassAlpha)
    readonly property color colDanger: "#e06c75"
    readonly property color colWarn:"#e5c07b"

    // цвета тянем из colors.json шелла и следим за изменениями
    FileView {
        id: colorFile
        path: (Quickshell.env("HOME") || "") + "/.cache/quickshell/colors.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const json = JSON.parse(colorFile.text().trim())
                if (json.bg) root.colBg = json.bg
                if (json.accent) root.colAccent = json.accent
                if (json.text) root.colText = json.text
                if (json.secondary) root.colSecondary = json.secondary
            } catch (e) {}
        }
    }

    // ── язык интерфейса ──
    // берём из настроек шелла (SmStore пишет в settings.json), меняется на лету
    // если сменить язык пока окно открыто. Пока файла нет - по системной локали
    property string uiLang: {
        const l = (Quickshell.env("LANG") || "").toLowerCase()
        return (l.indexOf("ru") === 0 || l.indexOf("uk") === 0 || l.indexOf("be") === 0) ? "ru" : "en"
    }

    readonly property string settingsPath: (Quickshell.env("XDG_DATA_HOME") || ((Quickshell.env("HOME") || "") + "/.local/share"))
        + "/qs-launchers/settings.json"

    FileView {
        id: settingsFile
        path: root.settingsPath
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try {
                const o = JSON.parse(settingsFile.text().trim())
                if (root.langCodes.indexOf(o.lang) >= 0) root.uiLang = o.lang
            } catch (e) {}
        }
        onLoadFailed: {}
    }

    // словари читаем как обычные файлы из lang шелла и выдираем объект `s`
    // (это просто JSON-подобный литерал), так не нужен ни qmldir, ни синглтон Tr.
    // Новый язык: добавь код в langCodes (файл lang/LangXx.qml должен быть)
    readonly property string langDir: (Quickshell.env("HOME") || "") + "/.tech/shell/lang"
    readonly property var langCodes: ["ru", "en"]
    property var dicts: ({})

    // разбирает текст файла языка и кладёт словарь в root.dicts[code]
    function parseDict(code, txt) {
        const a = txt.indexOf("({")
        const b = txt.lastIndexOf("})")
        if (a < 0 || b < 0) { console.warn("LrcGen: не найден словарь s в языке " + code); return }
        try {
            const o = JSON.parse(txt.substring(a + 1, b + 1))
            const d = Object.assign({}, root.dicts)
            d[code] = o
            root.dicts = d
        } catch (e) {
            console.warn("LrcGen: не удалось разобрать язык " + code + ": " + e)
        }
    }

    Instantiator {
        model: root.langCodes
        delegate: FileView {
            required property string modelData
            path: root.langDir + "/Lang" + modelData.charAt(0).toUpperCase() + modelData.slice(1) + ".qml"
            onLoaded: root.parseDict(modelData, text())
            onLoadFailed: console.warn("LrcGen: нет файла языка " + path)
        }
    }

    // перевод по ключу: выбранный язык -> русский -> сам ключ (как Tr.tr в шелле)
    function t(key) {
        const d = root.dicts[root.uiLang]
        let v = d ? d[key] : undefined
        if (v === undefined) {
            const r = root.dicts["ru"]
            v = r ? r[key] : undefined
        }
        return v !== undefined ? v : key
    }

    // папка где лежит этот файл, auto_lrc.py должен быть рядом
    readonly property string scriptDir: (Quickshell.env("HOME") || "") + "/.tech/shell/lrc"
    readonly property string scriptPath: scriptDir + "/auto_lrc.py"
    readonly property string outDir: scriptDir + "/out"

    // ── состояние формы ──
    property string mode: "paste"      // "paste" | "file" | "transcribe"
    property string lyricsPath: ""
    property string lyricsText: ""
    property string source: ""
    property string outName: ""
    property string lang: "ru"         // язык ПЕСНИ, не интерфейса
    property string model: "medium"
    property bool vocals: false
    property bool tail: false

    // ── состояние работы ──
    // текст статуса считается из него, а не наоборот, поэтому от языка не зависит
    property string state: "idle"      // idle | running | done | error | cancelled | warn
    property string stage: ""          // audio | vocals | model | align | transcribe | tail | save
    property string warnKey: ""
    property int exitCode: 0
    property string lastLine: ""
    property string lastOut: ""
    property string tmpLyrics: "/tmp/lrcgen_" + Date.now() + ".txt"
    readonly property bool running: state === "running"

    readonly property string statusText:
        state === "running" ? (stage.length ? t("lrc.stage." + stage) : t("lrc.status.starting"))
        : state === "done" ? t("lrc.status.done").replace("%1", lastOut)
        : state === "error" ? t("lrc.status.error").replace("%1", exitCode) + (lastLine.length ? " — " + lastLine : "")
        : state === "cancelled" ? t("lrc.status.cancelled")
        : state === "warn" ? t(warnKey)
        : t("lrc.status.ready")

    readonly property color statusColor: state === "error" ? colDanger : state === "warn" ? colWarn : colAccent

    // имя результата по умолчанию: берём имя из источника (файл/ссылка), чистим от мусора
    function defaultOutPath() {
        let base = root.source.length ? root.source.split("/").pop().replace(/\.[^.]+$/, "") : "result"
        base = base.replace(/[^A-Za-z0-9_\-а-яА-ЯёЁ ]/g, "_").trim()
        if (!base.length) base = "result"
        return root.outDir + "/" + base + ".lrc"
    }

    // итоговый путь к .lrc: своё имя (без слэшей, с .lrc) или имя из источника
    function outFile() {
        let n = root.outName.trim().replace(/[\/\\]/g, "_")
        if (!n.length) return root.defaultOutPath()
        if (!/\.lrc$/i.test(n)) n += ".lrc"
        return root.outDir + "/" + n
    }

    // показывает предупреждение в статусе (например "нет текста") и не запускает работу
    function warn(key) {
        root.warnKey = key
        root.state = "warn"
    }

    // кнопка "запустить": проверяет что всё заполнено, чистит лог
    // и создаёт папку out, дальше цепочка идёт через mkdirProc
    function start() {
        if (root.running) return
        if (root.mode === "paste" && !root.lyricsText.trim().length) { warn("lrc.err.nolyrics"); return }
        if (root.mode === "file" && !root.lyricsPath.trim().length) { warn("lrc.err.nofile"); return }
        if (!root.source.trim().length) { warn("lrc.err.nosource"); return }

        logModel.clear()
        root.stage = ""
        root.lastLine = ""
        root.state = "running"
        mkdirProc.command = ["mkdir", "-p", root.outDir]
        mkdirProc.running = true
    }

    // отмена: ставим статус и гасим процесс если он идёт
    function cancel() {
        root.state = "cancelled"
        if (proc.running) proc.running = false
    }

    Process {
        id: mkdirProc
        running: false
        onExited: (code) => {
            if (!root.running) return
            if (root.mode === "paste") {
                writeProc.command = ["bash", "-c", 'printf "%s" "$1" > "$2"', "bash", root.lyricsText, root.tmpLyrics]
                writeProc.running = true
            } else {
                root.runMain()
            }
        }
    }

    Process { id: writeProc; running: false
        onExited: (code) => { if (root.running) root.runMain() }
    }

    // собирает команду для auto_lrc.py из настроек формы и запускает её
    function runMain() {
        const lyricsArg = root.mode === "paste" ? root.tmpLyrics
                         : root.mode === "transcribe" ? "-"
                         : root.lyricsPath
        const out = root.outFile()

        // -u без буферизации, чтобы лог шёл сразу а не в конце; --progress даёт метки этапов для статуса
        const args = ["python3", "-u", root.scriptPath, lyricsArg, root.source,
                      "-o", out, "--lang", root.lang, "--model", root.model,
                      "--ui", root.uiLang === "ru" ? "ru" : "en", "--progress"]
        if (root.mode === "transcribe") args.push("--transcribe")
        if (root.vocals) args.push("--vocals")
        if (root.tail) args.push("--tail")

        root.lastOut = out
        proc.command = args
        proc.running = true
    }

    // разбирает одну строку вывода скрипта: метка этапа идёт в статус, всё остальное в лог
    function onLine(data, isErr) {
        if (data.indexOf("@@stage:") === 0) {
            root.stage = data.substring(8).trim()
            return
        }
        logModel.append({ line: data })
        if (isErr && data.trim().length) root.lastLine = data.trim()
    }

    Process {
        id: proc
        running: false
        stdout: SplitParser { onRead: data => root.onLine(data, false) }
        stderr: SplitParser { onRead: data => root.onLine(data, true) }
        onExited: (code, status) => {
            if (!root.running) return
            if (code === 0) {
                root.state = "done"
            } else {
                root.exitCode = code
                root.state = "error"
            }
        }
    }

    ListModel { id: logModel }

    Process { id: openResultProc; running: false }


    // ─────────────────────────── UI ───────────────────────────
    Rectangle {
        id: card
        anchors.fill: parent
        radius: root.cr
        color: root.colGlass

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: root.pad
            spacing: 10

            // ── шапка: бейдж, заголовок/подзаголовок, закрыть ──
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 28

                Rectangle { id: badge; width: 28; height: 28; radius: root.cr; color: root.colSecondary

                    Text {
                        anchors.centerIn: parent
                        text: "\uf001"
                        color: root.colAccent
                        font.pixelSize: 14
                        font.family: root.fontFamily
                    }
                }

                Column {
                    anchors.left: badge.right
                    anchors.leftMargin: 10
                    anchors.right: closeBtn.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1

                    Text {
                        width: parent.width
                        text: root.t("lrc.title")
                        color: root.colText
                        font.pixelSize: 13
                        font.bold: true
                        font.family: root.fontFamily
                        elide: Text.ElideRight
                    }

                    Text {
                        width: parent.width
                        text: root.t("lrc.subtitle")
                        color: Qt.alpha(root.colText, 0.55)
                        font.pixelSize: 10
                        font.family: root.fontFamily
                        elide: Text.ElideRight
                    }
                }

                Rectangle {
                    id: closeBtn
                    anchors.right: parent.right
                    width: 28
                    height: 28
                    radius: root.cr
                    color: Qt.alpha(root.colText, closeMa.containsMouse ? 0.12 : 0.06)

                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        text: "✕"
                        color: root.colAccent
                        font.pixelSize: 12
                        font.family: root.fontFamily
                    }

                    MouseArea {
                        id: closeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.closePanel()
                    }
                }
            }

            // ═══ шаг 1: текст песни ═══
            Text {
                Layout.topMargin: 4
                text: root.t("lrc.step.lyrics")
                color: Qt.alpha(root.colText, 0.55)
                font.pixelSize: 10
                font.bold: true
                font.family: root.fontFamily
            }

            RowLayout {
                spacing: 6
                Layout.fillWidth: true

                Repeater {
                    model: ["paste", "file", "transcribe"]

                    Rectangle {
                        id: tab
                        required property string modelData
                        readonly property bool active: root.mode === modelData

                        Layout.fillWidth: true
                        Layout.preferredHeight: 28
                        radius: root.cr
                        color: active ? root.colAccent
                             : Qt.alpha(root.colText, tabMa.containsMouse ? 0.12 : 0.06)

                        Behavior on color { ColorAnimation { duration: 150 } }

                        Text {
                            anchors.centerIn: parent
                            text: root.t("lrc.mode." + tab.modelData)
                            color: tab.active ? root.colBg : Qt.alpha(root.colText, 0.85)
                            font.pixelSize: 11
                            font.bold: true
                            font.family: root.fontFamily
                        }

                        MouseArea {
                            id: tabMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.mode = tab.modelData
                        }
                    }
                }
            }

            // что делает выбранный режим
            Text {
                Layout.fillWidth: true
                Layout.preferredHeight: 26
                text: root.t("lrc.mode." + root.mode + ".hint")
                color: Qt.alpha(root.colText, 0.55)
                font.pixelSize: 10
                font.family: root.fontFamily
                wrapMode: Text.Wrap
                verticalAlignment: Text.AlignTop
            }

            // вставка текста
            Rectangle {
                visible: root.mode === "paste"
                Layout.fillWidth: true
                Layout.preferredHeight: 110
                radius: root.cr
                color: Qt.alpha(root.colText, 0.06)
                border.width: 1
                border.color: pasteArea.activeFocus ? Qt.alpha(root.colAccent, 0.6) : "transparent"

                Behavior on border.color { ColorAnimation { duration: 150 } }

                ScrollView {
                    anchors.fill: parent
                    anchors.margins: 2
                    clip: true

                    TextArea {
                        id: pasteArea
                        placeholderText: root.t("lrc.paste.placeholder")
                        placeholderTextColor: Qt.alpha(root.colText, 0.4)
                        wrapMode: TextArea.Wrap
                        color: root.colText
                        selectionColor: root.colAccent
                        selectedTextColor: root.colBg
                        font.pixelSize: 12
                        font.family: root.fontFamily
                        leftPadding: 8;  rightPadding: 8
                        topPadding: 6
                        bottomPadding: 6
                        background: null
                        onTextChanged: root.lyricsText = text
                    }
                }
            }

            // путь к .txt
            RowLayout {
                visible: root.mode === "file"
                Layout.fillWidth: true
                spacing: 10

                Text {
                    Layout.preferredWidth: root.labelW
                    text: root.t("lrc.file.label")
                    color: Qt.alpha(root.colText, 0.55)
                    font.pixelSize: 10
                    font.family: root.fontFamily
                    elide: Text.ElideRight
                }

                TextField {
                    id: pathField
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    placeholderText: root.t("lrc.file.placeholder")
                    placeholderTextColor: Qt.alpha(root.colText, 0.4)
                    color: root.colText
                    selectionColor: root.colAccent
                    selectedTextColor: root.colBg
                    font.pixelSize: 12
                    font.family: root.fontFamily
                    leftPadding: 10
                    rightPadding: 10
                    verticalAlignment: TextInput.AlignVCenter
                    background: Rectangle {
                        radius: root.cr
                        color: Qt.alpha(root.colText, 0.06)
                        border.width: 1
                        border.color: pathField.activeFocus ? Qt.alpha(root.colAccent, 0.6) : "transparent"
                        Behavior on border.color { ColorAnimation { duration: 150 } }
                    }
                    onTextChanged: root.lyricsPath = text
                }
            }

            // ═══ шаг 2: звук ═══
            Text {
                Layout.topMargin: 4
                text: root.t("lrc.step.audio")
                color: Qt.alpha(root.colText, 0.55)
                font.pixelSize: 10
                font.bold: true
                font.family: root.fontFamily
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    Layout.preferredWidth: root.labelW
                    text: root.t("lrc.source.label")
                    color: Qt.alpha(root.colText, 0.55)
                    font.pixelSize: 10
                    font.family: root.fontFamily
                    elide: Text.ElideRight
                }

                TextField {
                    id: srcField
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    placeholderText: root.t("lrc.source.placeholder")
                    placeholderTextColor: Qt.alpha(root.colText, 0.4)
                    color: root.colText
                    selectionColor: root.colAccent
                    selectedTextColor: root.colBg
                    font.pixelSize: 12
                    font.family: root.fontFamily
                    leftPadding: 10
                    rightPadding: 10
                    verticalAlignment: TextInput.AlignVCenter
                    background: Rectangle {
                        radius: root.cr
                        color: Qt.alpha(root.colText, 0.06)
                        border.width: 1
                        border.color: srcField.activeFocus ? Qt.alpha(root.colAccent, 0.6) : "transparent"
                        Behavior on border.color { ColorAnimation { duration: 150 } }
                    }
                    onTextChanged: root.source = text
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    Layout.preferredWidth: root.labelW
                    text: root.t("lrc.name.label")
                    color: Qt.alpha(root.colText, 0.55)
                    font.pixelSize: 10
                    font.family: root.fontFamily
                    elide: Text.ElideRight
                }

                TextField {
                    id: nameField
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    placeholderText: root.t("lrc.name.placeholder")
                    placeholderTextColor: Qt.alpha(root.colText, 0.4)
                    color: root.colText
                    selectionColor: root.colAccent
                    selectedTextColor: root.colBg
                    font.pixelSize: 12
                    font.family: root.fontFamily
                    leftPadding: 10
                    rightPadding: 10
                    verticalAlignment: TextInput.AlignVCenter
                    background: Rectangle {
                        radius: root.cr
                        color: Qt.alpha(root.colText, 0.06)
                        border.width: 1
                        border.color: nameField.activeFocus ? Qt.alpha(root.colAccent, 0.6) : "transparent"
                        Behavior on border.color { ColorAnimation { duration: 150 } }
                    }
                    onTextChanged: root.outName = text
                }
            }

            // куда ляжет результат
            Text {
                Layout.fillWidth: true
                text: root.t("lrc.save.to").replace("%1", root.outFile())
                color: Qt.alpha(root.colText, 0.45)
                font.pixelSize: 10
                font.family: root.fontFamily
                elide: Text.ElideMiddle
            }

            // ═══ шаг 3: настройки ═══
            Text {
                Layout.topMargin: 4
                text: root.t("lrc.step.options")
                color: Qt.alpha(root.colText, 0.55)
                font.pixelSize: 10
                font.bold: true
                font.family: root.fontFamily
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    text: root.t("lrc.songlang.label")
                    color: Qt.alpha(root.colText, 0.55)
                    font.pixelSize: 10
                    font.family: root.fontFamily
                }

                ComboBox {
                    id: songLangBox
                    Layout.preferredWidth: 130
                    Layout.preferredHeight: 28
                    model: [
                        { code: "ru", name: "Русский" },
                        { code: "en", name: "English" },
                        { code: "uk", name: "Українська" },
                        { code: "de", name: "Deutsch" },
                        { code: "fr", name: "Français" },
                        { code: "es", name: "Español" }
                    ]
                    textRole: "name"
                    currentIndex: 0
                    font.pixelSize: 11
                    font.family: root.fontFamily
                    onCurrentIndexChanged: {
                        if (currentIndex >= 0) root.lang = songLangBox.model[currentIndex].code
                    }

                    background: Rectangle {
                        radius: root.cr
                        color: Qt.alpha(root.colText, (songLangBox.hovered || songLangBox.popup.visible) ? 0.12 : 0.06)
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }
                    contentItem: Text {
                        leftPadding: 10
                        text: songLangBox.displayText
                        color: root.colText
                        font: songLangBox.font
                        verticalAlignment: Text.AlignVCenter
                    }
                    indicator: Text {
                        x: songLangBox.width - width - 10
                        y: (songLangBox.height - height) / 2
                        text: "\uf078"
                        color: root.colAccent
                        font.pixelSize: 8
                        font.family: root.fontFamily
                    }
                    delegate: ItemDelegate {
                        id: songLangItem
                        required property var modelData
                        required property int index
                        width: songLangBox.width - 8
                        height: 26
                        highlighted: songLangBox.highlightedIndex === index
                        contentItem: Text {
                            leftPadding: 6
                            text: songLangItem.modelData.name
                            color: songLangItem.highlighted ? root.colBg : root.colText
                            font: songLangBox.font
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            radius: root.cr
                            color: songLangItem.highlighted ? root.colAccent : "transparent"
                        }
                    }
                    popup: Popup {
                        y: songLangBox.height + 4
                        width: songLangBox.width
                        padding: 4
                        contentItem: ListView {
                            clip: true
                            implicitHeight: contentHeight
                            model: songLangBox.popup.visible ? songLangBox.delegateModel : null
                            currentIndex: songLangBox.highlightedIndex
                            boundsBehavior: Flickable.StopAtBounds
                        }
                        background: Rectangle {
                            radius: root.cr
                            color: root.colBg
                            border.width: 1
                            border.color: Qt.alpha(root.colText, 0.08)
                        }
                    }
                }

                Text {
                    Layout.leftMargin: 8
                    text: root.t("lrc.model.label")
                    color: Qt.alpha(root.colText, 0.55)
                    font.pixelSize: 10
                    font.family: root.fontFamily
                }

                ComboBox {
                    id: modelBox
                    Layout.preferredWidth: 120
                    Layout.preferredHeight: 28
                    model: ["tiny", "base", "small", "medium", "large-v3"]
                    currentIndex: 3
                    font.pixelSize: 11
                    font.family: root.fontFamily
                    onCurrentTextChanged: root.model = currentText

                    background: Rectangle {
                        radius: root.cr
                        color: Qt.alpha(root.colText, (modelBox.hovered || modelBox.popup.visible) ? 0.12 : 0.06)
                        Behavior on color { ColorAnimation { duration: 150 } }
                    }
                    contentItem: Text {
                        leftPadding: 10
                        text: modelBox.displayText
                        color: root.colText
                        font: modelBox.font
                        verticalAlignment: Text.AlignVCenter
                    }
                    indicator: Text {
                        x: modelBox.width - width - 10
                        y: (modelBox.height - height) / 2
                        text: "\uf078"
                        color: root.colAccent
                        font.pixelSize: 8
                        font.family: root.fontFamily
                    }
                    delegate: ItemDelegate {
                        id: modelItem
                        required property var modelData
                        required property int index
                        width: modelBox.width - 8
                        height: 26
                        highlighted: modelBox.highlightedIndex === index
                        contentItem: Text {
                            leftPadding: 6
                            text: modelItem.modelData
                            color: modelItem.highlighted ? root.colBg : root.colText
                            font: modelBox.font
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            radius: root.cr
                            color: modelItem.highlighted ? root.colAccent : "transparent"
                        }
                    }
                    popup: Popup {
                        y: modelBox.height + 4
                        width: modelBox.width
                        padding: 4
                        contentItem: ListView {
                            clip: true
                            implicitHeight: contentHeight
                            model: modelBox.popup.visible ? modelBox.delegateModel : null
                            currentIndex: modelBox.highlightedIndex
                            boundsBehavior: Flickable.StopAtBounds
                        }
                        background: Rectangle {
                            radius: root.cr
                            color: root.colBg
                            border.width: 1
                            border.color: Qt.alpha(root.colText, 0.08)
                        }
                    }
                }

                Item { Layout.fillWidth: true }
            }

            // что значит выбранная модель
            Text {
                Layout.fillWidth: true
                text: root.t("lrc.model." + root.model + ".hint")
                color: Qt.alpha(root.colText, 0.45)
                font.pixelSize: 10
                font.family: root.fontFamily
                elide: Text.ElideRight
            }

            // опция: вокал
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                CheckBox {
                    id: vocalsCb
                    text: root.t("lrc.opt.vocals")
                    padding: 0
                    onCheckedChanged: root.vocals = checked
                    indicator: Rectangle {
                        implicitWidth: 16
                        implicitHeight: 16
                        x: 0
                        y: (vocalsCb.height - height) / 2
                        radius: 4
                        color: vocalsCb.checked ? root.colAccent : Qt.alpha(root.colText, vocalsCb.hovered ? 0.12 : 0.06)
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Text {
                            anchors.centerIn: parent
                            visible: vocalsCb.checked
                            text: "✓"
                            color: root.colBg
                            font.pixelSize: 11
                            font.bold: true
                            font.family: root.fontFamily
                        }
                    }
                    contentItem: Text {
                        text: vocalsCb.text
                        color: root.colText
                        leftPadding: 16 + 8
                        verticalAlignment: Text.AlignVCenter
                        font.pixelSize: 11
                        font.family: root.fontFamily
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    text: root.t("lrc.opt.vocals.hint")
                    color: Qt.alpha(root.colText, 0.45)
                    font.pixelSize: 10
                    font.family: root.fontFamily
                    elide: Text.ElideRight
                }
            }

            // опция: концовка
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                CheckBox {
                    id: tailCb
                    text: root.t("lrc.opt.tail")
                    padding: 0
                    onCheckedChanged: root.tail = checked
                    indicator: Rectangle {
                        implicitWidth: 16
                        implicitHeight: 16
                        x: 0
                        y: (tailCb.height - height) / 2
                        radius: 4
                        color: tailCb.checked ? root.colAccent : Qt.alpha(root.colText, tailCb.hovered ? 0.12 : 0.06)
                        Behavior on color { ColorAnimation { duration: 150 } }
                        Text {
                            anchors.centerIn: parent
                            visible: tailCb.checked
                            text: "✓"
                            color: root.colBg
                            font.pixelSize: 11
                            font.bold: true
                            font.family: root.fontFamily
                        }
                    }
                    contentItem: Text {
                        text: tailCb.text
                        color: root.colText
                        leftPadding: 16 + 8
                        verticalAlignment: Text.AlignVCenter
                        font.pixelSize: 11
                        font.family: root.fontFamily
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.leftMargin: 24
                    text: root.t("lrc.opt.tail.hint")
                    color: Qt.alpha(root.colText, 0.45)
                    font.pixelSize: 10
                    font.family: root.fontFamily
                    elide: Text.ElideRight
                }
            }

            // ── лог ──
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 60
                radius: root.cr
                color: Qt.alpha(root.colText, 0.04)

                Text {
                    anchors.centerIn: parent
                    width: parent.width - 24
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    visible: logModel.count === 0
                    text: root.t("lrc.log.empty")
                    color: Qt.alpha(root.colText, 0.35)
                    font.pixelSize: 11
                    font.family: root.fontFamily
                }

                ListView {
                    id: logView
                    anchors.fill: parent
                    anchors.margins: 8
                    clip: true
                    spacing: 1
                    model: logModel
                    boundsBehavior: Flickable.StopAtBounds
                    onCountChanged: positionViewAtEnd()

                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AsNeeded
                        contentItem: Rectangle {
                            implicitWidth: 3
                            radius: 1.5
                            color: Qt.alpha(root.colAccent, 0.5)
                        }
                        background: Item {}
                    }

                    delegate: Text {
                        width: logView.width - 8
                        text: line
                        color: Qt.alpha(root.colText, 0.75)
                        font.pixelSize: 10
                        font.family: root.fontFamily
                        wrapMode: Text.Wrap
                    }
                }
            }

            // ── статус ──
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Rectangle {
                    id: statusDot
                    property real pulse: 1.0
                    width: 6
                    height: 6
                    radius: 3
                    color: root.statusColor
                    opacity: root.running ? pulse : (root.state === "idle" ? 0.4 : 1.0)

                    SequentialAnimation on pulse {
                        running: root.running
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.25; duration: 600; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutSine }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: root.statusText
                    color: root.statusColor
                    font.pixelSize: 11
                    font.family: root.fontFamily
                    elide: Text.ElideMiddle
                }
            }

            // ── кнопки: запустить / отмена / открыть результат ──
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    radius: root.cr
                    color: root.running ? Qt.alpha(root.colText, 0.08)
                         : runMa.containsMouse ? Qt.lighter(root.colAccent, 1.12) : root.colAccent

                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        text: root.running ? root.t("lrc.btn.running") : root.t("lrc.btn.run")
                        color: root.running ? Qt.alpha(root.colText, 0.7) : root.colBg
                        font.pixelSize: 12
                        font.bold: true
                        font.family: root.fontFamily
                    }

                    MouseArea {
                        id: runMa
                        anchors.fill: parent
                        enabled: !root.running
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.start()
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 110
                    Layout.preferredHeight: 32
                    visible: root.running
                    radius: root.cr
                    color: cancelMa.containsMouse ? root.colDanger : Qt.alpha(root.colDanger, 0.18)

                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        text: root.t("lrc.btn.cancel")
                        color: cancelMa.containsMouse ? root.colBg : root.colDanger
                        font.pixelSize: 11
                        font.bold: true
                        font.family: root.fontFamily
                    }

                    MouseArea {
                        id: cancelMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.cancel()
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 160
                    Layout.preferredHeight: 32
                    visible: root.state === "done" && root.lastOut.length > 0
                    radius: root.cr
                    color: openMa.containsMouse ? root.colAccent : Qt.alpha(root.colText, 0.07)

                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        anchors.centerIn: parent
                        text: root.t("lrc.btn.open")
                        color: openMa.containsMouse ? root.colBg : Qt.alpha(root.colText, 0.85)
                        font.pixelSize: 11
                        font.bold: true
                        font.family: root.fontFamily
                    }

                    MouseArea {
                        id: openMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { openResultProc.command = ["xdg-open", root.lastOut]; openResultProc.running = true }
                    }
                }
            }
        }
    }
}
