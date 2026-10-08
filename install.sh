#!/usr/bin/env bash
# .Tech installer / установщик .Tech
#
# Скачал один файл — дальше он сам / Download one file, it does the rest:
#   curl -fsSL https://raw.githubusercontent.com/22miligrams-cmyk/.Tech/main/install.sh | bash
#
#   ./install.sh              — покажет список шагов, отметь нужные / pick the steps you want
#   ./install.sh -y           — всё автоматически, без вопросов / fully automatic, no questions
#   ./install.sh --dry-run    — ничего не менять, только показать шаги / change nothing, just show steps
#   ./install.sh --auto-update / --no-auto-update — автопроверка обновлений вкл / выкл (без вопроса)
#   ./install.sh --help
#
# Через curl | bash автоматический режим:  curl -fsSL <url> | bash -s -- -y
# Запустил установщик повторно — он сравнит версию в ~/.tech/shell/v.version с версией на GitHub
# и, если они не совпали, предложит снести всё и поставить заново (обновление).
# Язык берётся из $LANG (принудительно: TECH_LANG=ru или TECH_LANG=en), папка установки — TECH_DIR.
# Пакеты, которые проверяются, перечислены в массиве DEPS ниже — правь его под свои нужды.

set -uo pipefail

REPO_URL="https://github.com/22miligrams-cmyk/.Tech.git"
README_URL="https://github.com/22miligrams-cmyk/.Tech#readme"
INSTALL_DIR="${TECH_DIR:-$HOME/.tech/shell}"   # всегда ~/.tech/shell; остальное в ~/.tech не трогаем / always ~/.tech/shell; the rest of ~/.tech is left alone
VERSION_FILE="v.version"   # файл с версией в корне репозитория / version file in the repo root
CONF_NAME="tech"   # quickshell -c tech
MIN_LUA_VER="0.55.0"   # с этой версии Hyprland конфиг на Lua / Lua config since this version
DRY_RUN=0
AUTO_UPD=""   # "", 1 или 0: автопроверка обновлений шелла (пусто — спросить; с -y — включить)
ASSUME_YES=0   # по умолчанию — выбор шагов; -y = всё автоматически / default: pick steps; -y = automatic

usage() {
    cat <<'EOF'
.Tech installer / установщик .Tech

  ./install.sh            pick which steps to run / выбери нужные шаги
  ./install.sh -y         fully automatic, no questions / всё автоматически
  ./install.sh --dry-run  change nothing, only show steps / ничего не менять
  ./install.sh --auto-update / --no-auto-update   update checks on / off, no question
                          автопроверка обновлений вкл / выкл, без вопроса
  ./install.sh --help

  curl -fsSL https://raw.githubusercontent.com/22miligrams-cmyk/.Tech/main/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/22miligrams-cmyk/.Tech/main/install.sh | bash -s -- -y

Env: TECH_LANG=ru|en, TECH_DIR=<install dir>
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=1 ;;
        --ask|--interactive) ASSUME_YES=0 ;;
        -y|--yes)   ASSUME_YES=1 ;;
        --auto-update)    AUTO_UPD=1 ;;
        --no-auto-update) AUTO_UPD=0 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
    esac
done

# вопросы читаем с терминала, а не из stdin (иначе при «curl | bash» скрипт съел бы сам себя);
# нет терминала — просто отвечаем «да» на всё
if (( ! ASSUME_YES )) && ! ( : </dev/tty ) 2>/dev/null; then ASSUME_YES=1; fi

# ── цвета ───────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RST=$'\e[0m'; C_B=$'\e[1m'; C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_ACC=$'\e[38;2;163;206;241m'; C_DIM=$'\e[2m'
else
    C_RST=""; C_B=""; C_OK=""; C_WARN=""; C_ERR=""; C_ACC=""; C_DIM=""
fi

# ── зависимости: команда | arch | debian/ubuntu | fedora | opensuse ───────
# "-" значит «пакета нет в репозиториях, ставить руками».
# Список собран по Logic.qml и shell.qml; файлы из bar/, panels/, launchers/ и assets/
# я не видел — добавь сюда то, что используют они (обои, скриншоты, плеер и т.д.).
DEPS=(
    "git|git|git|git|git"
    "quickshell|quickshell|-|-|-"
    "hyprctl|hyprland|-|hyprland|hyprland"
    "jq|jq|jq|jq|jq"
    "python3|python|python3|python3|python3"
    "pavucontrol|pavucontrol|pavucontrol|pavucontrol|pavucontrol"
    "blueman-manager|blueman|blueman|blueman|blueman"
    "xdg-open|xdg-utils|xdg-utils|xdg-utils|xdg-utils"
    "notify-send|libnotify|libnotify-bin|libnotify|libnotify-tools"
    "stdbuf|coreutils|coreutils|coreutils|coreutils"
    "curl|curl|curl|curl|curl"
    "tar|tar|tar|tar|tar"
    "xz|xz|xz-utils|xz|xz"
    "fc-cache|fontconfig|fontconfig|fontconfig|fontconfig"
    "pipewire|pipewire|pipewire|pipewire|pipewire"
    "wpctl|wireplumber|wireplumber|wireplumber|wireplumber"
    "qsb|qt6-shadertools|qt6-shader-baker|qt6-qtshadertools|qt6-shadertools"
)

# ── строки интерфейса ───────────────────────────────────────────────────
declare -A RU EN
L="en"

