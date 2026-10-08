// Paths.qml
//
// Зачем это: одно место, где лежат общие пути шелла. Чтобы не писать
// Quickshell.env("HOME") + "/.cache/quickshell" в каждом файле, а просто
// брать Paths.cache. Если вдруг переедет папка - правим только тут.
//
// Как юзать: Paths.home, Paths.cache, Paths.wallpapers ...
pragma Singleton
import Quickshell

Singleton {
    // домашняя папка пользователя
    readonly property string home: Quickshell.env("HOME")

    // сюда шелл складывает кэш (colors.json, palettes.json и прочее)
    readonly property string cache: home + "/.cache/quickshell"

    // пользовательские данные (уважаем XDG_DATA_HOME)
    readonly property string data: Quickshell.env("XDG_DATA_HOME") || (home + "/.local/share")

    // папка настроек лаунчеров (settings.json лежит тут)
    readonly property string launchers: data + "/qs-launchers"

    // сюда меню настроек пишет выбранную папку с обоями (просто путь одной строкой)
    readonly property string wallDirFile: launchers + "/wall-dir.txt"

    // папка с обоями по умолчанию (пока в настройках ничего не выбрано)
    readonly property string wallpapers: home + "/Изображения/wallpapers"

    // svg-иконки шелла
    readonly property string icons: home + "/.tech/shell/icons"
}
