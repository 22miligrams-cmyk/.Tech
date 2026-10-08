// lang/LangState.qml — текущий язык интерфейса, общий для настроек и всех панелей.
// SettingsMenu пишет сюда выбранный язык, Tr.qml читает — привязывать lang в Visual.qml не нужно.
pragma Singleton
import QtQuick

QtObject {
    property string lang: "ru"
}