RU[lang_prompt]="Выбери язык / Choose language"
RU[invalid]="Не понял, введи 1 или 2."
RU[root]="Не запускай установщик от root — он сам спросит sudo, когда понадобится."
RU[dry]="Режим --dry-run: ничего не будет изменено, команды только печатаются."
RU[distro]="Дистрибутив: %s, пакетный менеджер: %s"
RU[distro_unknown]="Не удалось определить пакетный менеджер — пакеты придётся ставить вручную."
RU[hypr_ver]="Hyprland %s"
RU[hypr_old]="Hyprland старше %s — там ещё нет Lua-конфига. Шелл работает и на старых версиях, но рекомендую обновиться."
RU[checking]="Проверяю, чего не хватает…"
RU[all_ok]="Все зависимости на месте."
RU[missing_item]="  ✗ %s  (пакет: %s)"
RU[manual_item]="  ! %s  — в репозиториях этого дистрибутива нет, нужно поставить вручную"
RU[skip_install]="Пропускаю установку пакетов. Без них шелл может не запуститься."
RU[installing]="Ставлю пакеты…"
RU[install_fail]="Не все пакеты поставились — смотри ошибки выше."
RU[qs_aur]="quickshell нет в основных репозиториях, пробую AUR (%s)…"
RU[qs_manual]="quickshell не установлен. Инструкция: https://quickshell.org"
RU[qs_copr]="quickshell нет в основных репозиториях, подключаю COPR errornr/quickshell…"
RU[qs_try]="Пробую поставить quickshell из репозиториев…"
RU[font_have]="Шрифт JetBrainsMono Nerd Font уже установлен."
RU[font_get]="Скачиваю шрифт JetBrainsMono Nerd Font (для иконок)…"
RU[font_ok]="Шрифт установлен в ~/.local/share/fonts."
RU[font_fail]="Не получилось поставить JetBrainsMono Nerd Font — иконки в шелле могут отображаться квадратиками. Скачай вручную: https://www.nerdfonts.com/font-downloads"
RU[repo_using]="Использую текущую папку: %s"
RU[repo_pull]="Репозиторий уже есть в %s — обновляю."
RU[repo_clone]="Клонирую репозиторий в %s…"
RU[repo_notgit]="Папка %s уже существует, но это не репозиторий .Tech (скорее всего, остаток от старой установки). Остальное в ~/.tech не трогаю."
RU[ask_moveold]="Перенести её в бэкап и поставить заново?"
RU[moveold_ok]="Старая папка перенесена в %s"
RU[moveold_no]="Ок, ничего не трогаю. Освободи папку или задай другую: TECH_DIR=/путь ./install.sh"
RU[ver_same]="У тебя последняя версия: %s."
RU[ver_opt_exit]="  1) Выйти"
RU[ver_opt_reinstall]="  2) Переустановить"
RU[ver_choose]="Выбери 1 или 2 [1]: "
RU[ver_diff]="Доступно обновление: у тебя версия %s, на GitHub — %s."
RU[ver_unknown]="Не удалось узнать версию на GitHub (нет интернета или нет файла версии) — просто подтягиваю изменения."
RU[ver_dirty]="Внимание: в %s есть твои локальные правки — они будут потеряны."
RU[ask_reinstall]="Полностью снести установленную версию и поставить новую?"
RU[ver_skip]="Остаюсь на текущей версии."
RU[wipe_refuse]="Отказываюсь удалять %s — слишком опасный путь."
RU[reinstall_ok]="Обновлено: поставлена версия %s."
RU[repo_fail]="Не получилось получить репозиторий. Проверь интернет и права на папку."
RU[shaders_build]="Собираю шейдеры (qsb)…"
RU[shaders_none]="Исходников шейдеров (.frag/.vert) не найдено — пропускаю."
RU[shaders_nosb]="qsb не найден — шейдеры не собраны (ставь qt6-shadertools)."
RU[shaders_fail]="  ✗ не собрался: %s"
RU[shaders_ok]="Шейдеров собрано: %s"
RU[link_ok]="Ссылка создана."
RU[link_exists]="~/.config/quickshell/%s уже существует и ведёт не туда — не трогаю."
RU[colors]="Создал стартовый файл цветов: %s"
RU[auto_ok]="Автозапуск добавлен. Бэкап: %s"
RU[auto_has]="В %s уже есть запуск quickshell — не трогаю."
RU[auto_legacy]="Нашёл только старый hyprland.conf (hyprlang) — пропишу автозапуск там."
RU[auto_noconf]="Не нашёл конфиг Hyprland. Добавь вручную в ~/.config/hypr/hyprland.lua:"
RU[auto_noconf_old]="или, для старого формата, в ~/.config/hypr/hyprland.conf:"
RU[ask_restart]="quickshell уже запущен. Перезапустить его?"
RU[launch_ok]="Шелл запущен."
RU[launch_fail]="Не получилось запустить шелл. Попробуй вручную: quickshell -p %s"
RU[launch_nohypr]="Сейчас не запущен Hyprland (или нет доступа к его сессии) — запусти шелл после входа: quickshell -d -p %s"
RU[launch_noqs]="quickshell не установлен — запускать нечего."
RU[next]="Что дальше:"
RU[next1]="  1. Если шелл ещё не запущен — перезайди в Hyprland (или выполни:  quickshell -d -p %s)"
RU[next2]="  2. Если что-то не работает — сначала загляни в README: %s"
RU[menu_title]="Что установить?"
RU[menu_hint]="↑↓ — двигаться · Пробел — вкл/выкл · a — всё · n — ничего · Enter — поехали"
RU[dep_title]="Зависимости"
RU[dep_summary]="Не хватает %s из %s."
RU[dep_legend]="✓ есть   ✗ нет, поставлю   ! нет в репозитории, ставить вручную"
RU[note_missing]="не хватает: %s"
RU[note_ok]="всё на месте"
RU[note_done]="уже на месте, пропускаю"
RU[step_pkgs]="Недостающие пакеты (через менеджер пакетов, нужен sudo)"
RU[step_font]="Шрифт JetBrainsMono Nerd Font (иконки)"
RU[step_shaders]="Сборка шейдеров (qsb)"
RU[step_link]="Ссылка ~/.config/quickshell/tech (чтобы работало «quickshell -c tech»)"
RU[step_colors]="Стартовый файл цветов"
RU[step_auto]="Автозапуск в конфиге Hyprland (бэкап сохраню)"
RU[step_launch]="Запустить шелл сразу после установки"
RU[running_skip]="quickshell уже запущен — не трогаю (запусти установщик без -y, если нужен перезапуск)."
RU[scan_missing]="В QML вызываются программы, которых нет в системе (эвристика, проверь сам): %s"
RU[ask_autoupd]="Проверять обновления .Tech автоматически (при старте шелла и раз в несколько часов)?"
RU[autoupd_on]="Автопроверка обновлений включена. Выключить: quickshell ipc -p %s call updater autoOff"
RU[autoupd_off]="Автопроверка обновлений выключена. Включить: quickshell ipc -p %s call updater autoOn"
RU[bye]="Готово! Удачи и приятного пользования ✨"

