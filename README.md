<div align="center">

# .Tech

**Шелл-дотфайлы для Hyprland на Quickshell**

[![License: MIT](https://img.shields.io/badge/license-MIT-a3cef1.svg)](LICENSE)
[![Hyprland](https://img.shields.io/badge/Hyprland-0.55%2B-3d5a80.svg)](https://hypr.land)
[![Quickshell](https://img.shields.io/badge/Quickshell-QML-181825.svg)](https://quickshell.org)

[Русский](#русский) · [English](#english)

</div>

<!-- Добавь сюда скриншот: ![preview](assets/preview.png) -->

---

## Русский

### Что это

`.Tech` — набор дотфайлов для [Hyprland](https://hypr.land): панель, всплывающие панели, лаунчеры, уведомления и настройки, написанные на QML под [Quickshell](https://quickshell.org). Есть русский и английский интерфейс.

### Требования

- **Hyprland 0.55 или новее** — с этой версии конфиг пишется на Lua (`hyprland.lua`). Старый формат `hyprland.conf` (hyprlang) в 0.55 ещё работает, но объявлен устаревшим; установщик понимает оба.
- **Quickshell**
- Wayland-сессия и PipeWire

Остальные зависимости установщик проверит и предложит поставить сам:

| Команда | Зачем |
|---|---|
| `git` | получение и обновление репозитория |
| `quickshell` | сам шелл |
| `hyprctl` (`hyprland`) | общение с композитором |
| `jq`, `python3` | вспомогательные скрипты |
| `pipewire`, `wpctl` (`wireplumber`), `pavucontrol` | звук |
| `blueman-manager` | Bluetooth |
| `xdg-open` (`xdg-utils`) | открытие ссылок и файлов |
| `qsb` (`qt6-shadertools`) | сборка шейдеров |

### Установка

```bash
git clone https://github.com/22miligrams-cmyk/.Tech.git ~/.tech/shell
cd ~/.tech/shell
./install.sh
```

Установщик по шагам:

1. спросит язык (русский / English);
2. определит дистрибутив (Arch, Debian/Ubuntu, Fedora, openSUSE) и версию Hyprland;
3. найдёт недостающие пакеты и предложит их поставить (на Arch `quickshell` при необходимости возьмёт из AUR через `yay`/`paru`);
4. соберёт шейдеры (`.frag`/`.vert` → `.qsb`);
5. предложит ссылку `~/.config/quickshell/tech`, чтобы работало `quickshell -c tech`;
6. создаст стартовый `~/.cache/quickshell/colors.json`;
7. **предложит добавить автозапуск** — в `hyprland.lua` (Lua-формат, Hyprland 0.55+) или, если есть только старый `hyprland.conf`, в него; перед правкой делается бэкап `*.bak-<дата>`;
8. **предложит сразу запустить шелл** (`quickshell -d`), а если он уже работает — перезапустить.

Флаги установщика:

| Флаг | Что делает |
|---|---|
| `--yes`, `-y` | отвечать «да» на все вопросы |
| `--dry-run` | ничего не менять, только показать команды |
| `--help` | краткая справка |

Переменная `TECH_DIR` меняет папку, в которую клонируется репозиторий (по умолчанию `~/.tech/shell`).

### Ручная установка

1. Поставь зависимости из таблицы выше.
2. Собери шейдеры:
   ```bash
   find . -type f \( -name '*.frag' -o -name '*.vert' \) -exec sh -c 'qsb --qt6 -o "$1.qsb" "$1"' _ {} \;
   ```
3. Положи стартовые цвета в `~/.cache/quickshell/colors.json`:
   ```json
   {
     "bg": "#181825",
     "accent": "#a3cef1",
     "text": "#e0e1dd",
     "secondary": "#3d5a80"
   }
   ```
4. Запусти: `quickshell -d -p ~/.tech/shell`

### Автозапуск

**Hyprland 0.55+ — `~/.config/hypr/hyprland.lua`:**

```lua
hl.on("hyprland.start", function()
  hl.exec_cmd("quickshell -p '/home/USER/.tech/shell'")
end)
```

**Старый формат — `~/.config/hypr/hyprland.conf`:**

```ini
exec-once = quickshell -p '/home/USER/.tech/shell'
```

### Обновление

```bash
cd ~/.tech/shell && git pull --ff-only && ./install.sh
```

Перезапустить шелл: `pkill -x quickshell && quickshell -d -p ~/.tech/shell`

### Структура

```
shell.qml          точка входа
Bar.qml            панель
Logic.qml          логика и состояние
Visual.qml         общий внешний вид
assets/  icons/    ресурсы и иконки
bar/  panels/      части панели и всплывающие панели
launchers/         лаунчеры
notifications/     уведомления
settings/          настройки
lang/              переводы
lrc/               тексты песен
common/            общие компоненты
```

### Цвета

Шелл читает палитру из `~/.cache/quickshell/colors.json` (ключи `bg`, `accent`, `text`, `secondary`). Поменяй значения — и цвета обновятся.

### Если что-то не работает

- Запусти шелл из терминала без `-d` — ошибки QML будут видны сразу: `quickshell -p ~/.tech/shell`
- Не хватает пакета — запусти `./install.sh` ещё раз, он покажет, чего нет.
- Шейдеры не собрались — проверь, что установлен `qsb` (`qt6-shadertools`).

### Лицензия

[MIT](LICENSE)

---

## English

### What is this

`.Tech` is a set of dotfiles for [Hyprland](https://hypr.land): a bar, popup panels, launchers, notifications and settings written in QML for [Quickshell](https://quickshell.org). The UI is available in Russian and English.

### Requirements

- **Hyprland 0.55 or newer** — the config is written in Lua (`hyprland.lua`) from that version on. The old hyprlang `hyprland.conf` still works in 0.55 but is deprecated; the installer handles both.
- **Quickshell**
- A Wayland session and PipeWire

The installer checks and offers to install the rest (`git`, `jq`, `python3`, `wireplumber`, `pavucontrol`, `blueman`, `xdg-utils`, `qt6-shadertools`).

### Install

```bash
git clone https://github.com/22miligrams-cmyk/.Tech.git ~/.tech/shell
cd ~/.tech/shell
./install.sh
```

The installer detects your distro (Arch, Debian/Ubuntu, Fedora, openSUSE) and Hyprland version, installs missing packages, builds shaders, links `~/.config/quickshell/tech`, creates a starter colors file, then **offers to add autostart** (to `hyprland.lua` on 0.55+, or to `hyprland.conf` on older setups, with a backup) and **offers to launch the shell right away**.

Flags: `--yes` / `-y` (answer yes to everything), `--dry-run` (change nothing, just print), `--help`.

### Autostart (manual)

```lua
-- ~/.config/hypr/hyprland.lua  (Hyprland 0.55+)
hl.on("hyprland.start", function()
  hl.exec_cmd("quickshell -p '/home/USER/.tech/shell'")
end)
```

```ini
# ~/.config/hypr/hyprland.conf  (legacy)
exec-once = quickshell -p '/home/USER/.tech/shell'
```

### Update

```bash
cd ~/.tech/shell && git pull --ff-only && ./install.sh
```

### License

[MIT](LICENSE)
