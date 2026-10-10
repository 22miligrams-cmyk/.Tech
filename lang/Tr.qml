// lang/Tr.qml — единственный переводчик: Tr.tr("ключ") берёт строку из LangRu / LangEn.
// Синглтон: словари создаются один раз на весь шелл. Язык выставляет SettingsMenu (Tr.lang = ...).
// Нет в выбранном языке — берём русский, нет и там — сам ключ.
// Чтобы добавить язык: допиши код в langs, экземпляр LangXx {} и запись в dicts — больше нигде.
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string settingsPath: (Quickshell.env("XDG_DATA_HOME") || ((Quickshell.env("HOME") || "") + "/.local/share"))
        + "/qs-launchers/settings.json"

    property string lang: "ru"

    FileView {
        id: settingsFile
        path: root.settingsPath
        watchChanges: true
        onLoaded: {
            try {
                const o = JSON.parse(settingsFile.text().trim())
                if (root.langs.indexOf(o.lang) >= 0) root.lang = o.lang
            } catch (e) {}
        }
        onFileChanged: reload()
    }

    readonly property var langs: ["ru", "en"]

    LangRu { id: ruDict }
    LangEn { id: enDict }

    readonly property var dicts: ({ ru: ruDict.s, en: enDict.s })
    readonly property var strings: dicts[lang] || ruDict.s

    function tr(key) {
        const t = root.strings[key]
        if (t !== undefined) return t
        const r = ruDict.s[key]
        return r !== undefined ? r : key
    }

    // Список из одного ключа: "a|b|c" -> ["a","b","c"]
    function list(key) { return root.tr(key).split("|") }

    // fmt("cal.today", [a, b, c]) с подстановкой %1 %2 %3
    function fmt(key, a) {
        let t = root.tr(key)
        for (let i = 0; i < a.length; i++) t = t.replace("%" + (i + 1), a[i])
        return t
    }
}
