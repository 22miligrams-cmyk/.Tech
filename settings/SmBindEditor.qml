// Окошко создания/редактирования своего бинда: название, команда и выбор готового пресета
// (окна шелла вроде календаря или громкости). Показывается поверх всего меню с затемнением.
import QtQuick
import QtQuick.Layouts

Item {
    id: root
    required property var menu
    readonly property string colBg: menu.colBg
    readonly property string colAccent: menu.colAccent
    readonly property string colText: menu.colText
    readonly property string colSecondary: menu.colSecondary

    property bool bdEditing: false
    property string bdEditId: ""
    property int editField: 0
    property int presetIdx: -1

    property real appear: bdEditing ? 1 : 0
    Behavior on appear { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
    visible: bdEditing || appear > 0.01

    readonly property var winPresets: ["calendar", "sys", "volume", "player", "notifications", "clipboard", "tray", "bluetooth", "workspaces", "settings", "dnd", "alttab", "alttabPrev"]

    // человеческое название пресета (из переводов, для alttab запасной вариант)
    function winName(p) {
        const v = menu.tr("win." + p)
        if (v && v !== "win." + p) return v
        return ({ alttab: "Alt+Tab", alttabPrev: "Alt+Shift+Tab" })[p] || p
    }

    // команда quickshell ipc, которая открывает окно пресета
    function presetCmd(p) { return menu.bindsCtl.ipcPrefix + " call shell " + p }

    // открывает редактор: пустой для нового бинда или с данными существующего (по id)
    function openBindEditor(id) {
        bdEditId = id
        let c = id ? menu.bdCustom.find(x => x.id === id) : null
        bindNameInput.text = c ? c.name : ""
        bindCmdInput.text = c ? c.cmd : ""
        presetIdx = -1
        menu.bdCapture = ""
        bdEditing = true
        focusEditField(0)
    }

    // переводит фокус на одно из трёх полей (0 имя, 1 команда, 2 пресет), по кругу
    function focusEditField(i) {
        editField = (i + 3) % 3
        if (editField === 0) bindNameInput.forceActiveFocus()
        else if (editField === 1) bindCmdInput.forceActiveFocus()
        else presetRow.forceActiveFocus()
    }

    // закрывает редактор и отдаёт фокус обратно сетке карточек
    function closeBindEditor() {
        bdEditing = false
        Qt.callLater(() => menu.settingsGrid.forceActiveFocus())
    }

    // листает пресеты влево/вправо и подставляет команду (и название, если оно пустое или от прошлого пресета)
    function cycleWinPreset(d) {
        const n = winPresets.length
        presetIdx = presetIdx < 0 ? (d > 0 ? 0 : n - 1) : (presetIdx + d + n) % n
        const p = winPresets[presetIdx]
        bindCmdInput.text = presetCmd(p)
        if (bindNameInput.text.trim() === "" || winPresets.some(w => bindNameInput.text === winName(w)))
            bindNameInput.text = winName(p)
    }

    // сохраняет бинд. Пустые поля не пропускает (фокус на пустое). Новый бинд сразу ставит в режим записи клавиши
    function saveBindEditor() {
        const name = bindNameInput.text.trim(), cmd = bindCmdInput.text.trim()
        if (name === "") { focusEditField(0); return }
        if (cmd === "") { focusEditField(1); return }
        if (bdEditId !== "") {
            menu.bdCustom = menu.bdCustom.map(c => c.id === bdEditId ? ({ id: c.id, name: name, cmd: cmd }) : c)
            menu.storeCtl.save(); menu.bindsCtl.scheduleApply()
            closeBindEditor()
        } else {
            const id = "c" + Date.now()
            menu.bdCustom = menu.bdCustom.concat([{ id: id, name: name, cmd: cmd }])
            menu.storeCtl.save()
            closeBindEditor()
            Qt.callLater(() => {
                menu.settingsGrid.currentIndex = menu.bindsCtl.bindBase.length + menu.bdCustom.length - 1
                menu.settingsGrid.forceActiveFocus()
                menu.bdCapture = id
            })
        }
    }

    Rectangle { anchors.fill: parent; color: "black"; opacity: 0.5 * root.appear }
    MouseArea { anchors.fill: parent; onClicked: root.closeBindEditor() }

    Rectangle {
        id: editCard
        anchors.centerIn: parent
        width: 500
        height: editCol.implicitHeight + 56
        radius: 22
        color: Qt.alpha(colBg, 0.96)
        opacity: root.appear
        scale: 0.94 + 0.06 * root.appear

        MouseArea { anchors.fill: parent }

        ColumnLayout {
            id: editCol
            anchors.fill: parent
            anchors.margins: 28
            spacing: 6

            RowLayout {
                Layout.bottomMargin: 14
                spacing: 12

                Rectangle {
                    Layout.preferredWidth: 34; Layout.preferredHeight: 34
                    radius: 10
                    color: colSecondary
                    Text {
                        anchors.centerIn: parent
                        text: String.fromCodePoint(0xF030C)
                        color: colAccent
                        font.pixelSize: 18
                    }
                }

                Text {
                    text: root.bdEditId === "" ? menu.tr("bedit.new") : menu.tr("bedit.edit")
                    color: colText
                    font.pixelSize: 16
                    font.bold: true
                    font.family: "JetBrainsMono Nerd Font, Monospace"
                }
            }

            Text {
                text: menu.tr("bedit.name")
                color: colText; opacity: 0.55
                font.pixelSize: 10
                font.family: "JetBrainsMono Nerd Font, Monospace"
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 42
                radius: 12
                color: Qt.alpha(colSecondary, bindNameInput.activeFocus ? 0.95 : 0.4)
                Behavior on color { ColorAnimation { duration: 150 } }
                TextInput {
                    id: bindNameInput
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 14
                    verticalAlignment: TextInput.AlignVCenter
                    color: colText
                    selectionColor: colAccent; selectedTextColor: colBg
                    selectByMouse: true; clip: true
                    font.pixelSize: 13
                    font.family: "JetBrainsMono Nerd Font, Monospace"
                    onActiveFocusChanged: if (activeFocus) root.editField = 0
                    Keys.onTabPressed: root.focusEditField(1)
                    Keys.onDownPressed: root.focusEditField(1)
                    Keys.onBacktabPressed: root.focusEditField(2)
                    Keys.onUpPressed: root.focusEditField(2)
                    Keys.onReturnPressed: root.saveBindEditor()
                    Keys.onEnterPressed: root.saveBindEditor()
                    Keys.onEscapePressed: root.closeBindEditor()
                }
            }

            Text {
                Layout.topMargin: 8
                text: menu.tr("bedit.cmd")
                color: colText; opacity: 0.55
                font.pixelSize: 10
                font.family: "JetBrainsMono Nerd Font, Monospace"
            }
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 42
                radius: 12
                color: Qt.alpha(colSecondary, bindCmdInput.activeFocus ? 0.95 : 0.4)
                Behavior on color { ColorAnimation { duration: 150 } }
                TextInput {
                    id: bindCmdInput
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 14
                    verticalAlignment: TextInput.AlignVCenter
                    color: colText
                    selectionColor: colAccent; selectedTextColor: colBg
                    selectByMouse: true; clip: true
                    font.pixelSize: 12
                    font.family: "JetBrainsMono Nerd Font, Monospace"
                    onActiveFocusChanged: if (activeFocus) root.editField = 1
                    Keys.onTabPressed: root.focusEditField(2)
                    Keys.onDownPressed: root.focusEditField(2)
                    Keys.onBacktabPressed: root.focusEditField(0)
                    Keys.onUpPressed: root.focusEditField(0)
                    Keys.onReturnPressed: root.saveBindEditor()
                    Keys.onEnterPressed: root.saveBindEditor()
                    Keys.onEscapePressed: root.closeBindEditor()
                }
            }

            Text {
                Layout.topMargin: 8
                text: menu.tr("bedit.preset")
                color: colText; opacity: 0.55
                font.pixelSize: 10
                font.family: "JetBrainsMono Nerd Font, Monospace"
            }
            Rectangle {
                id: presetRow
                Layout.fillWidth: true
                Layout.preferredHeight: 42
                radius: 12
                color: Qt.alpha(colSecondary, presetRow.activeFocus ? 0.95 : 0.4)
                Behavior on color { ColorAnimation { duration: 150 } }

                Text {
                    anchors.centerIn: parent
                    text: root.presetIdx < 0 ? "—" : root.winName(root.winPresets[root.presetIdx])
                    color: root.presetIdx < 0 ? colText : colAccent
                    opacity: root.presetIdx < 0 ? 0.5 : 1
                    font.pixelSize: 13
                    font.bold: true
                    font.family: "JetBrainsMono Nerd Font, Monospace"
                }

                Text {
                    anchors.left: parent.left; anchors.leftMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    text: "‹"
                    color: colAccent
                    font.pixelSize: 20
                    opacity: leftArea.containsMouse ? 1 : 0.6
                }
                Text {
                    anchors.right: parent.right; anchors.rightMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    text: "›"
                    color: colAccent
                    font.pixelSize: 20
                    opacity: rightArea.containsMouse ? 1 : 0.6
                }
                MouseArea {
                    id: leftArea
                    anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                    width: parent.width / 2
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { presetRow.forceActiveFocus(); root.cycleWinPreset(-1) }
                }
                MouseArea {
                    id: rightArea
                    anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
                    width: parent.width / 2
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { presetRow.forceActiveFocus(); root.cycleWinPreset(1) }
                }

                Keys.onLeftPressed: root.cycleWinPreset(-1)
                Keys.onRightPressed: root.cycleWinPreset(1)
                Keys.onTabPressed: root.focusEditField(0)
                Keys.onDownPressed: root.focusEditField(0)
                Keys.onBacktabPressed: root.focusEditField(1)
                Keys.onUpPressed: root.focusEditField(1)
                Keys.onReturnPressed: root.saveBindEditor()
                Keys.onEnterPressed: root.saveBindEditor()
                Keys.onEscapePressed: root.closeBindEditor()
            }

            RowLayout {
                Layout.topMargin: 20
                Layout.alignment: Qt.AlignRight
                spacing: 10

                Rectangle {
                    Layout.preferredWidth: 110; Layout.preferredHeight: 40
                    radius: 12
                    color: cancelArea.containsMouse ? colSecondary : Qt.alpha(colSecondary, 0.45)
                    Behavior on color { ColorAnimation { duration: 150 } }
                    Text {
                        anchors.centerIn: parent
                        text: menu.bindsCtl.atText("Отмена", "Cancel")
                        color: colText
                        font.pixelSize: 12
                        font.bold: true
                        font.family: "JetBrainsMono Nerd Font, Monospace"
                    }
                    MouseArea {
                        id: cancelArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.closeBindEditor()
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 130; Layout.preferredHeight: 40
                    radius: 12
                    color: colAccent
                    opacity: saveArea.containsMouse ? 1.0 : 0.88
                    Behavior on opacity { NumberAnimation { duration: 150 } }
                    Text {
                        anchors.centerIn: parent
                        text: menu.bindsCtl.atText("Сохранить", "Save")
                        color: colBg
                        font.pixelSize: 12
                        font.bold: true
                        font.family: "JetBrainsMono Nerd Font, Monospace"
                    }
                    MouseArea {
                        id: saveArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.saveBindEditor()
                    }
                }
            }
        }
    }
}