EN[lang_prompt]="Выбери язык / Choose language"
EN[invalid]="Didn't get that, enter 1 or 2."
EN[root]="Don't run the installer as root — it will ask for sudo when needed."
EN[dry]="--dry-run mode: nothing will be changed, commands are only printed."
EN[distro]="Distro: %s, package manager: %s"
EN[distro_unknown]="Could not detect a package manager — you'll have to install packages by hand."
EN[hypr_ver]="Hyprland %s"
EN[hypr_old]="Hyprland is older than %s — no Lua config there yet. The shell works on older versions too, but consider updating."
EN[checking]="Checking what's missing…"
EN[all_ok]="All dependencies are in place."
EN[missing_item]="  ✗ %s  (package: %s)"
EN[manual_item]="  ! %s  — not in this distro's repositories, install it manually"
EN[skip_install]="Skipping package installation. The shell may not start without them."
EN[installing]="Installing packages…"
EN[install_fail]="Not every package installed — see the errors above."
EN[qs_aur]="quickshell is not in the main repos, trying AUR (%s)…"
EN[qs_manual]="quickshell is not installed. Instructions: https://quickshell.org"
EN[qs_copr]="quickshell is not in the main repos, enabling COPR errornr/quickshell…"
EN[qs_try]="Trying to install quickshell from the repositories…"
EN[font_have]="JetBrainsMono Nerd Font is already installed."
EN[font_get]="Downloading JetBrainsMono Nerd Font (for icons)…"
EN[font_ok]="Font installed to ~/.local/share/fonts."
EN[font_fail]="Could not install JetBrainsMono Nerd Font — icons in the shell may show as boxes. Download it manually: https://www.nerdfonts.com/font-downloads"
EN[repo_using]="Using the current folder: %s"
EN[repo_pull]="Repository already exists in %s — updating."
EN[repo_clone]="Cloning the repository into %s…"
EN[repo_notgit]="Folder %s already exists but is not a .Tech repository (probably a leftover of an old install). The rest of ~/.tech is left alone."
EN[ask_moveold]="Move it to a backup and install fresh?"
EN[moveold_ok]="Old folder moved to %s"
EN[moveold_no]="OK, leaving it alone. Free up the folder or pick another: TECH_DIR=/path ./install.sh"
EN[ver_same]="You have the latest version: %s."
EN[ver_opt_exit]="  1) Exit"
EN[ver_opt_reinstall]="  2) Reinstall"
EN[ver_choose]="Choose 1 or 2 [1]: "
EN[ver_diff]="Update available: you have version %s, GitHub has %s."
EN[ver_unknown]="Could not read the version on GitHub (no internet or no version file) — just pulling changes."
EN[ver_dirty]="Warning: %s has local changes — they will be lost."
EN[ask_reinstall]="Completely remove the installed version and install the new one?"
EN[ver_skip]="Staying on the current version."
EN[wipe_refuse]="Refusing to delete %s — path is too dangerous."
EN[reinstall_ok]="Updated: version %s installed."
EN[repo_fail]="Could not get the repository. Check your internet and folder permissions."
EN[shaders_build]="Building shaders (qsb)…"
EN[shaders_none]="No shader sources (.frag/.vert) found — skipping."
EN[shaders_nosb]="qsb not found — shaders not built (install qt6-shadertools)."
EN[shaders_fail]="  ✗ failed to build: %s"
EN[shaders_ok]="Shaders built: %s"
EN[link_ok]="Link created."
EN[link_exists]="~/.config/quickshell/%s already exists and points elsewhere — leaving it alone."
EN[colors]="Created a starter colors file: %s"
EN[auto_ok]="Autostart added. Backup: %s"
EN[auto_has]="%s already launches quickshell — leaving it alone."
EN[auto_legacy]="Only the old hyprland.conf (hyprlang) was found — adding autostart there."
EN[auto_noconf]="Could not find a Hyprland config. Add this manually to ~/.config/hypr/hyprland.lua:"
EN[auto_noconf_old]="or, for the old format, to ~/.config/hypr/hyprland.conf:"
EN[ask_restart]="quickshell is already running. Restart it?"
EN[launch_ok]="Shell started."
EN[launch_fail]="Could not start the shell. Try manually: quickshell -p %s"
EN[launch_nohypr]="Hyprland isn't running (or its session isn't reachable) — start the shell after logging in: quickshell -d -p %s"
EN[launch_noqs]="quickshell is not installed — nothing to launch."
EN[next]="What's next:"
EN[next1]="  1. If the shell isn't running yet — re-login to Hyprland (or run:  quickshell -d -p %s)"
EN[next2]="  2. If something doesn't work — check the README first: %s"
EN[menu_title]="What to install?"
EN[menu_hint]="↑↓ move · Space toggle · a all · n none · Enter go"
EN[dep_title]="Dependencies"
EN[dep_summary]="%s of %s are missing."
EN[dep_legend]="✓ found   ✗ missing, will install   ! not in repos, install manually"
EN[note_missing]="missing: %s"
EN[note_ok]="all in place"
EN[note_done]="already in place, skipping"
EN[step_pkgs]="Missing packages (via the package manager, needs sudo)"
EN[step_font]="JetBrainsMono Nerd Font (icons)"
EN[step_shaders]="Build shaders (qsb)"
EN[step_link]="Link ~/.config/quickshell/tech (so \"quickshell -c tech\" works)"
EN[step_colors]="Starter colors file"
EN[step_auto]="Autostart in the Hyprland config (a backup is kept)"
EN[step_launch]="Launch the shell right after installing"
EN[running_skip]="quickshell is already running — leaving it alone (run the installer without -y to restart it)."
EN[scan_missing]="The QML calls programs that are not installed (heuristic, double-check): %s"
EN[ask_autoupd]="Check for .Tech updates automatically (on shell start and every few hours)?"
EN[autoupd_on]="Automatic update checks are on. Turn off: quickshell ipc -p %s call updater autoOff"
EN[autoupd_off]="Automatic update checks are off. Turn on: quickshell ipc -p %s call updater autoOn"
EN[bye]="Done! Good luck and enjoy ✨"

