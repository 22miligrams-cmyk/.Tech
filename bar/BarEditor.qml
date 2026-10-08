// BarEditor.qml
//
// Зачем это: редактор раскладки бара в меню настроек. Показывает три зоны
// (лево / центр / право) и все блоки бара как плашки: их можно таскать между
// зонами и менять порядок, а кликом между соседними плашками - склеивать в одну.
// Какие блоки включены, решает enabledMap, а результат пишется в BarLayout.
// Если плашки с подписями не влезают в зону - переходит в компактный режим
// (только иконки).

import QtQuick
import "../panels"
import "../notifications"
import "../settings"
import "../common"
import "../lang"
import "../icons"

Item {
    id: editor

    // снаружи приходят модель раскладки и цвета темы
    required property var barLayout
    required property string colBg
    required property string colAccent
    required property string colText
    required property string colSecondary

    // какие блоки включены (false - блок скрыт, но своё место в раскладке помнит)
    property var enabledMap: ({})
    // включён ли блок (по умолчанию да)
    function isOn(id) { return enabledMap[id] !== false }

    // компактный режим: когда плашки с подписями не влезают
    property bool compact: false;  readonly property real compactW: 42

    readonly property string fontFamily: "JetBrainsMono Nerd Font, Monospace"
    readonly property string settingsIcon: "󰒓"
    readonly property var zoneNames: ["left", "center", "right"]

    // перевод по ключу, а если перевода нет - запасной текст
    function trOr(key, fallback) {
        const t = Tr.tr(key)
        return (!t || t === key) ? fallback : t
    }

    // по каждому блоку: подпись, svg-иконка и запасной глиф из шрифта
    readonly property var meta: ({
        ws: { label: Tr.tr("blk.ws"), svg: "workspaces", icon: "󱂬" },
        mpris: { label: Tr.tr("blk.mpris"), svg: "player", icon: "󰎈" },
        bt: { label: Tr.tr("blk.bt"), svg: "bluetooth", icon: "󰂯" },
        app: { label: Tr.tr("blk.app"), svg: "", icon: "󱂚" },
        search: { label: Tr.tr("blk.search"), svg: "search", icon: "󰍉" },
        sys: { label: Tr.tr("blk.sys"), svg: "sys", icon: "" },
        notif: { label: Tr.tr("blk.notif"), svg: "notifications", icon: "󰂚" },
        vol: { label: Tr.tr("blk.vol"), svg: "volume", icon: "󰕾" },
        battery: { label: Tr.tr("blk.battery"), svg: "battery", icon: String.fromCodePoint(0xF0079) },
        clip: { label: Tr.tr("blk.clip"), svg: "clipboard", icon: String.fromCodePoint(0xF014C) },
        tray: { label: Tr.tr("blk.tray"), svg: "tray", icon: String.fromCodePoint(0xF003B) },
        lyrics: { label: trOr("blk.lyrics", "Текст песни"), svg: "lyrics", icon: "󰎈" }
    })

    // размеры: зазоры между плашками, высоты, где по вертикали стоят плашки
    readonly property real chipGap: 12;  readonly property real joinGap: 0
    readonly property real chipH: 32
    readonly property real zoneH: 62
    readonly property real chipY: zoneH - chipH - 8

    // состояние перетаскивания: над какой зоной курсор, какую плашку тащим, где рисовать метку вставки
    property string hoverZone: ""
    property var dragChip: null
    property real dropX: 0
    property bool animateMove: false
    property int linkTick: 0

    implicitHeight: 116

    transform: Translate { y: editor.barLayout.subPush }

    // анимацию переезда плашек включаем ненадолго после изменений, иначе они будут ехать при каждом ресайзе
    Timer {
        id: animOff
        interval: 380
        onTriggered: editor.animateMove = false
    }

    // включает анимацию переезда на 380мс
    function animateOnce() {
        animateMove = true
        animOff.restart()
    }

    // блоки включили или выключили - пересчитать расстановку
    onEnabledMapChanged: {
        animateOnce()
        relayout()
    }

    // раскладка поменялась (например сбросили) - тоже пересчитать
    Connections {
        target: editor.barLayout
        function onRevChanged() {
            editor.animateOnce()
            editor.relayout()
        }
    }

    // шапка: иконка, заголовок и кнопка сброса
    Item {
        id: head
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 28

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10

            Rectangle {
                width: 28
                height: 28
                radius: 6
                color: editor.colSecondary
                anchors.verticalCenter: parent.verticalCenter

                Text {
                    anchors.centerIn: parent
                    text: "⠿"
                    color: editor.colAccent
                    font.pixelSize: 14
                }
            }

            Text {
                id: titleText
                text: Tr.tr("layout.title")
                color: editor.colText
                font.pixelSize: 13
                font.bold: true
                font.family: editor.fontFamily
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Rectangle {
            id: resetBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: resetText.implicitWidth+28
            height: 28
            radius: 10
            color: resetMa.containsMouse ? Qt.alpha(editor.colSecondary, 0.9) : Qt.alpha(editor.colBg, 0.4)

            Behavior on color { ColorAnimation { duration: 150 } }

            Text {
                id: resetText
                anchors.centerIn: parent
                text: Tr.tr("layout.reset")
                color: resetMa.containsMouse ? editor.colAccent : editor.colText
                font.pixelSize: 11
                font.bold: true
                font.family: editor.fontFamily
            }

            MouseArea {
                id: resetMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: editor.barLayout.reset()
            }
        }
    }

    // рамка с тремя зонами, сами плашки ставятся руками в relayout()
    Rectangle {
        id: frame
        anchors.top: head.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: parent.right
        height: editor.zoneH + 16
        radius: 14
        color: "transparent"

        // тут лежат зоны, подсветка слота, метка вставки и сами плашки
        Item {
            id: zones
            x: 8
            y: 8
            width: parent.width - 16
            height: editor.zoneH

            readonly property real gap: 8
            readonly property real zw: (width - 2 * gap) / 3

            onWidthChanged: {
                editor.relayout()
                Qt.callLater(editor.relayout)
            }

            Component.onCompleted: Qt.callLater(editor.relayout)

            // три зоны
            EditorZone {
                id: zoneL
                host: editor
                zone: "left"
                x: 0
                width: zones.zw
                height: zones.height
            }

            EditorZone {
                id: zoneC
                host: editor
                zone: "center"
                x: zones.zw + zones.gap
                width: zones.zw
                height: zones.height
            }

            EditorZone {
                id: zoneR
                host: editor
                zone: "right"
                x: 2 * (zones.zw + zones.gap)
                width: zones.zw
                height: zones.height
            }

            // подсветка места, откуда плашку взяли
            Rectangle {
                visible: editor.dragChip !== null
                z: 1
                x: editor.dragChip ? editor.dragChip.slotX : 0
                y: editor.chipY
                width: editor.dragChip ? editor.dragChip.width : 0
                height: editor.chipH
                radius: 10
                color: Qt.alpha(editor.colAccent, 0.18)
            }

            // метка "сюда вставится": вертикальная линия с точками на концах
            Item {
                id: dropMark
                z: 50
                visible: opacity > 0.01
                opacity: editor.dragChip !== null && editor.hoverZone !== "" ? 1.0 : 0.0
                x: editor.dropX
                y: editor.chipY - 3
                width: 3
                height: editor.chipH + 6

                Behavior on opacity { NumberAnimation { duration: 120 } }
                Behavior on x { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

                Rectangle {
                    anchors.centerIn: parent
                    width: 11
                    height: parent.height + 4
                    radius: 5
                    color: Qt.alpha(editor.colAccent, 0.25)

                    SequentialAnimation on opacity {
                        running: dropMark.visible
                        loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 0.45; duration: 700; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 0.45; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    radius: 2
                    color: editor.colAccent
                }
                Rectangle {
                    width: 7
                    height: 7
                    radius: 3.5
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: -3
                    color: editor.colAccent
                }
                Rectangle {
                    width: 7
                    height: 7
                    radius: 3.5
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: parent.height - 4
                    color: editor.colAccent
                }
            }

            // сами плашки блоков, по одной на каждый блок из allBlocks
            Repeater {
                id: chips
                model: editor.barLayout.allBlocks

                // одна плашка: тянется мышью, углы со стороны склейки становятся прямыми
                delegate: Rectangle {
                    id: chip

                    required property string modelData
                    readonly property string blockId: modelData

                    readonly property bool dragging: mouse.drag.active
                    readonly property var info: editor.meta[modelData]
                    property bool moved: false
                    property real slotX: 0

                    readonly property bool on: editor.enabledMap[modelData] !== false

                    readonly property bool jl: { const r = editor.barLayout.rev; const t = editor.linkTick; return editor.joinsLeft(modelData) }
                    readonly property bool jr: { const r = editor.barLayout.rev; const t = editor.linkTick; return editor.joinsRight(modelData) }
                    readonly property real fullW: 22+chipRow.spacing+lbl.implicitWidth+20

                    width: editor.compact ? editor.compactW : fullW
                    height: editor.chipH
                    opacity: !on ? 0.0 : (editor.dragChip !== null && !dragging ? 0.8 : 1.0)
                    visible: opacity > 0.01
                    radius: 10
                    topLeftRadius: jl ? 0 : 10
                    bottomLeftRadius: jl ? 0 : 10
                    topRightRadius: jr ? 0 : 10
                    bottomRightRadius: jr ? 0 : 10
                    z: dragging ? 100 : 5

                    color: dragging ? editor.colAccent
                         : Qt.alpha(editor.colSecondary, mouse.containsMouse ? 1.0 : 0.9)
                    scale: !on ? 0.6 : (dragging ? 1.06 : (mouse.containsMouse && !jl && !jr ? 1.03 : 1.0))

                    Behavior on topLeftRadius { NumberAnimation { duration: 160 } }
                    Behavior on bottomLeftRadius { NumberAnimation { duration: 160 } }
                    Behavior on topRightRadius { NumberAnimation { duration: 160 } }
                    Behavior on bottomRightRadius { NumberAnimation { duration: 160 } }

                    Behavior on x { enabled: editor.animateMove && !mouse.drag.active; NumberAnimation { duration: 340; easing.type: Easing.OutBack; easing.overshoot: 0.9 } }
                    Behavior on y { enabled: editor.animateMove && !mouse.drag.active; NumberAnimation { duration: 340; easing.type: Easing.OutBack; easing.overshoot: 0.9 } }
                    Behavior on color { ColorAnimation { duration: 150 } }
                    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                    Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                    onWidthChanged: editor.relayout()

                    onDraggingChanged: {
                        if (dragging) {
                            moved = true
                            editor.dragChip = chip
                        } else {
                            editor.hoverZone = ""
                            if (editor.dragChip === chip) editor.dragChip = null
                        }
                    }

                    Row {
                        id: chipRow
                        anchors.centerIn: parent
                        spacing: 7

                        Rectangle {
                            width: 22
                            height: 22
                            radius: 6
                            anchors.verticalCenter: parent.verticalCenter
                            color: "transparent"

                            Behavior on color { ColorAnimation { duration: 150 } }

                            Icon {
                                visible: !!(chip.info && chip.info.svg)
                                anchors.centerIn: parent
                                name: chip.info && chip.info.svg ? chip.info.svg : ""
                                size: 13
                                color: chip.dragging ? editor.colBg : editor.colAccent
                            }

                            Text {
                                visible: !(chip.info && chip.info.svg)
                                anchors.centerIn: parent
                                text: chip.info ? chip.info.icon : ""
                                color: chip.dragging ? editor.colBg : editor.colAccent
                                font.pixelSize: 13
                                font.family: editor.fontFamily
                            }
                        }

                        Text {
                            id: lbl
                            visible: !editor.compact
                            text: chip.info ? chip.info.label : chip.blockId
                            color: chip.dragging ? editor.colBg : editor.colText
                            font.pixelSize: 11
                            font.bold: true
                            font.family: editor.fontFamily
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    // тянем мышью, порог 4px чтобы случайный клик не считался перетаскиванием
                    MouseArea {
                        id: mouse
                        enabled: chip.on
                        anchors.fill: parent
                        hoverEnabled: true
                        drag.target: chip
                        drag.threshold: 4
                        cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                        onPositionChanged: {
                            if (drag.active) editor.updateHover(chip)
                        }
                        onReleased: {
                            if (chip.moved) {
                                chip.moved = false
                                editor.drop(chip.blockId, chip)
                            }
                        }
                    }
                }
            }

            Repeater {
                model: editor.barLayout.allBlocks

                // застёжки между соседними плашками: клик склеивает / расклеивает
                delegate: Item {
                    id: lk

                    required property string modelData
                    readonly property var c: { const t = editor.linkTick; return editor.chipOf(modelData) }
                    readonly property bool can: { const r = editor.barLayout.rev; return editor.barLayout.hasLeft(modelData) }
                    readonly property bool joined: { const r = editor.barLayout.rev; return editor.barLayout.isJoined(modelData) }
                    readonly property bool hot: lkMa.containsMouse

                    visible: can && editor.isOn(modelData) && editor.leftVisible(modelData) && c !== null && editor.dragChip === null
                    z: 60
                    width: joined ? 12 : editor.chipGap + 4
                    height: editor.chipH
                    x: c ? c.x - (joined ? editor.joinGap : editor.chipGap) / 2 - width / 2 : 0
                    y: editor.chipY

                    Rectangle {
                        anchors.centerIn: parent
                        width: lk.joined ? 6 : parent.width
                        height: parent.height
                        radius: lk.joined ? 3 : 8
                        color: Qt.alpha(editor.colAccent, lk.hot ? (lk.joined ? 0.55 : 0.18) : 0.0)

                        Behavior on color { ColorAnimation { duration: 140 } }
                    }

                    Repeater {
                        model: 2
                        delegate: Rectangle {
                            required property int index
                            visible: !lk.joined
                            width: 5
                            height: 3
                            radius: 1.5
                            y: (parent.height - height) / 2
                            x: parent.width / 2 + (index === 0 ? -width - (lk.hot ? 0.5 : 2.5) : (lk.hot ? 0.5 : 2.5))
                            color: lk.hot ? editor.colAccent : Qt.alpha(editor.colText, 0.4)

                            Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                            Behavior on color { ColorAnimation { duration: 140 } }
                        }
                    }

                    Rectangle {
                        visible: lk.joined
                        anchors.centerIn: parent
                        width: 1.5
                        height: lk.hot ? editor.chipH - 10 : editor.chipH - 16
                        radius: 1
                        color: lk.hot ? editor.colAccent : Qt.alpha(editor.colBg, 0.55)

                        Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                        Behavior on color { ColorAnimation { duration: 140 } }
                    }

                    MouseArea {
                        id: lkMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: editor.barLayout.toggleJoin(lk.modelData)
                    }
                }
            }
        }
    }

    // ширина одной зоны
    function zoneW() {
        return (zones.width - 2*zones.gap)/3
    }

    // плашка по id блока
    function chipOf(id) {
        return chips.itemAt(barLayout.allBlocks.indexOf(id))
    }

    // главная расстановка: считаем влезают ли плашки (иначе compact), потом руками выставляем x/y каждой
    // с учётом зазоров и склеек. Левая зона прижата влево, правая вправо, центральная по центру
    function relayout() {
        if (chips.count < barLayout.allBlocks.length) return
        if (zones.width <= 0) return
        const zw = zoneW()

        let need = false
        for (let k = 0; k < 3; k++) {
            const m0 = barLayout.model(zoneNames[k])
            let w = 0
            let cnt = 0
            for (let i = 0; i < m0.count; i++) {
                const bid = m0.get(i).blockId
                if (!isOn(bid)) continue
                const c = chipOf(bid)
                if (!c) continue
                w += c.fullW + (cnt > 0 ? (barLayout.isJoined(bid) ? joinGap : chipGap) : 0)
                cnt++
            }

            if (w > zw - 16 - (k === 2 ? 36 : 0)) need = true
        }
        if (need !== compact) compact = need

        for (let k = 0; k < 3; k++) {
            const m = barLayout.model(zoneNames[k])
            const list = []
            let total = 0

            const gaps = []
            for (let i = 0; i < m.count; i++) {
                const bid = m.get(i).blockId
                if (!isOn(bid)) continue
                const c = chipOf(bid)
                if (!c) continue
                const g = list.length > 0 ? (barLayout.isJoined(bid) ? joinGap : chipGap) : 0
                gaps.push(g)
                list.push(c)
                total += c.width + g
            }

            const n = list.length
            const rowW = total

            let local
            if (k === 0) {
                local = 8
            } else if (k === 1) {
                local = (zw - rowW) / 2
            } else {
                local = zw - (rowW + (n > 0 ? chipGap : 0) + 30) - 8
            }

            let cx = k * (zw + zones.gap) + local
            for (let j = 0; j < n; j++) {
                cx += gaps[j]
                list[j].slotX = cx
                if (!list[j].dragging) {
                    list[j].x = cx
                    list[j].y = chipY
                }
                cx += list[j].width
            }
        }
        linkTick++
    }

    // нужно ли плашке прямые углы слева (склеена с видимым соседом)
    function joinsLeft(id) {
        if (dragChip !== null || !isOn(id)) return false
        return barLayout.hasLeft(id) && barLayout.isJoined(id) && leftVisible(id)
    }

    // то же справа: склеен ли со следующим видимым блоком
    function joinsRight(id) {
        if (dragChip !== null || !isOn(id)) return false
        const z = barLayout.zoneOf(id)
        if (z === "") return false
        const m = barLayout.model(z)
        let found = false
        for (let i = 0; i < m.count; i++) {
            const bid = m.get(i).blockId
            if (found) {
                if (!isOn(bid)) continue
                return barLayout.isJoined(bid)
            }
            if (bid === id) found = true
        }
        return false
    }

    // есть ли слева видимый (включённый) сосед
    function leftVisible(id) {
        const z = barLayout.zoneOf(id)
        if (z === "") return false
        const m = barLayout.model(z)
        for (let i = 0; i < m.count; i++) {
            const bid = m.get(i).blockId
            if (bid === id) break
            if (isOn(bid)) return true
        }
        return false
    }

    // переводит индекс среди видимых плашек в настоящий индекс в модели (выключенные тоже занимают место)
    function realIndex(z, id, visIdx) {
        const m = barLayout.model(z)
        let seen = 0
        let p = 0
        for (let i = 0; i < m.count; i++) {
            const bid = m.get(i).blockId
            if (bid === id) continue
            if (isOn(bid)) {
                if (seen === visIdx) return p
                seen++
            }
            p++
        }
        return p
    }

    // какая зона под точкой (пусто, если слишком далеко по вертикали)
    function zoneAt(p) {
        if (p.y < -30 || p.y > zones.height + 30) return ""
        let i = Math.floor((p.x + zones.gap / 2) / (zoneW() + zones.gap))
        i = Math.max(0, Math.min(2, i))
        return zoneNames[i]
    }

    // на какое место среди видимых плашек зоны попадёт тащимая, по её центру
    function insertIndex(z, id, px) {
        const m = barLayout.model(z)
        let idx = 0
        for (let i = 0; i < m.count; i++) {
            const bid = m.get(i).blockId
            if (bid === id || !isOn(bid)) continue
            const c = chipOf(bid)
            if (c && c.slotX + c.width / 2 < px) idx++
        }
        return idx
    }

    // где по x рисовать метку вставки
    function markX(z, id, px) {
        const m = barLayout.model(z)
        const list = []
        for (let i = 0; i < m.count; i++) {
            const bid = m.get(i).blockId
            if (bid === id || !isOn(bid)) continue
            const c = chipOf(bid)
            if (c) list.push(c)
        }
        if (list.length === 0) {
            const k = zoneNames.indexOf(z)
            return k * (zoneW() + zones.gap) + zoneW() / 2 - 1.5 - (z === "right" ? 19 : 0)
        }
        const idx = insertIndex(z, id, px)
        if (idx < list.length) return list[idx].slotX - chipGap / 2 - 1.5
        const last = list[list.length - 1]
        return last.slotX + last.width + chipGap / 2 - 1.5
    }

    // пока тащим: обновляем зону под курсором и положение метки
    function updateHover(chip) {
        const px = chip.x + chip.width / 2
        hoverZone = zoneAt(Qt.point(px, chip.y + chip.height / 2))
        if (hoverZone !== "") dropX = markX(hoverZone, chip.blockId, px)
    }

    // отпустили плашку: считаем куда, и через callLater кладём в раскладку (чтобы не ломать drag посреди события)
    function drop(id, chip) {
        const px = chip.x + chip.width / 2
        const z = zoneAt(Qt.point(px, chip.y + chip.height / 2))
        const idx = z !== "" ? realIndex(z, id, insertIndex(z, id, px)) : 0
        hoverZone = ""
        animateOnce()

        Qt.callLater(function() {
            if (z !== "") editor.barLayout.place(id, z, idx)
            editor.relayout()
        })
    }
}
