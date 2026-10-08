#!/usr/bin/env bash
# .Tech installer / установщик .Tech
#
#   ./install.sh              — обычная установка / normal install
#   ./install.sh --yes        — на все вопросы «да» / answer "yes" to every question
#   ./install.sh --dry-run    — ничего не менять, только показать шаги / change nothing, just show steps
#   ./install.sh --help
#
# Пакеты, которые проверяются, перечислены в массиве DEPS ниже — правь его под свои нужды.

set -uo pipefail

REPO_URL="https://github.com/22miligrams-cmyk/.Tech.git"
README_URL="https://github.com/22miligrams-cmyk/.Tech#readme"
INSTALL_DIR="${TECH_DIR:-$HOME/.tech/shell}"
CONF_NAME="tech"   # quickshell -c tech
MIN_LUA_VER="0.55.0"   # с этой версии Hyprland конфиг на Lua / Lua config since this version
DRY_RUN=0
ASSUME_YES=0

for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=1 ;;
        -y|--yes)   ASSUME_YES=1 ;;
        -h|--help)  sed -n '2,9p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
    esac
done

# ── цвета ───────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RST=$'\e[0m'; C_B=$'\e[1m'; C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_ACC=$'\e[38;2;163;206;241m'
else
    C_RST=""; C_B=""; C_OK=""; C_WARN=""; C_ERR=""; C_ACC=""
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
    "stdbuf|coreutils|coreutils|coreutils|coreutils"
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
RU[manual_item]="  ✗ %s  — в репозиториях этого дистрибутива нет, нужно поставить вручную"
RU[ask_install]="Установить недостающее из репозиториев?"
RU[skip_install]="Пропускаю установку пакетов. Без них шелл может не запуститься."
RU[installing]="Ставлю пакеты…"
RU[install_fail]="Не все пакеты поставились — смотри ошибки выше."
RU[qs_aur]="quickshell нет в основных репозиториях, пробую AUR (%s)…"
RU[qs_manual]="quickshell не установлен. Инструкция: https://quickshell.org"
RU[repo_using]="Использую текущую папку: %s"
RU[repo_pull]="Репозиторий уже есть в %s — обновляю."
RU[repo_clone]="Клонирую репозиторий в %s…"
RU[repo_fail]="Не получилось получить репозиторий. Проверь интернет и права на папку."
RU[shaders_build]="Собираю шейдеры (qsb)…"
RU[shaders_none]="Исходников шейдеров (.frag/.vert) не найдено — пропускаю."
RU[shaders_nosb]="qsb не найден — шейдеры не собраны (ставь qt6-shadertools)."
RU[shaders_fail]="  ✗ не собрался: %s"
RU[shaders_ok]="Шейдеров собрано: %s"
RU[ask_link]="Сделать ссылку ~/.config/quickshell/%s → %s (чтобы работало «quickshell -c %s»)?"
RU[link_ok]="Ссылка создана."
RU[link_exists]="~/.config/quickshell/%s уже существует и ведёт не туда — не трогаю."
RU[colors]="Создал стартовый файл цветов: %s"
RU[ask_auto]="Добавить автозапуск в %s? (старый файл сохраню как .bak)"
RU[auto_ok]="Автозапуск добавлен. Бэкап: %s"
RU[auto_has]="В %s уже есть запуск quickshell — не трогаю."
RU[auto_legacy]="Нашёл только старый hyprland.conf (hyprlang) — пропишу автозапуск там."
RU[auto_noconf]="Не нашёл конфиг Hyprland. Добавь вручную в ~/.config/hypr/hyprland.lua:"
RU[auto_noconf_old]="или, для старого формата, в ~/.config/hypr/hyprland.conf:"
RU[ask_launch]="Запустить шелл прямо сейчас?"
RU[ask_restart]="quickshell уже запущен. Перезапустить его?"
RU[launch_ok]="Шелл запущен."
RU[launch_fail]="Не получилось запустить шелл. Попробуй вручную: quickshell -p %s"
RU[launch_nohypr]="Сейчас не запущен Hyprland (или нет доступа к его сессии) — запусти шелл после входа: quickshell -d -p %s"
RU[launch_noqs]="quickshell не установлен — запускать нечего."
RU[next]="Что дальше:"
RU[next1]="  1. Если шелл ещё не запущен — перезайди в Hyprland (или выполни:  quickshell -d -p %s)"
RU[next2]="  2. Если что-то не работает — сначала загляни в README: %s"
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
EN[manual_item]="  ✗ %s  — not in this distro's repositories, install it manually"
EN[ask_install]="Install the missing packages from the repositories?"
EN[skip_install]="Skipping package installation. The shell may not start without them."
EN[installing]="Installing packages…"
EN[install_fail]="Not every package installed — see the errors above."
EN[qs_aur]="quickshell is not in the main repos, trying AUR (%s)…"
EN[qs_manual]="quickshell is not installed. Instructions: https://quickshell.org"
EN[repo_using]="Using the current folder: %s"
EN[repo_pull]="Repository already exists in %s — updating."
EN[repo_clone]="Cloning the repository into %s…"
EN[repo_fail]="Could not get the repository. Check your internet and folder permissions."
EN[shaders_build]="Building shaders (qsb)…"
EN[shaders_none]="No shader sources (.frag/.vert) found — skipping."
EN[shaders_nosb]="qsb not found — shaders not built (install qt6-shadertools)."
EN[shaders_fail]="  ✗ failed to build: %s"
EN[shaders_ok]="Shaders built: %s"
EN[ask_link]="Create a link ~/.config/quickshell/%s → %s (so that \"quickshell -c %s\" works)?"
EN[link_ok]="Link created."
EN[link_exists]="~/.config/quickshell/%s already exists and points elsewhere — leaving it alone."
EN[colors]="Created a starter colors file: %s"
EN[ask_auto]="Add autostart to %s? (the old file will be saved as .bak)"
EN[auto_ok]="Autostart added. Backup: %s"
EN[auto_has]="%s already launches quickshell — leaving it alone."
EN[auto_legacy]="Only the old hyprland.conf (hyprlang) was found — adding autostart there."
EN[auto_noconf]="Could not find a Hyprland config. Add this manually to ~/.config/hypr/hyprland.lua:"
EN[auto_noconf_old]="or, for the old format, to ~/.config/hypr/hyprland.conf:"
EN[ask_launch]="Launch the shell right now?"
EN[ask_restart]="quickshell is already running. Restart it?"
EN[launch_ok]="Shell started."
EN[launch_fail]="Could not start the shell. Try manually: quickshell -p %s"
EN[launch_nohypr]="Hyprland isn't running (or its session isn't reachable) — start the shell after logging in: quickshell -d -p %s"
EN[launch_noqs]="quickshell is not installed — nothing to launch."
EN[next]="What's next:"
EN[next1]="  1. If the shell isn't running yet — re-login to Hyprland (or run:  quickshell -d -p %s)"
EN[next2]="  2. If something doesn't work — check the README first: %s"
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