# ── помощники ───────────────────────────────────────────────────────────
t()  { if [[ $L == ru ]]; then printf '%s' "${RU[$1]}"; else printf '%s' "${EN[$1]}"; fi; }
say() { local f; f="$(t "$1")"; shift; printf "$f\n" "$@"; }
ok()   { printf '%s' "$C_OK";   say "$@"; printf '%s' "$C_RST"; }
warn() { printf '%s' "$C_WARN"; say "$@"; printf '%s' "$C_RST"; }
err()  { printf '%s' "$C_ERR";  say "$@"; printf '%s' "$C_RST"; }

run() {
    if (( DRY_RUN )); then
        printf '%s+ %s%s\n' "$C_ACC" "$*" "$C_RST"
        return 0
    fi
    "$@"
}

# установщик живёт отдельно и в ~/.tech/shell не нужен — не выкладываем install.sh в рабочую папку
# (sparse-checkout: в git чисто, обновления не конфликтуют; нет поддержки — просто удаляем файл)
strip_installer() {   # strip_installer <папка>
    run git -C "$1" sparse-checkout set --no-cone '/*' '!/install.sh' >/dev/null 2>&1 \
        || run rm -f -- "$1/install.sh"
}

# ask <ключ строки> [аргументы] → 0 если «да» (по умолчанию да)
ask() {
    local f ans
    f="$(t "$1")"; shift
    # shellcheck disable=SC2059
    printf "%s$f [Y/n] %s" "$C_B" "$@" "$C_RST"
    if (( ASSUME_YES )); then echo "y"; return 0; fi
    read -r ans </dev/tty || { echo; return 1; }
    [[ -z "$ans" || "$ans" =~ ^([yYдД]|[yY][eE][sS]|[дД][аА])$ ]]
}

# ver_ge A B → 0 если версия A >= B
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

hypr_version() {
    local v=""
    if command -v Hyprland >/dev/null 2>&1; then
        v="$(Hyprland --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    fi
    if [[ -z "$v" ]] && command -v hyprctl >/dev/null 2>&1; then
        v="$(hyprctl version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
    fi
    printf '%s' "$v"
}

# ── выбор шагов ─────────────────────────────────────────────────────────
STEPS=(pkgs font shaders link colors auto launch)
declare -A SEL
declare -A DONE   # шаги, которые уже сделаны — их пропускаем
for _k in "${STEPS[@]}"; do SEL[$_k]=1; done

want() { [[ "${SEL[$1]:-0}" == 1 ]]; }

