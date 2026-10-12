// Paths.qml
//
// Зачем это: одно место, где лежат общие пути шелла. Чтобы не писать
// Quickshell.env("HOME") + "/.cache/quickshell" в каждом файле, а просто
// брать Paths.cache. Если вдруг переедет папка - правим только тут.
//
// Как юзать: Paths.home, Paths.cache, Paths.wallpapers ...
pragma Singleton
import Quickshell
import Quickshell.Io

Singleton {
    id: root

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

    // папка «Изображения»: спрашиваем у системы (xdg-user-dir), чтобы работало и с русской,
    // и с английской локалью. Пока ответ не пришёл (или xdg-user-dir нет) - ~/Pictures
    property string pictures: home + "/Pictures"

    Process {
        running: true
        command: ["xdg-user-dir", "PICTURES"]
        stdout: StdioCollector {
            onStreamFinished: {
                const t = text.trim()
                // xdg-user-dir возвращает $HOME, если каталог не настроен - тогда остаёмся на ~/Pictures
                if (t !== "" && t !== root.home) root.pictures = t
            }
        }
    }

    // папка с обоями по умолчанию (пока в настройках ничего не выбрано)
    readonly property string wallpapers: pictures + "/wallpapers"

    // svg-иконки шелла
    readonly property string icons: home + "/.tech/shell/icons"
}
