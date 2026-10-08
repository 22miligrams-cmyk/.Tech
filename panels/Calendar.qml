import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../bar"
import "../notifications"
import "../settings"
import "../common"
import "../lang"
import "../icons"

PanelWindow {
    id: cal

    function tr(key) { return Tr.tr(key) }

    // перевод, если ключа нет в lang/*.qml — берём запасной текст
    function t(key, fb) {
        const v = Tr.tr(key)
        return (v && v !== key) ? v : fb
    }


    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary
    required property color colGlass

    property var now: new Date()

    property string side: "bottom"

    property var anchorRect: ({ x: 0, y: 0, w: 0, h: 0, lo: 0, hi: 0 })

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"
    readonly property var monthNames: Tr.list("cal.months")
    readonly property var monthGen: Tr.list("cal.monthsGen")
    readonly property var dayShort: Tr.list("cal.days")
    readonly property var dayFull: Tr.list("cal.daysFull")


    // заметки и будильники
    property string dataFile: Paths.home + "/.cache/quickshell/calendar-data.json"
    property bool alarmNotify: false   // дублировать звонок обычным уведомлением (notify-send)
    property int snoozeMin: 5
    property int soundRepeats: 1       // сколько раз играет звук (1 = один раз)
    readonly property int ringActive: cw.ringActive   // сколько сработавших будильников ещё не закрыли
    property string alarmSound: "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"

    property var notes: ({})        // { "2026-10-05": "текст" }
    property var alarms: []         // [{ id, ts, label, done }]
    property int noteRev: 0
    property int alarmRev: 0
    property real clockMs: Date.now()
    property bool noteLoading: false
    property bool instant: false    // сброс без анимации

    // вид
    property bool isClosing: false
    property real p: 0
    property int viewYear: 2000     // что выбрано (меняется сразу)
    property int viewMonth: 0
    // позиция карусели в месяцах (y*12+m), дробное = идёт пролистывание
    property real pos: 24000
    property real lastWheel: 0

    // выбранный день
    property bool hasSel: false
    property int selY: 0
    property int selM: 0
    property int selD: 1
    readonly property string selKey: hasSel ? dateKey(selY, selM, selD) : ""
    property string shownKey: ""
    property real dayOp: 1
    property real dayOpenF: hasSel ? 1 : 0
    property real dayH: dayCol.implicitHeight + 8

    Behavior on dayOpenF {
        enabled: !cal.instant
        NumberAnimation { duration: 230; easing.type: Easing.OutCubic }
    }
    Behavior on dayH {
        enabled: !cal.instant
        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
    }

    // время нового будильника
    property int alH: 8
    property int alM: 0
    readonly property bool canAdd: hasSel && alarmTsAt(selY, selM, selD, alH, alM) > clockMs

    readonly property int todayY: now ? now.getFullYear() : 0
    readonly property int todayM: now ? now.getMonth() : 0
    readonly property int todayD: now ? now.getDate() : 0
    readonly property int todayW: now ? now.getDay() : 0
    readonly property bool onCurrentMonth: viewYear === todayY && viewMonth === todayM

    readonly property bool horiz: side === "top" || side === "bottom"
    readonly property real pad: 14
    readonly property real cr: 6
    readonly property real pw: horiz ? Math.max(280, anchorRect.w) : 280
    readonly property real ph: body.implicitHeight + pad * 2
    readonly property real cellW: Math.floor((pw - pad * 2) / 7)
    readonly property real cellH: 32
    readonly property real rowGap: 2
    readonly property real gridH: cellH * 6 + rowGap * 5
    readonly property real dowH: 26   // строка дней недели (18) + отступ (8)

    // индекс выбранного дня в сетке месяца (или -1)
    function selIndexIn(idx, has, sy, sm, sd) {
        if (!has) return -1
        const gy = Math.floor(idx / 12)
        const gm = idx % 12
        const off = (new Date(gy, gm, 1).getDay() + 6) % 7
        const diff = Math.round((Date.UTC(sy, sm, sd) - Date.UTC(gy, gm, 1)) / 86400000)
        const i = diff + off
        return (i >= 0 && i < 42) ? i : -1
    }

    function clamp(v, lo, hi) {
        return Math.max(lo, Math.min(v, hi))
    }

    readonly property real floatGap: 8
    readonly property bool fused: horiz ? anchorRect.w >= pw - 0.5 : anchorRect.h >= ph - 0.5
    readonly property real gapNow: fused ? 0 : floatGap

    readonly property real px: side === "left" ? anchorRect.x + anchorRect.w + gapNow
        : side === "right" ? anchorRect.x - pw - gapNow
        : clamp(anchorRect.x + anchorRect.w / 2 - pw / 2, 8, width - 8 - pw)

    readonly property real py: side === "bottom" ? anchorRect.y - ph - gapNow
        : side === "top" ? anchorRect.y + anchorRect.h + gapNow
        : clamp(anchorRect.y + anchorRect.h / 2 - ph / 2, 8, height - 8 - ph)

    function sq(v) {
        return fused && v >= anchorRect.lo - 0.5 && v <= anchorRect.hi + 0.5
    }

    readonly property bool covers: fused && (horiz
        ? (px <= anchorRect.x + 0.5 && px + pw >= anchorRect.x + anchorRect.w - 0.5)
        : (py <= anchorRect.y + 0.5 && py + ph >= anchorRect.y + anchorRect.h - 0.5))

    // даты
    function pad2(n) { return (n < 10 ? "0" : "") + n }
    function dateKey(y, m, d) { return y + "-" + pad2(m + 1) + "-" + pad2(d) }
    function fmtTime(ts) {
        const d = new Date(ts)
        return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
    }
    function alarmTsAt(y, m, d, h, mi) {
        return new Date(y, m, d, h, mi, 0, 0).getTime()
    }

    function shownTitle() {
        if (!shownKey) return ""
        const p = shownKey.split("-")
        const dt = new Date(parseInt(p[0]), parseInt(p[1]) - 1, parseInt(p[2]))
        let s = dayFull[dt.getDay()] + ", " + dt.getDate() + " " + monthGen[dt.getMonth()]
        if (dt.getFullYear() !== todayY) s += " " + dt.getFullYear()
        return s
    }

    // листаем месяцы
    function setView(y, m, animate) {
        const old = viewYear * 12 + viewMonth
        const t = y * 12 + m
        viewYear = y
        viewMonth = m
        slideAnim.stop()
        if (!animate) {
            pos = t
            return
        }
        // если прыжок длинный (год) — сперва на соседнюю страницу, оттуда плавно доезжаем
        if (Math.abs(t - old) > 1)
            pos = t - (t > old ? 1 : -1)
        slideAnim.to = t
        slideAnim.start()
    }

    function goToday(animate) {
        const d = now ? now : new Date()
        const y = d.getFullYear()
        const m = d.getMonth()
        if (animate === false) {
            setView(y, m, false)
            return
        }
        if (y === viewYear && m === viewMonth) return
        setView(y, m, true)
    }

    function shiftMonth(delta) {
        const idx = viewYear * 12 + viewMonth + delta
        setView(Math.floor(idx / 12), ((idx % 12) + 12) % 12, true)
    }

    function wheelStep(e) {
        const tm = Date.now()
        if (tm - lastWheel < 130) return
        lastWheel = tm
        shiftMonth(e.angleDelta.y > 0 ? -1 : 1)
    }

    function cellsFor(idx) {
        const gy = Math.floor(idx / 12)
        const gm = idx % 12
        const first = new Date(gy, gm, 1)
        const offset = (first.getDay() + 6) % 7
        const dim = new Date(gy, gm + 1, 0).getDate()
        const out = []
        for (let i = 0; i < 42; i++) {
            const dt = new Date(gy, gm, i - offset + 1)
            const d = i - offset + 1
            out.push({
                day: dt.getDate(),
                y: dt.getFullYear(),
                m: dt.getMonth(),
                cur: d >= 1 && d <= dim
            })
        }
        return out
    }
    // выбор дня
    function selectDay(y, m, d) {
        const k = dateKey(y, m, d)
        if (hasSel && k === selKey) {
            hasSel = false
            keys.forceActiveFocus()
            return
        }
        const wasOpen = hasSel
        selY = y
        selM = m
        selD = d
        hasSel = true

        if (y === todayY && m === todayM && d === todayD) {
            alH = Math.min(23, new Date().getHours() + 1)
            alM = 0
        }
        if (y !== viewYear || m !== viewMonth)
            setView(y, m, true)

        if (wasOpen) {
            dayFade.restart()
        } else {
            dayFade.stop()
            dayOp = 1
            shownKey = selKey
        }
        keys.forceActiveFocus()
    }

    onShownKeyChanged: {
        noteLoading = true
        noteEd.text = noteFor(shownKey)
        noteLoading = false
    }

    // заметки
    function noteFor(key) { return notes[key] || "" }

    function noteExists(y, m, d, rev) { return !!notes[dateKey(y, m, d)] }

    function setNote(key, text) {
        if (!key) return
        const n = Object.assign({}, notes)
        if (text.trim() === "") delete n[key]
        else n[key] = text
        notes = n
        noteRev++
        save()
    }

    // будильники
    function alarmsFor(key, rev) {
        const out = []
        for (let i = 0; i < alarms.length; i++) {
            const a = alarms[i]
            const dt = new Date(a.ts)
            if (dateKey(dt.getFullYear(), dt.getMonth(), dt.getDate()) === key)
                out.push(a)
        }
        out.sort((a, b) => a.ts - b.ts)
        return out
    }

    function alarmCount(y, m, d, rev) {
        let c = 0
        for (let i = 0; i < alarms.length; i++) {
            const a = alarms[i]
            if (a.done) continue
            const dt = new Date(a.ts)
            if (dt.getFullYear() === y && dt.getMonth() === m && dt.getDate() === d) c++
        }
        return c
    }

    function stepTime(isH, delta) {
        if (isH) alH = (alH + delta + 24) % 24
        else alM = (alM + delta * 5 + 60) % 60
    }

    function setTime(isH, v) {
        if (isH) alH = clamp(v, 0, 23)
        else alM = clamp(v, 0, 59)
    }

    function addAlarm(y, m, d, h, mi, label) {
        const ts = alarmTsAt(y, m, d, h, mi)
        if (ts <= Date.now()) return
        const list = alarms.slice()
        list.push({
            id: Date.now().toString(36) + Math.floor(Math.random() * 46656).toString(36),
            ts: ts,
            label: label,
            done: false
        })
        alarms = list
        alarmRev++
        save()
    }

    function commitAlarm() {
        if (!hasSel || !canAdd) return
        addAlarm(selY, selM, selD, alH, alM, labelInput.text.trim())
        labelInput.text = ""
    }
    function removeAlarm(id) {
        alarms = alarms.filter(a => a.id !== id)
        alarmRev++
        save()
    }

    // будильник сработал -> открываем окно Cw.qml
    function ring(a) {
        const dt = new Date(a.ts)
        cw.show(a.id, fmtTime(a.ts), a.label || "",
                noteFor(dateKey(dt.getFullYear(), dt.getMonth(), dt.getDate())))
        if (alarmNotify) {
            Quickshell.execDetached(["notify-send", "-u", "critical", "-a", "Calendar",
                "-i", "alarm-clock", "⏰ " + t("cal.alarmRing", "Будильник"),
                fmtTime(a.ts) + (a.label ? " — " + a.label : "")])
        }
    }

    // «Отложить»: новый одноразовый будильник через snoozeMin минут
    function snoozeAlarm(label) {
        const list = alarms.slice()
        list.push({
            id: Date.now().toString(36) + Math.floor(Math.random() * 46656).toString(36),
            ts: Date.now() + snoozeMin * 60000,
            label: label,
            done: false
        })
        alarms = list
        alarmRev++
        save()
    }

    function checkAlarms() {
        const tm = Date.now()
        let changed = false
        const list = alarms.map(a => {
            if (!a.done && tm >= a.ts) {
                changed = true
                // если шелл был выключен дольше 10 минут — не звоним за прошлое
                if (tm - a.ts <= 600000) ring(a)
                return { id: a.id, ts: a.ts, label: a.label, done: true }
            }
            return a
        })
        if (changed) {
            alarms = list
            alarmRev++
            save()
        }
    }
    // сохранение / загрузка
    function loadData() {
        let raw = ""
        try { raw = store.text() } catch (e) { raw = "" }
        if (!raw || raw.trim() === "") return
        try {
            const o = JSON.parse(raw)
            notes = o.notes || {}
            alarms = (o.alarms || []).filter(a => a && typeof a.ts === "number")
            noteRev++
            alarmRev++
        } catch (e) {
            console.warn("Calendar: не удалось прочитать", dataFile, e)
            Quickshell.execDetached(["cp", dataFile, dataFile + ".bad"])
        }
    }

    function save() { saveTimer.restart() }

    function flush() {
        store.setText(JSON.stringify({ notes: notes, alarms: alarms }, null, 1))
    }

    Component.onCompleted: loadData()
    Component.onDestruction: {
        if (saveTimer.running) {
            saveTimer.stop()
            flush()
        }
    }

    // окно сработавшего будильника, блюр как у панели, рамки нет
    Cw {
        id: cw
        screen: cal.screen
        colBg: cal.colBg
        colAccent: cal.colAccent
        colText: cal.colText
        colGlass: cal.colGlass
        wallpaper: cal.wallpaper
        blurEnabled: cal.blurEnabled
        blurRadius: cal.blurRadius
        blurTint: cal.blurTint
        fontFamily: cal.fontFamily
        cr: cal.cr
        snoozeMin: cal.snoozeMin
        sound: cal.alarmSound
        soundRepeats: cal.soundRepeats
        onSnoozeRequested: (label) => cal.snoozeAlarm(label)
    }


    FileView {
        id: store
        path: cal.dataFile
        blockLoading: true
        printErrors: false
    }

    Timer {
        id: saveTimer
        interval: 300
        onTriggered: cal.flush()
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            cal.clockMs = Date.now()
            cal.checkAlarms()
        }
    }

    function toggleMenu() {
        if (isClosing)
            return

        if (visible) {
            isClosing = true
            openAnim.stop()
            closeAnim.start()
        } else {
            goToday(false)
            p = 0
            visible = true
            openAnim.restart()
            keys.forceActiveFocus()
        }
    }
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore

    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "calendar-menu"
    visible: false

    property string wallpaper: ""
    property bool blurEnabled: true
    property real blurRadius: 16
    property color blurTint: Qt.rgba(0.05, 0.05, 0.07, 0.25)

    LiveBackdrop {
        id: backdrop
        screenObj: cal.screen
        wallpaper: cal.wallpaper
        autoDetect: false
        active: cal.visible && cal.blurEnabled
        roi: Qt.rect(cal.px, cal.py, cal.pw, cal.ph)
        pollInterval: 700
        texScale: 0.5
        x: -width - 64
        y: -height - 64
    }

    Item {
        id: keys
        anchors.fill: parent
        focus: true

        Keys.onEscapePressed: cal.toggleMenu()
        Keys.onLeftPressed: cal.shiftMonth(-1)
        Keys.onRightPressed: cal.shiftMonth(1)
        Keys.onUpPressed: cal.shiftMonth(-12)
        Keys.onDownPressed: cal.shiftMonth(12)
        Keys.onPressed: (e) => {
            if (e.key === Qt.Key_Home || e.key === Qt.Key_T) cal.goToday()
        }


        MouseArea {
            anchors.fill: parent
            onClicked: cal.toggleMenu()
        }

        NumberAnimation {
            id: openAnim
            target: cal
            property: "p"
            to: 1
            duration: 300
            easing.type: Easing.OutCubic
        }

        NumberAnimation {
            id: closeAnim
            target: cal
            property: "p"
            to: 0
            duration: 210
            easing.type: Easing.InCubic
            onFinished: {
                cal.visible = false
                cal.isClosing = false
                cal.instant = true
                cal.hasSel = false
                cal.shownKey = ""
                cal.instant = false
            }
        }

        // листание месяцев: обе страницы едут вместе, анимацию можно прервать в любой момент
        NumberAnimation {
            id: slideAnim
            target: cal
            property: "pos"
            duration: 320
            easing.type: Easing.OutQuart
        }
        // смена выбранного дня — содержимое блока дня плавно подменяется
        SequentialAnimation {
            id: dayFade
            NumberAnimation { target: cal; property: "dayOp"; to: 0; duration: 90 }
            ScriptAction { script: cal.shownKey = cal.selKey }
            NumberAnimation { target: cal; property: "dayOp"; to: 1; duration: 150 }
        }

        Item {
            id: holder
            x: cal.px
            y: cal.py
            width: cal.pw
            height: cal.ph
            clip: true

            BarBlur {
                source: (cal.blurEnabled && backdrop.width > 0) ? backdrop.texture : null
                srcSize: Qt.size(backdrop.width, backdrop.height)
                originX: holder.x
                originY: holder.y
                rect: ({ x: panel.x, y: panel.y, w: panel.width, h: panel.height })
                corners: Qt.vector4d(panel.topLeftRadius, panel.topRightRadius,
                                     panel.bottomRightRadius, panel.bottomLeftRadius)
                blurRadius: cal.blurRadius
                tint: cal.blurTint
                strength: panel.opacity
            }

            Rectangle {
                id: panel
                width: holder.width
                height: holder.height

                x: cal.side === "left" ? -(1 - cal.p) * width
                 : cal.side === "right" ? (1 - cal.p) * width : 0
                y: cal.side === "bottom" ? (1 - cal.p) * height
                 : cal.side === "top" ? -(1 - cal.p) * height : 0
                opacity: Math.min(1, cal.p * 2.5)

                color: cal.colGlass

                topLeftRadius: ((cal.side === "top" && cal.sq(cal.px)) || (cal.side === "left" && cal.sq(cal.py))) ? 0 : cal.cr
                topRightRadius: ((cal.side === "top" && cal.sq(cal.px + cal.pw)) || (cal.side === "right" && cal.sq(cal.py))) ? 0 : cal.cr
                bottomLeftRadius: ((cal.side === "bottom" && cal.sq(cal.px)) || (cal.side === "left" && cal.sq(cal.py + cal.ph))) ? 0 : cal.cr
                bottomRightRadius: ((cal.side === "bottom" && cal.sq(cal.px + cal.pw)) || (cal.side === "right" && cal.sq(cal.py + cal.ph))) ? 0 : cal.cr

                MouseArea {
                    anchors.fill: parent
                    onClicked: (mouse) => {
                        mouse.accepted = true
                        keys.forceActiveFocus()
                    }
                }

                // колесом листаем месяцы по всей панели
                WheelHandler {
                    onWheel: (e) => cal.wheelStep(e)
                }

                Column {
                    id: body
                    y: cal.pad
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: cal.cellW * 7
                    spacing: 0

                    // заголовок
                    Item {
                        width: parent.width
                        height: 30

                        Rectangle {
                            id: prevBtn
                            width: 30
                            height: 30
                            radius: cal.cr
                            color: prevMa.containsMouse ? Qt.alpha(cal.colText, 0.12) : Qt.alpha(cal.colText, 0.06)

                            Behavior on color { ColorAnimation { duration: 150 } }

                            Icon {
                                anchors.centerIn: parent
                                name: "chevronLeft"
                                size: 16
                                color: cal.colAccent
                                dim: 1.3
                            }
                            MouseArea {
                                id: prevMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: cal.shiftMonth(-1)
                            }
                        }

                        Rectangle {
                            id: titleBtn
                            anchors.left: prevBtn.right
                            anchors.right: nextBtn.left
                            anchors.leftMargin: 6
                            anchors.rightMargin: 6
                            height: 30
                            radius: cal.cr
                            clip: true
                            color: titleMa.containsMouse && !cal.onCurrentMonth ? Qt.alpha(cal.colText, 0.12) : "transparent"

                            Behavior on color { ColorAnimation { duration: 150 } }

                            // название месяца едет вместе со страницей и обрезается между стрелками
                            Repeater {
                                model: 2

                                Text {
                                    required property int index
                                    readonly property int f: Math.floor(cal.pos)
                                    readonly property int idx: (f % 2 === index) ? f : f + 1
                                    x: (titleBtn.width - width) / 2 + (idx - cal.pos) * (cal.cellW * 7)
                                    y: (titleBtn.height - height) / 2
                                    visible: Math.abs(idx - cal.pos) < 1
                                    text: cal.monthNames[idx % 12] + " " + Math.floor(idx / 12)
                                    color: cal.colText
                                    font.pixelSize: 13
                                    font.bold: true
                                    font.family: cal.fontFamily
                                }
                            }


                            MouseArea {
                                id: titleMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: cal.onCurrentMonth ? Qt.ArrowCursor : Qt.PointingHandCursor
                                onClicked: cal.goToday()
                            }
                        }

                        Rectangle {
                            id: nextBtn
                            anchors.right: parent.right
                            width: 30
                            height: 30
                            radius: cal.cr
                            color: nextMa.containsMouse ? Qt.alpha(cal.colText, 0.12) : Qt.alpha(cal.colText, 0.06)

                            Behavior on color { ColorAnimation { duration: 150 } }

                            Icon {
                                anchors.centerIn: parent
                                name: "chevronRight"
                                size: 16
                                color: cal.colAccent
                                dim: 1.3
                            }

                            MouseArea {
                                id: nextMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: cal.shiftMonth(1)
                            }
                        }
                    }

                    Item { width: 1; height: 8 }

                    // сетка месяца
                    Item {
                        id: gridClip
                        width: parent.width
                        height: cal.dowH + cal.gridH
                        clip: true

                        // две страницы на одной ленте: x = (месяц - pos) * ширина
                        Repeater {
                            model: 2

                            Item {
                                id: pg
                                required property int index
                                readonly property int f: Math.floor(cal.pos)
                                readonly property int idx: (f % 2 === index) ? f : f + 1
                                readonly property int hlI: cal.selIndexIn(idx, cal.hasSel, cal.selY, cal.selM, cal.selD)
                                property int lastHl: 0
                                onHlIChanged: if (hlI >= 0) lastHl = hlI

                                width: gridClip.width
                                height: gridClip.height
                                x: (idx - cal.pos) * gridClip.width
                                visible: Math.abs(idx - cal.pos) < 1

                                // дни недели едут со своей страницей
                                Row {
                                    Repeater {
                                        model: cal.dayShort

                                        Item {
                                            required property string modelData
                                            required property int index
                                            width: cal.cellW
                                            height: 18

                                            Text {
                                                anchors.centerIn: parent
                                                text: parent.modelData
                                                color: parent.index >= 5 ? cal.colAccent : Qt.alpha(cal.colText, 0.55)
                                                font.pixelSize: 10
                                                font.bold: true
                                                font.family: cal.fontFamily
                                            }
                                        }
                                    }
                                }

                                // рамка вокруг выбранного дня
                                Rectangle {
                                    id: hl
                                    width: cal.cellW
                                    height: cal.cellH
                                    radius: cal.cr
                                    x: (pg.lastHl % 7) * cal.cellW
                                    y: cal.dowH + Math.floor(pg.lastHl / 7) * (cal.cellH + cal.rowGap)
                                    color: Qt.alpha(cal.colAccent, 0.30)
                                    opacity: pg.hlI >= 0 ? 1 : 0

                                    Behavior on opacity { NumberAnimation { duration: 160 } }
                                    Behavior on x {
                                        enabled: !slideAnim.running && hl.opacity > 0.5
                                        NumberAnimation { duration: 190; easing.type: Easing.OutCubic }
                                    }
                                    Behavior on y {
                                        enabled: !slideAnim.running && hl.opacity > 0.5
                                        NumberAnimation { duration: 190; easing.type: Easing.OutCubic }
                                    }
                                }

                                Grid {
                                    y: cal.dowH
                                    columns: 7
                                    rowSpacing: cal.rowGap
                                    columnSpacing: 0

                                    Repeater {
                                        model: cal.cellsFor(pg.idx)
                                        Rectangle {
                                            id: cell
                                            required property var modelData
                                            required property int index

                                            readonly property bool isToday: modelData.cur
                                                && modelData.y === cal.todayY
                                                && modelData.m === cal.todayM
                                                && modelData.day === cal.todayD
                                            readonly property bool hasN: cal.noteExists(modelData.y, modelData.m, modelData.day, cal.noteRev)
                                            readonly property int nAl: cal.alarmCount(modelData.y, modelData.m, modelData.day, cal.alarmRev)

                                            width: cal.cellW
                                            height: cal.cellH
                                            radius: cal.cr
                                            color: isToday ? cal.colAccent
                                                 : (cellMa.containsMouse ? Qt.alpha(cal.colText, 0.12) : "transparent")

                                            Behavior on color { ColorAnimation { duration: 150 } }

                                            Text {
                                                anchors.centerIn: parent
                                                anchors.verticalCenterOffset: (cell.hasN || cell.nAl > 0) ? -2 : 0
                                                text: cell.modelData.day
                                                color: cell.isToday ? cal.colBg
                                                     : (cell.modelData.cur
                                                        ? (cell.index % 7 >= 5 ? cal.colAccent : cal.colText)
                                                        : Qt.alpha(cal.colText, 0.28))
                                                font.pixelSize: 12
                                                font.bold: cell.isToday
                                                font.family: cal.fontFamily

                                                Behavior on anchors.verticalCenterOffset { NumberAnimation { duration: 120 } }
                                            }

                                            // точки: заметка и будильник
                                            Row {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                anchors.bottom: parent.bottom
                                                anchors.bottomMargin: 3
                                                spacing: 3

                                                Rectangle {
                                                    visible: cell.hasN
                                                    width: 4; height: 4; radius: 2
                                                    color: cell.isToday ? cal.colBg
                                                         : Qt.alpha(cal.colText, cell.modelData.cur ? 0.75 : 0.35)
                                                }
                                                Rectangle {
                                                    visible: cell.nAl > 0
                                                    width: 4; height: 4; radius: 2
                                                    color: cell.isToday ? cal.colBg : cal.colAccent
                                                }
                                            }

                                            MouseArea {
                                                id: cellMa
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: cal.selectDay(cell.modelData.y, cell.modelData.m, cell.modelData.day)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Item { width: 1; height: 8 }

                    // блок выбранного дня (заметка + будильники)
                    Item {
                        id: dayWrap
                        width: parent.width
                        height: cal.dayH * cal.dayOpenF
                        clip: true
                        visible: height > 0.5

                        Column {
                            id: dayCol
                            width: parent.width
                            spacing: 6
                            opacity: cal.dayOp * cal.dayOpenF

                            Item {
                                width: parent.width
                                height: 20

                                Text {
                                    anchors.left: parent.left
                                    anchors.right: closeBtn.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    text: cal.shownTitle()
                                    color: cal.colText
                                    font.pixelSize: 12
                                    font.bold: true
                                    font.family: cal.fontFamily
                                }

                                Rectangle {
                                    id: closeBtn
                                    anchors.right: parent.right
                                    width: 20
                                    height: 20
                                    radius: cal.cr
                                    color: closeMa.containsMouse ? Qt.alpha(cal.colText, 0.12) : "transparent"

                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    Text {
                                        anchors.centerIn: parent
                                        text: "×"
                                        color: Qt.alpha(cal.colText, 0.7)
                                        font.pixelSize: 14
                                        font.family: cal.fontFamily
                                    }

                                    MouseArea {
                                        id: closeMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            cal.hasSel = false
                                            keys.forceActiveFocus()
                                        }
                                    }
                                }
                            }

                            // заметка
                            Rectangle {
                                id: noteBox
                                width: parent.width
                                height: Math.max(52, Math.min(110, noteEd.paintedHeight + 14))
                                radius: cal.cr
                                color: Qt.alpha(cal.colText, noteEd.activeFocus ? 0.10 : 0.06)


                                Behavior on color { ColorAnimation { duration: 150 } }

                                WheelHandler { onWheel: (e) => {} }

                                Flickable {
                                    id: noteFlick
                                    anchors.fill: parent
                                    anchors.margins: 7
                                    contentWidth: width
                                    contentHeight: noteEd.paintedHeight
                                    clip: true
                                    boundsBehavior: Flickable.StopAtBounds

                                    TextEdit {
                                        id: noteEd
                                        width: noteFlick.width
                                        wrapMode: TextEdit.Wrap
                                        color: cal.colText
                                        selectionColor: cal.colAccent
                                        selectedTextColor: cal.colBg
                                        selectByMouse: true
                                        font.pixelSize: 12
                                        font.family: cal.fontFamily

                                        onTextChanged: {
                                            if (!cal.noteLoading) cal.setNote(cal.shownKey, text)
                                        }

                                        onCursorRectangleChanged: {
                                            const r = cursorRectangle
                                            if (r.y < noteFlick.contentY)
                                                noteFlick.contentY = r.y
                                            else if (r.y + r.height > noteFlick.contentY + noteFlick.height)
                                                noteFlick.contentY = r.y + r.height - noteFlick.height
                                        }

                                        Keys.onEscapePressed: (e) => {
                                            keys.forceActiveFocus()
                                            e.accepted = true
                                        }

                                        Text {
                                            visible: noteEd.text.length === 0
                                            text: cal.t("cal.notePlaceholder", "Заметка на день…")
                                            color: Qt.alpha(cal.colText, 0.35)
                                            font: noteEd.font
                                        }
                                    }
                                }
                            }

                            Text {
                                text: "\uf0f3  " + cal.t("cal.alarms", "Будильники")
                                color: Qt.alpha(cal.colText, 0.55)
                                font.pixelSize: 10
                                font.bold: true
                                font.family: cal.fontFamily
                            }

                            // будильники этого дня
                            Column {
                                id: alarmCol
                                width: parent.width
                                spacing: 0
                                visible: alarmRep.count > 0

                                Repeater {
                                    id: alarmRep
                                    model: cal.alarmsFor(cal.shownKey, cal.alarmRev)

                                    Item {
                                        id: arow
                                        required property var modelData
                                        width: alarmCol.width
                                        height: 30
                                        clip: true

                                        NumberAnimation on opacity { from: 0; to: 1; duration: 160 }

                                        ParallelAnimation {
                                            id: delAnim
                                            NumberAnimation { target: arow; property: "opacity"; to: 0; duration: 140 }
                                            NumberAnimation { target: arow; property: "height"; to: 0; duration: 170; easing.type: Easing.OutCubic }
                                            onFinished: cal.removeAlarm(arow.modelData.id)
                                        }

                                        Rectangle {
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.top: parent.top
                                            height: 26
                                            radius: cal.cr
                                            color: Qt.alpha(cal.colText, 0.06)

                                            Text {
                                                id: aTime
                                                anchors.left: parent.left
                                                anchors.leftMargin: 9
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: cal.fmtTime(arow.modelData.ts)
                                                color: arow.modelData.done ? Qt.alpha(cal.colText, 0.4) : cal.colAccent
                                                font.pixelSize: 12
                                                font.bold: true
                                                font.strikeout: arow.modelData.done
                                                font.family: cal.fontFamily
                                            }

                                            Text {
                                                anchors.left: aTime.right
                                                anchors.leftMargin: 10
                                                anchors.right: delBtn.left
                                                anchors.rightMargin: 4
                                                anchors.verticalCenter: parent.verticalCenter
                                                elide: Text.ElideRight
                                                text: arow.modelData.label
                                                color: Qt.alpha(cal.colText, arow.modelData.done ? 0.35 : 0.85)
                                                font.pixelSize: 11
                                                font.family: cal.fontFamily
                                            }

                                            Rectangle {
                                                id: delBtn
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 22
                                                height: 22
                                                radius: cal.cr
                                                color: delMa.containsMouse ? Qt.alpha(cal.colText, 0.12) : "transparent"

                                                Behavior on color { ColorAnimation { duration: 150 } }

                                                Text {
                                                    anchors.centerIn: parent
                                                    text: "×"
                                                    color: Qt.alpha(cal.colText, 0.7)
                                                    font.pixelSize: 14
                                                    font.family: cal.fontFamily
                                                }
                                                MouseArea {
                                                    id: delMa
                                                    anchors.fill: parent
                                                    hoverEnabled: true
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: delAnim.start()
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // добавление будильника: [чч:мм] [название] [+]
                            Item {
                                id: addRow
                                width: parent.width
                                height: 28

                                Row {
                                    id: timeRow
                                    spacing: 0

                                    Repeater {
                                        model: 2

                                        Item {
                                            id: tfItem
                                            required property int index
                                            readonly property bool isH: index === 0
                                            width: isH ? 56 : 44
                                            height: 28

                                            Rectangle {
                                                width: 44
                                                height: 28
                                                radius: cal.cr
                                                color: Qt.alpha(cal.colText, ti.activeFocus ? 0.12 : 0.06)

                                                Behavior on color { ColorAnimation { duration: 150 } }
                                                Binding {
                                                    target: ti
                                                    property: "text"
                                                    value: cal.pad2(tfItem.isH ? cal.alH : cal.alM)
                                                    when: !ti.activeFocus
                                                }

                                                TextInput {
                                                    id: ti
                                                    anchors.fill: parent
                                                    horizontalAlignment: TextInput.AlignHCenter
                                                    verticalAlignment: TextInput.AlignVCenter
                                                    maximumLength: 2
                                                    selectByMouse: true
                                                    inputMethodHints: Qt.ImhDigitsOnly
                                                    validator: IntValidator { bottom: 0; top: tfItem.isH ? 23 : 59 }
                                                    color: cal.colText
                                                    selectionColor: cal.colAccent
                                                    selectedTextColor: cal.colBg
                                                    font.pixelSize: 12
                                                    font.bold: true
                                                    font.family: cal.fontFamily

                                                    function commit() {
                                                        const v = parseInt(text)
                                                        if (!isNaN(v)) cal.setTime(tfItem.isH, v)
                                                        text = cal.pad2(tfItem.isH ? cal.alH : cal.alM)
                                                    }
                                                    function refresh() {
                                                        text = cal.pad2(tfItem.isH ? cal.alH : cal.alM)
                                                        selectAll()
                                                    }

                                                    onActiveFocusChanged: {
                                                        if (activeFocus) selectAll()
                                                        else commit()
                                                    }

                                                    Keys.onUpPressed: { cal.stepTime(tfItem.isH, 1); refresh() }
                                                    Keys.onDownPressed: { cal.stepTime(tfItem.isH, -1); refresh() }
                                                    Keys.onReturnPressed: { commit(); cal.commitAlarm() }
                                                    Keys.onEnterPressed: { commit(); cal.commitAlarm() }
                                                    Keys.onEscapePressed: (e) => {
                                                        keys.forceActiveFocus()
                                                        e.accepted = true
                                                    }

                                                    WheelHandler {
                                                        onWheel: (e) => {
                                                            cal.stepTime(tfItem.isH, e.angleDelta.y > 0 ? 1 : -1)
                                                            if (ti.activeFocus) ti.refresh()
                                                        }
                                                    }
                                                }
                                            }

                                            Text {
                                                visible: tfItem.isH
                                                x: 44
                                                width: 12
                                                height: 28
                                                horizontalAlignment: Text.AlignHCenter
                                                verticalAlignment: Text.AlignVCenter
                                                text: ":"
                                                color: Qt.alpha(cal.colText, 0.6)
                                                font.pixelSize: 13
                                                font.bold: true
                                                font.family: cal.fontFamily
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    anchors.left: timeRow.right
                                    anchors.leftMargin: 6
                                    anchors.right: addBtn.left
                                    anchors.rightMargin: 6
                                    height: 28
                                    radius: cal.cr
                                    color: Qt.alpha(cal.colText, labelInput.activeFocus ? 0.12 : 0.06)

                                    Behavior on color { ColorAnimation { duration: 150 } }


                                    TextInput {
                                        id: labelInput
                                        anchors.fill: parent
                                        anchors.leftMargin: 8
                                        anchors.rightMargin: 8
                                        verticalAlignment: TextInput.AlignVCenter
                                        clip: true
                                        maximumLength: 60
                                        selectByMouse: true
                                        color: cal.colText
                                        selectionColor: cal.colAccent
                                        selectedTextColor: cal.colBg
                                        font.pixelSize: 11
                                        font.family: cal.fontFamily

                                        Keys.onReturnPressed: cal.commitAlarm()
                                        Keys.onEnterPressed: cal.commitAlarm()
                                        Keys.onEscapePressed: (e) => {
                                            keys.forceActiveFocus()
                                            e.accepted = true
                                        }

                                        Text {
                                            visible: labelInput.text.length === 0
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: cal.t("cal.alarmLabel", "Название")
                                            color: Qt.alpha(cal.colText, 0.35)
                                            font: labelInput.font
                                        }
                                    }
                                }

                                Rectangle {
                                    id: addBtn
                                    anchors.right: parent.right
                                    width: 28
                                    height: 28
                                    radius: cal.cr
                                    color: cal.canAdd ? (addMa.containsMouse ? Qt.lighter(cal.colAccent, 1.15) : cal.colAccent)
                                                      : Qt.alpha(cal.colText, 0.06)

                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    Text {
                                        anchors.centerIn: parent
                                        text: "+"
                                        color: cal.canAdd ? cal.colBg : Qt.alpha(cal.colText, 0.3)
                                        font.pixelSize: 16
                                        font.bold: true
                                        font.family: cal.fontFamily
                                    }

                                    MouseArea {
                                        id: addMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: cal.canAdd ? Qt.PointingHandCursor : Qt.ArrowCursor
                                        onClicked: {
                                            keys.forceActiveFocus()
                                            cal.commitAlarm()
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // кнопка «сегодня»
                    Rectangle {
                        width: parent.width
                        height: 26
                        radius: cal.cr
                        color: todayMa.containsMouse && !cal.onCurrentMonth
                               ? Qt.alpha(cal.colText, 0.12) : Qt.alpha(cal.colText, 0.06)

                        Behavior on color { ColorAnimation { duration: 150 } }

                        Text {
                            anchors.centerIn: parent
                            text: Tr.fmt("cal.today", [cal.dayFull[cal.todayW], cal.todayD, cal.monthGen[cal.todayM]])
                            color: cal.onCurrentMonth ? Qt.alpha(cal.colText, 0.75) : cal.colAccent
                            font.pixelSize: 11
                            font.bold: true
                            font.family: cal.fontFamily
                        }
                        MouseArea {
                            id: todayMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: cal.onCurrentMonth ? Qt.ArrowCursor : Qt.PointingHandCursor
                            onClicked: cal.goToday()
                        }
                    }
                }
            }
        }
    }
}