hr() { printf '%s━━ %s %s' "$C_B" "$1" "$C_ACC"; printf '━%.0s' $(seq 1 $(( 58 - ${#1} ))); printf '%s\n' "$C_RST"; }

# пометка справа от пункта меню
step_note() {
    if [[ "$1" == pkgs ]] && (( HAVE_MISSING )); then
        printf '%s(%s)%s' "$C_WARN" "$(printf "$(t note_missing)" "$DEP_MISS")" "$C_RST"
    fi
    return 0
}

# что уже сделано: такие шаги не выбираем и пропускаем
detect_done() {
    local q f
    (( HAVE_MISSING )) || DONE[pkgs]=1
    if command -v fc-list >/dev/null 2>&1 && fc-list 2>/dev/null | grep -qi 'JetBrainsMono Nerd'; then DONE[font]=1; fi
    q="$HOME/.config/quickshell/$CONF_NAME"
    if [[ -L "$q" && "$(readlink -f "$q")" == "$(readlink -f "$INSTALL_DIR")" ]]; then DONE[link]=1; fi
    [[ -e "$HOME/.cache/quickshell/colors.json" ]] && DONE[colors]=1
    for f in "$HOME/.config/hypr/hyprland.lua" "$HOME/.config/hypr/hyprland.conf"; do
        if [[ -f "$f" ]] && grep -v '^[[:space:]]*\(--\|#\)' "$f" | grep -q 'quickshell'; then DONE[auto]=1; fi
    done
    for k in "${!DONE[@]}"; do SEL[$k]=0; done
}

# читает одну клавишу с терминала → KEY=up|down|space|enter|esc|eof|<символ>
read_key() {
    local k rest
    KEY=""
    IFS= read -rsn1 k </dev/tty || { KEY=eof; return; }
    if [[ $k == $'\e' ]]; then
        rest=""
        IFS= read -rsn2 -t 0.05 rest </dev/tty || true
        case "$rest" in
            '[A'|'OA') KEY=up ;;
            '[B'|'OB') KEY=down ;;
            *)         KEY=esc ;;
        esac
    elif [[ -z $k ]]; then KEY=enter
    elif [[ $k == ' ' ]]; then KEY=space
    else KEY="$k"
    fi
}

# рисует пункты меню; курсор — CUR. Печатает ровно ${#STEPS[@]}+1 строк.
render_menu() {
    local i k ptr box
    for i in "${!STEPS[@]}"; do
        k="${STEPS[i]}"
        printf '\r\e[2K'
        if [[ -n "${DONE[$k]:-}" ]]; then
            printf '    %s%d  %s✓%s%s  %s  (%s)%s\n' "$C_DIM" "$((i + 1))" "$C_OK" "$C_RST" "$C_DIM" "$(t "step_$k")" "$(t note_done)" "$C_RST"
            continue
        fi
        if want "$k"; then box="${C_OK}[x]${C_RST}"; else box="${C_DIM}[ ]${C_RST}"; fi
        if (( i == CUR )); then
            printf '  %s❯%s %s%d%s %s %s%s%s  %s\n' "$C_ACC" "$C_RST" "$C_ACC" "$((i + 1))" "$C_RST" "$box" "$C_B" "$(t "step_$k")" "$C_RST" "$(step_note "$k")"
        else
            printf '    %s%d%s %s %s  %s\n' "$C_DIM" "$((i + 1))" "$C_RST" "$box" "$(t "step_$k")" "$(step_note "$k")"
        fi
    done
    printf '\r\e[2K  %s%s%s\n' "$C_DIM" "$(t menu_hint)" "$C_RST"
}

# переместить курсор на следующий/предыдущий невыполненный пункт
move_cur() {   # move_cur <+1|-1>
    local i=$CUR n=${#STEPS[@]} c
    for (( c = 0; c < n; c++ )); do
        i=$(( (i + $1 + n) % n ))
        if [[ -z "${DONE[${STEPS[i]}]:-}" ]]; then CUR=$i; return; fi
    done
}

# выбор шагов стрелками: ↑↓ — двигаться, Пробел — вкл/выкл, Enter — поехали
choose_steps() {
    local k i total=$(( ${#STEPS[@]} + 1 )) active=0
    CUR=0
    for i in "${!STEPS[@]}"; do
        if [[ -z "${DONE[${STEPS[i]}]:-}" ]]; then (( active == 0 )) && CUR=$i; active=1; fi
    done
    (( active )) || return 0     # всё уже сделано — выбирать нечего

    echo; hr "$(t menu_title)"
    printf '\e[?25l'            # прячем курсор терминала
    trap 'printf "\e[?25h\n"; exit 130' INT
    render_menu
    while true; do
        read_key
        case "$KEY" in
            up|k)    move_cur -1 ;;
            down|j)  move_cur 1 ;;
            space)   k="${STEPS[CUR]}"; if want "$k"; then SEL[$k]=0; else SEL[$k]=1; fi ;;
            a|A)     for k in "${STEPS[@]}"; do [[ -z "${DONE[$k]:-}" ]] && SEL[$k]=1; done ;;
            n|N)     for k in "${STEPS[@]}"; do SEL[$k]=0; done ;;
            [1-9])   i=$(( KEY - 1 ))
                     if (( i < ${#STEPS[@]} )) && [[ -z "${DONE[${STEPS[i]}]:-}" ]]; then
                         CUR=$i; k="${STEPS[i]}"; if want "$k"; then SEL[$k]=0; else SEL[$k]=1; fi
                     fi ;;
            enter|eof) break ;;
        esac
        printf '\e[%dA' "$total"
        render_menu
    done
    printf '\e[?25h'
    trap - INT
}

# qsb в разных дистрибутивах называется по-разному (qsb, qsb-qt6) или лежит вне $PATH
QSB=""
find_qsb() {
    local c
    for c in qsb qsb-qt6 /usr/lib/qt6/bin/qsb /usr/lib64/qt6/bin/qsb /usr/lib/qt6/libexec/qsb; do
        if command -v "$c" >/dev/null 2>&1; then QSB="$c"; return 0; fi
    done
    return 1
}
have_cmd() { if [[ "$1" == qsb ]]; then find_qsb; else command -v "$1" >/dev/null 2>&1; fi; }

# программы, которые QML зовёт через command: [...] / execDetached([...]), но которых нет в системе
scan_used_commands() {
    [[ -d "$ROOT" ]] || return 0
    local c; local -a miss=()
    while read -r c; do
        [[ -z "$c" ]] && continue
        command -v "$c" >/dev/null 2>&1 || miss+=("$c")
    done < <(grep -rhoE '(command:|execDetached\()[[:space:]]*\[[[:space:]]*"[A-Za-z0-9_.+-]+"' \
                 --include='*.qml' "$ROOT" 2>/dev/null | grep -oE '"[^"]+"$' | tr -d '"' | sort -u)
    (( ${#miss[@]} )) && warn scan_missing "${miss[*]}"
    return 0
}

banner() {
    printf '%s' "$C_ACC"
    cat <<'EOF'

      ___              ___              ___              ___     
     /\  \            /\  \            /\  \            /\__\    
     \:\  \          /::\  \          /::\  \          /:/  /    
      \:\  \        /:/\:\  \        /:/\:\  \        /:/__/     
      /::\  \      /::\~\:\  \      /:/  \:\  \      /::\  \ ___ 
     /:/\:\__\    /:/\:\ \:\__\    /:/__/ \:\__\    /:/\:\  /\__\
    /:/  \/__/    \:\~\:\ \/__/    \:\  \  \/__/    \/__\:\/:/  /
   /:/  /          \:\ \:\__\       \:\  \               \::/  / 
   \/__/            \:\ \/__/        \:\  \              /:/  /  
                     \:\__\           \:\__\            /:/  /   
                      \/__/            \/__/            \/__/    

        dotfiles for Hyprland

EOF
    printf '%s' "$C_RST"
}

# ── 1. приветствие ──────────────────────────────────────────────────────
clear 2>/dev/null || true
banner

if [[ $EUID -eq 0 ]]; then
    L="en"; err root; echo "  (Не запускай от root.)"; exit 1
fi

# ── 2. язык ─────────────────────────────────────────────────────────────
DEFAULT_CHOICE=2
SYS_LANG="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
[[ "$SYS_LANG" == ru* ]] && DEFAULT_CHOICE=1
case "${TECH_LANG:-}" in ru) DEFAULT_CHOICE=1 ;; en) DEFAULT_CHOICE=2 ;; esac

if (( ASSUME_YES )) || [[ -n "${TECH_LANG:-}" ]]; then
    (( DEFAULT_CHOICE == 1 )) && L="ru" || L="en"
else
    while true; do
        printf '%s\n  1) Русский\n  2) English\n[%s]> ' "$(t lang_prompt)" "$DEFAULT_CHOICE"
        read -r choice </dev/tty || exit 1
        choice="${choice:-$DEFAULT_CHOICE}"
        case "$choice" in
            1) L="ru"; break ;;
            2) L="en"; break ;;
            *) say invalid ;;
        esac
    done