# ask <ключ строки> [аргументы] → 0 если «да» (по умолчанию да)
ask() {
    local f ans
    f="$(t "$1")"; shift
    # shellcheck disable=SC2059
    printf "%s$f [Y/n] %s" "$C_B" "$@" "$C_RST"
    if (( ASSUME_YES )); then echo "y"; return 0; fi
    read -r ans || { echo; return 1; }
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

banner() {
    printf '%s' "$C_ACC"
    cat <<'EOF'

        _____         _
       |_   _|__  ___| |__
         | |/ _ \/ __| '_ \
    _    | |  __/ (__| | | |
   (_)   |_|\___|\___|_| |_|

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
[[ "${LANG:-}" == ru* ]] && DEFAULT_CHOICE=1

if (( ASSUME_YES )); then
    (( DEFAULT_CHOICE == 1 )) && L="ru" || L="en"
else
    while true; do
        printf '%s\n  1) Русский\n  2) English\n[%s]> ' "$(t lang_prompt)" "$DEFAULT_CHOICE"
        read -r choice || exit 1
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

# ── 4. что отсутствует ─────────────────────────────────────────────────
echo; say checking
declare -A SEEN
PKGS=(); MANUAL=(); NEED_QS=0; HAVE_MISSING=0

for row in "${DEPS[@]}"; do
    IFS='|' read -r cmd c_arch c_deb c_fed c_suse <<<"$row"
    command -v "$cmd" >/dev/null 2>&1 && continue
    HAVE_MISSING=1
    cols=("" "$c_arch" "$c_deb" "$c_fed" "$c_suse")
    pkg="${cols[$COL]:--}"

    if [[ "$cmd" == "quickshell" ]]; then NEED_QS=1; fi
    if [[ -z "$PM" || "$pkg" == "-" ]]; then
        MANUAL+=("$cmd")
    else
        printf '%s%s%s\n' "$C_WARN" "$(printf "$(t missing_item)" "$cmd" "$pkg")" "$C_RST"
        if [[ "$cmd" != "quickshell" && -z "${SEEN[$pkg]:-}" ]]; then
            SEEN[$pkg]=1; PKGS+=("$pkg")
        fi
    fi
done
for m in "${MANUAL[@]+"${MANUAL[@]}"}"; do
    printf '%s%s%s\n' "$C_WARN" "$(printf "$(t manual_item)" "$m")" "$C_RST"
done

if (( HAVE_MISSING == 0 )); then
    ok all_ok
elif [[ -n "$PM" ]]; then
    echo
    if ask ask_install; then
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

# ── 5. репозиторий ─────────────────────────────────────────────────────
echo
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [[ -f "$SCRIPT_DIR/shell.qml" ]]; then
    ROOT="$SCRIPT_DIR"
    say repo_using "$ROOT"
elif [[ -d "$INSTALL_DIR/.git" ]]; then
    ROOT="$INSTALL_DIR"
    say repo_pull "$ROOT"
    run git -C "$ROOT" pull --ff-only || true
else
    ROOT="$INSTALL_DIR"
    say repo_clone "$ROOT"
    run mkdir -p "$(dirname "$ROOT")"
    run git clone --depth 1 "$REPO_URL" "$ROOT" || { err repo_fail; exit 1; }
fi

# ── 6. шейдеры (скомпилированные .qsb в git больше не хранятся) ─────────
echo; say shaders_build
mapfile -t SHADERS < <(find "$ROOT" -type f \( -name '*.frag' -o -name '*.vert' \) -not -path '*/.git/*' 2>/dev/null)
if (( ${#SHADERS[@]} == 0 )); then
    say shaders_none
elif ! command -v qsb >/dev/null 2>&1 && (( ! DRY_RUN )); then
    warn shaders_nosb
else
    built=0
    for f in "${SHADERS[@]}"; do
        if run qsb --qt6 -o "$f.qsb" "$f"; then built=$((built + 1)); else say shaders_fail "$f"; fi
    done
    ok shaders_ok "$built"
fi

# ── 7. ссылка для «quickshell -c tech» ─────────────────────────────────
echo
QS_CONF="$HOME/.config/quickshell/$CONF_NAME"
if [[ -L "$QS_CONF" && "$(readlink -f "$QS_CONF")" == "$(readlink -f "$ROOT")" ]]; then
    :
elif [[ -e "$QS_CONF" || -L "$QS_CONF" ]]; then
    warn link_exists "$CONF_NAME"
elif ask ask_link "$CONF_NAME" "$ROOT" "$CONF_NAME"; then
    run mkdir -p "$HOME/.config/quickshell"
    run ln -s "$ROOT" "$QS_CONF" && ok link_ok
fi

# ── 8. стартовые цвета (Logic.qml читает ~/.cache/quickshell/colors.json) ─
COLORS="$HOME/.cache/quickshell/colors.json"
if [[ ! -e "$COLORS" ]]; then
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

if [[ -z "$TARGET" ]]; then
    warn auto_noconf
    printf '%s' "$C_ACC"; lua_block; printf '%s' "$C_RST"
    warn auto_noconf_old
    printf '%s' "$C_ACC"; conf_block; printf '%s' "$C_RST"
elif grep -v '^[[:space:]]*\(--\|#\)' "$TARGET" | grep -q 'quickshell'; then
    say auto_has "$TARGET"
elif ask ask_auto "$TARGET"; then
    add_autostart "$TARGET" "$KIND"
fi

# ── 10. запуск прямо сейчас ────────────────────────────────────────────
echo
if ! command -v quickshell >/dev/null 2>&1 && (( ! DRY_RUN )); then
    warn launch_noqs
elif [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" && -z "${WAYLAND_DISPLAY:-}" ]] && (( ! DRY_RUN )); then
    warn launch_nohypr "$ROOT"
elif ask ask_launch; then
    GO=1
    if pgrep -x quickshell >/dev/null 2>&1 && (( ! DRY_RUN )); then
        if ask ask_restart; then
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