fi
echo
(( DRY_RUN )) && warn dry

# ── 2b. проверка версии — ДО выбора шагов ──────────────────────────────
# Если установка уже есть, сразу сравниваем v.version с GitHub:
#   совпали → «последняя версия» + 1 выйти / 2 переустановить
#   не совпали → предлагаем обновиться
if [[ -d "$INSTALL_DIR/.git" ]]; then
    ROOT="$INSTALL_DIR"
    LOCAL_VER="$(tr -d '[:space:]' < "$ROOT/$VERSION_FILE" 2>/dev/null)"
    REMOTE_VER=""
    if git -C "$ROOT" fetch -q --depth 1 origin 2>/dev/null; then
        REMOTE_VER="$(git -C "$ROOT" show "FETCH_HEAD:$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')"
    fi

    # снести установленную копию и поставить свежую
    # сначала качаем новую копию рядом, и только потом сносим старую —
    # если интернет пропал, старая установка остаётся целой
    do_reinstall() {
        if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
            warn ver_dirty "$ROOT"
        fi
        local NEW_DIR="$ROOT.new" REAL
        run rm -rf -- "$NEW_DIR"
        run git clone --depth 1 "$REPO_URL" "$NEW_DIR" || { err repo_fail; exit 1; }
        strip_installer "$NEW_DIR"
        REAL="$(readlink -f "$ROOT")"
        if [[ -z "$REAL" || "$REAL" == "/" || "$REAL" == "$(readlink -f "$HOME")" || "$REAL" == "$(readlink -f "$HOME/.tech")" ]]; then
            err wipe_refuse "$REAL"; exit 1
        fi
        run rm -rf -- "$REAL"
        run mv -- "$NEW_DIR" "$ROOT"
        ok reinstall_ok "${REMOTE_VER:-$LOCAL_VER}"
    }

    if [[ -z "$REMOTE_VER" ]]; then
        warn ver_unknown
        run git -C "$ROOT" pull --ff-only || true
    elif [[ "$LOCAL_VER" == "$REMOTE_VER" ]]; then
        # версии совпали: «You have the latest version» + 1 — выйти, 2 — переустановить
        ok ver_same "$LOCAL_VER"
        if (( ! ASSUME_YES )); then
            while true; do
                say ver_opt_exit
                say ver_opt_reinstall
                printf '%s%s%s' "$C_B" "$(t ver_choose)" "$C_RST"
                read -r VER_ANS </dev/tty || { echo; exit 0; }
                case "${VER_ANS:-1}" in
                    1) exit 0 ;;
                    2) do_reinstall; break ;;
                    *) say invalid ;;
                esac
            done
        fi
    else
        say ver_diff "${LOCAL_VER:-?}" "$REMOTE_VER"
        if ask ask_reinstall; then
            do_reinstall
        else
            warn ver_skip
        fi
    fi
fi

# ── 3. дистрибутив и менеджер пакетов ──────────────────────────────────
DISTRO="unknown"
[[ -r /etc/os-release ]] && DISTRO="$(. /etc/os-release; echo "${PRETTY_NAME:-${NAME:-unknown}}")"

PM=""; COL=0
if   command -v pacman  >/dev/null 2>&1; then PM="pacman"; COL=1
elif command -v apt-get >/dev/null 2>&1; then PM="apt";    COL=2
elif command -v dnf     >/dev/null 2>&1; then PM="dnf";    COL=3
elif command -v zypper  >/dev/null 2>&1; then PM="zypper"; COL=4
fi

if [[ -n "$PM" ]]; then say distro "$DISTRO" "$PM"; else warn distro_unknown; fi

# версия Hyprland (если уже стоит)
HYPR_VER="$(hypr_version)"
if [[ -n "$HYPR_VER" ]]; then
    say hypr_ver "$HYPR_VER"
    ver_ge "$HYPR_VER" "$MIN_LUA_VER" || warn hypr_old "$MIN_LUA_VER"
fi

install_pkgs() {
    case "$PM" in
        pacman) run sudo pacman -S --needed --noconfirm "$@" ;;
        apt)    run sudo apt-get update && run sudo apt-get install -y "$@" ;;
        dnf)    run sudo dnf install -y "$@" ;;
        zypper) run sudo zypper --non-interactive install "$@" ;;
    esac
}

# ── 3b. проверка зависимостей — ДО меню, чтобы было видно, что нужно ───
declare -A SEEN
PKGS=(); MANUAL=(); GRID=(); MISS_LINES=(); NEED_QS=0; HAVE_MISSING=0; DEP_MISS=0
DEP_TOTAL=${#DEPS[@]}

for row in "${DEPS[@]}"; do
    IFS='|' read -r cmd c_arch c_deb c_fed c_suse <<<"$row"
    if have_cmd "$cmd"; then GRID+=("ok|$cmd"); continue; fi
    HAVE_MISSING=1; DEP_MISS=$((DEP_MISS + 1))
    cols=("" "$c_arch" "$c_deb" "$c_fed" "$c_suse")
    pkg="${cols[$COL]:--}"

    if [[ "$cmd" == "quickshell" ]]; then NEED_QS=1; fi
    if [[ -z "$PM" || "$pkg" == "-" ]]; then
        MANUAL+=("$cmd"); GRID+=("man|$cmd")
        MISS_LINES+=("$C_WARN$(printf "$(t manual_item)" "$cmd")$C_RST")
    else
        GRID+=("bad|$cmd")
        MISS_LINES+=("$C_ERR$(printf "$(t missing_item)" "$cmd" "$pkg")$C_RST")
        if [[ "$cmd" != "quickshell" && -z "${SEEN[$pkg]:-}" ]]; then
            SEEN[$pkg]=1; PKGS+=("$pkg")
        fi
    fi
done

show_deps() {
    local i=0 item st name col icon line
    echo; hr "$(t dep_title)"
    for item in "${GRID[@]}"; do
        st="${item%%|*}"; name="${item#*|}"
        case "$st" in
            ok)  col="$C_OK";   icon="✓" ;;
            bad) col="$C_ERR";  icon="✗" ;;
            *)   col="$C_WARN"; icon="!" ;;
        esac
        printf '  %s%s%s %-17s' "$col" "$icon" "$C_RST" "$name"
        i=$((i + 1)); (( i % 3 == 0 )) && echo
    done
    (( i % 3 )) && echo
    echo
    if (( HAVE_MISSING )); then
        for line in "${MISS_LINES[@]}"; do printf '%s\n' "$line"; done
        echo
        warn dep_summary "$DEP_MISS" "$DEP_TOTAL"
        printf '%s  %s%s\n' "$C_DIM" "$(t dep_legend)" "$C_RST"
    else
        ok all_ok
    fi
}
show_deps
detect_done

# ── 3c. выбор шагов (без -y и только если есть терминал) ───────────────
(( ASSUME_YES )) || choose_steps

# ── 4. установка недостающего ──────────────────────────────────────────
if (( HAVE_MISSING == 0 )); then
    :
elif [[ -n "$PM" ]]; then
    echo
    if want pkgs; then
        say installing
        FAIL=0
        (( ${#PKGS[@]} )) && { install_pkgs "${PKGS[@]}" || FAIL=1; }

        # quickshell: Arch — сначала репозитории, потом AUR
        if (( NEED_QS )) && ! command -v quickshell >/dev/null 2>&1; then
            if [[ "$PM" == "pacman" ]]; then
                if ! run sudo pacman -S --needed --noconfirm quickshell; then
                    helper=""
                    for h in yay paru; do command -v "$h" >/dev/null 2>&1 && { helper="$h"; break; }; done
                    if [[ -n "$helper" ]]; then
                        say qs_aur "$helper"
                        run "$helper" -S --needed --noconfirm quickshell-git || FAIL=1
                    else
                        warn qs_manual; FAIL=1
                    fi
                fi
            elif [[ "$PM" == "dnf" ]]; then
                say qs_copr
                run sudo dnf install -y dnf-plugins-core
                if ! { run sudo dnf copr enable -y errornr/quickshell && run sudo dnf install -y quickshell; }; then
                    warn qs_manual; FAIL=1
                fi
            elif [[ "$PM" == "zypper" ]]; then
                say qs_try
                run sudo zypper --non-interactive install quickshell || { warn qs_manual; FAIL=1; }
            else
                warn qs_manual
            fi
        fi
        (( FAIL )) && warn install_fail
    else
        warn skip_install
    fi
else
    echo; warn skip_install
fi

# ── 4b. шрифт JetBrainsMono Nerd Font (иконки в баре и меню) ───────────
echo
if ! want font; then
    :
elif command -v fc-list >/dev/null 2>&1 && fc-list 2>/dev/null | grep -qi 'JetBrainsMono Nerd'; then
    say font_have
elif command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 && command -v xz >/dev/null 2>&1; then
    say font_get
    FONT_DIR="$HOME/.local/share/fonts/JetBrainsMonoNerd"
    FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz"
    if (( DRY_RUN )); then
        printf '%s+ download %s -> %s%s\n' "$C_ACC" "$FONT_URL" "$FONT_DIR" "$C_RST"
    else
        FONT_TMP="$(mktemp)"
        if mkdir -p "$FONT_DIR" && curl -fsSL "$FONT_URL" -o "$FONT_TMP" \
           && tar -xJf "$FONT_TMP" -C "$FONT_DIR" --wildcards '*.ttf'; then
            command -v fc-cache >/dev/null 2>&1 && fc-cache -f "$FONT_DIR" >/dev/null 2>&1
            ok font_ok
        else
            warn font_fail
        fi
        rm -f "$FONT_TMP"
    fi
else
    warn font_fail
fi

# ── 5. репозиторий ─────────────────────────────────────────────────────
echo
# Всегда ставим в $INSTALL_DIR (~/.tech/shell), независимо от того, откуда запущен скрипт.
if [[ -d "$INSTALL_DIR/.git" ]]; then
    ROOT="$INSTALL_DIR"   # версия уже проверена в шаге 2b
else
    ROOT="$INSTALL_DIR"
    if [[ -e "$INSTALL_DIR" && -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
        # папка занята чем-то посторонним (например, старой установкой в ~/.tech/shell)
        warn repo_notgit "$INSTALL_DIR"
        if ask ask_moveold; then
            BACKUP="$INSTALL_DIR.bak-$(date +%Y%m%d-%H%M%S)"
            run mv -- "$INSTALL_DIR" "$BACKUP" || exit 1
            ok moveold_ok "$BACKUP"
        else
            err moveold_no; exit 1
        fi
    fi
    say repo_clone "$ROOT"
    run mkdir -p "$(dirname "$ROOT")"
    run git clone --depth 1 "$REPO_URL" "$ROOT" || { err repo_fail; exit 1; }
    strip_installer "$ROOT"
fi

# ── 6. шейдеры (скомпилированные .qsb в git больше не хранятся) ─────────
build_shaders() {
say shaders_build
mapfile -t SHADERS < <(find "$ROOT" -type f \( -name '*.frag' -o -name '*.vert' \) -not -path '*/.git/*' 2>/dev/null)
if (( ${#SHADERS[@]} == 0 )); then
    say shaders_none
elif ! find_qsb && (( ! DRY_RUN )); then
    warn shaders_nosb
else
    built=0
    for f in "${SHADERS[@]}"; do
        if run "${QSB:-qsb}" --qt6 -o "$f.qsb" "$f"; then built=$((built + 1)); else say shaders_fail "$f"; fi
    done
    ok shaders_ok "$built"
fi
}
echo
want shaders && build_shaders
scan_used_commands

# ── 7. ссылка для «quickshell -c tech» ─────────────────────────────────
echo
QS_CONF="$HOME/.config/quickshell/$CONF_NAME"
if [[ -L "$QS_CONF" && "$(readlink -f "$QS_CONF")" == "$(readlink -f "$ROOT")" ]]; then
    :
elif [[ -L "$QS_CONF" && ! -e "$QS_CONF" ]] && want link; then
    # битая ссылка (например, на старую папку) — пересоздаём
    run ln -sfn "$ROOT" "$QS_CONF" && ok link_ok
elif [[ -e "$QS_CONF" || -L "$QS_CONF" ]]; then
    warn link_exists "$CONF_NAME"
elif want link; then
    run mkdir -p "$HOME/.config/quickshell"
    run ln -s "$ROOT" "$QS_CONF" && ok link_ok
fi

# ── 8. стартовые цвета (Logic.qml читает ~/.cache/quickshell/colors.json) ─
COLORS="$HOME/.cache/quickshell/colors.json"
if want colors && [[ ! -e "$COLORS" ]]; then
    run mkdir -p "$(dirname "$COLORS")"
    if (( DRY_RUN )); then
        printf '%s+ write %s%s\n' "$C_ACC" "$COLORS" "$C_RST"
    else
        printf '{\n  "bg": "#181825",\n  "accent": "#a3cef1",\n  "text": "#e0e1dd",\n  "secondary": "#3d5a80"\n}\n' > "$COLORS"
    fi
    say colors "$COLORS"
fi

# ── 9. автозапуск в Hyprland (Lua с 0.55, hyprlang — для старых версий) ──
echo
HYPR_DIR="$HOME/.config/hypr"
HLUA="$HYPR_DIR/hyprland.lua"
HCONF="$HYPR_DIR/hyprland.conf"

lua_block() {
    printf '\n-- .Tech shell\nhl.on("hyprland.start", function()\n  hl.exec_cmd("quickshell -p '"'"'%s'"'"'")\nend)\n' "$ROOT"
}
conf_block() {
    printf '\n# .Tech shell\nexec-once = quickshell -p '"'"'%s'"'"'\n' "$ROOT"
}

add_autostart() {   # add_autostart <файл> <lua|conf>
    local file="$1" kind="$2" bak
    bak="$file.bak-$(date +%Y%m%d-%H%M%S)"
    run cp "$file" "$bak"
    if (( DRY_RUN )); then
        printf '%s+ append to %s:%s\n' "$C_ACC" "$file" "$C_RST"
        if [[ $kind == lua ]]; then lua_block; else conf_block; fi
    else
        if [[ $kind == lua ]]; then lua_block >> "$file"; else conf_block >> "$file"; fi
    fi
    ok auto_ok "$bak"
}

if [[ -f "$HLUA" ]]; then
    TARGET="$HLUA"; KIND="lua"
elif [[ -f "$HCONF" ]]; then
    TARGET="$HCONF"; KIND="conf"
    say auto_legacy
else
    TARGET=""; KIND=""
fi

if ! want auto; then
    :
elif [[ -z "$TARGET" ]]; then
    warn auto_noconf
    printf '%s' "$C_ACC"; lua_block; printf '%s' "$C_RST"
    warn auto_noconf_old
    printf '%s' "$C_ACC"; conf_block; printf '%s' "$C_RST"
elif grep -v '^[[:space:]]*\(--\|#\)' "$TARGET" | grep -q 'quickshell'; then
    say auto_has "$TARGET"
else
    add_autostart "$TARGET" "$KIND"
fi

# ── 9b. автопроверка обновлений (настройка шелла: ~/.cache/qs-updater/state.json) ──
# Спрашиваем только если настройки ещё нет (первая установка) или её задали флагом.
# Дальше переключать можно из шелла: quickshell ipc -p <папка> call updater autoOn|autoOff
UPD_STATE="$HOME/.cache/qs-updater/state.json"
if [[ -n "$AUTO_UPD" || ! -e "$UPD_STATE" ]]; then
    echo
    if [[ -z "$AUTO_UPD" ]]; then
        if ask ask_autoupd; then AUTO_UPD=1; else AUTO_UPD=0; fi
    fi
    if (( DRY_RUN )); then
        printf '%s+ write %s (autoCheck=%s)%s\n' "$C_ACC" "$UPD_STATE" "$AUTO_UPD" "$C_RST"
    else
        mkdir -p "$(dirname "$UPD_STATE")"
        if [[ -s "$UPD_STATE" ]] && command -v python3 >/dev/null 2>&1; then
            # файл уже есть — меняем только autoCheck, остальное (интервал и т.д.) не трогаем
            python3 - "$UPD_STATE" "$AUTO_UPD" <<'PYJSON'
import json, sys
p, v = sys.argv[1], sys.argv[2] == "1"
try:
    d = json.load(open(p))
except Exception:
    d = {}
d["autoCheck"] = v
json.dump(d, open(p, "w"))
PYJSON
        else
            if (( AUTO_UPD )); then printf '{"autoCheck":true}' > "$UPD_STATE"; else printf '{"autoCheck":false}' > "$UPD_STATE"; fi
        fi
    fi
    if (( AUTO_UPD )); then say autoupd_on "$ROOT"; else say autoupd_off "$ROOT"; fi
fi

# ── 10. запуск прямо сейчас ────────────────────────────────────────────
echo
if ! want launch; then
    :
elif ! command -v quickshell >/dev/null 2>&1 && (( ! DRY_RUN )); then
    warn launch_noqs
elif [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" && -z "${WAYLAND_DISPLAY:-}" ]] && (( ! DRY_RUN )); then
    warn launch_nohypr "$ROOT"
else
    GO=1
    if pgrep -x quickshell >/dev/null 2>&1 && (( ! DRY_RUN )); then
        if (( ASSUME_YES )); then
            warn running_skip; GO=0
        elif ask ask_restart; then
            pkill -x quickshell; sleep 0.5
        else
            GO=0
        fi
    fi
    if (( GO )); then
        if run quickshell -d -p "$ROOT"; then ok launch_ok; else err launch_fail "$ROOT"; fi
    fi
fi

# ── 11. финал ──────────────────────────────────────────────────────────
echo
printf '%s' "$C_B"; say next; printf '%s' "$C_RST"
say next1 "$ROOT"
say next2 "$README_URL"
echo
printf '%s' "$C_ACC"; say bye; printf '%s' "$C_RST"
