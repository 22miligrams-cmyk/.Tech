#!/usr/bin/env python3
# qsbinds.py - пишет бинды запуска лаунчеров Quickshell в конфиг Hyprland: hyprland.lua (0.55+)
# или hyprland.conf (старые версии). Формат выбирается сам по файлу.
# Вызывается из SettingsMenu.qml (вкладка «Бинды») с одним аргументом - json:
#   qsbinds.py '{"enabled": true, "mod": "auto", "binds": [{"key": "D", "cmd": "..."}]}'
# Скрипт сам дописывает в конец конфига управляемый блок между маркерами qs-binds и делает hyprctl reload,
# остальной конфиг не трогает. enabled=false убирает блок. mod="auto" - берёт главный модификатор из конфига,
# иначе можно задать SUPER / ALT / CTRL / SHIFT или комбинацию через "+". Необязательное поле "alttab"
# добавляет бинды переключателя окон. После записи проверяется, что Hyprland увидел все бинды,
# нет ли конфликтов, а если конфиг после записи дал новые ошибки - файл откатывается назад.
# Путь к конфигу берётся из $QS_HYPR_CONF (симлинки разворачиваются). Если переменной нет, берётся
# ~/.config/hypr/hyprland.lua, а если его нет, то ~/.config/hypr/hyprland.conf.
# Для hyprland.conf блок выглядит так: «bind = SUPER, D, exec, команда» между строками «# >>> qs-binds».
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import glob
from collections import Counter

# какой конфиг править: $QS_HYPR_CONF, иначе hyprland.lua (Hyprland 0.55+), иначе hyprland.conf (старые версии)
def find_conf():
    env = os.environ.get("QS_HYPR_CONF")
    if env:
        return env
    base = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "hypr")
    lua = os.path.join(base, "hyprland.lua")
    conf = os.path.join(base, "hyprland.conf")
    if os.path.isfile(lua):
        return lua
    return conf if os.path.isfile(conf) else lua


HYPRLAND_CONF = find_conf()
FMT = "lua"   # "lua" или "conf"; выставляется в main() по файлу

COMMENT = {"lua": "--", "conf": "#"}
# маркеры блока в обоих форматах (старый блок убираем независимо от того, каким он был)
BLOCK_RE = re.compile(r"\n*(?:--|#) >>> qs-binds[^\n]*\n.*?(?:--|#) <<< qs-binds[^\n]*\n?", re.S)


def begin_mark():
    return COMMENT[FMT] + " >>> qs-binds (генерируется настройками Quickshell, руками не править)"


def end_mark():
    return COMMENT[FMT] + " <<< qs-binds"

USE_RE = re.compile(r"hl\.bind\(\s*([A-Za-z_]\w*)\s*\.\.")
LIT_RE = re.compile(r'^(?:local\s+)?([A-Za-z_]\w*)\s*=\s*"([A-Za-z_ +]+)"', re.M)

# hyprland.conf: переменные «$mainMod = SUPER» и использование «bind = $mainMod SHIFT, Q, ...»
CONF_VAR_RE = re.compile(r"^\s*\$([A-Za-z_]\w*)\s*=\s*([^\n#]*)", re.M)
CONF_USE_RE = re.compile(r"^\s*bind[a-z]*\s*=\s*\$([A-Za-z_]\w*)", re.M)
CONF_SOURCE_RE = re.compile(r"^\s*source\s*=\s*([^\n#]+)", re.M)

KEY_RE = re.compile(r"^(?:[A-Za-z0-9_]{1,32}|mouse:\d{3})$")
MODS = ("SUPER", "ALT", "CTRL", "SHIFT")
MASKS = {"SHIFT": 1, "CTRL": 4, "ALT": 8, "SUPER": 64}
MASK_ORDER = ("SUPER", "CTRL", "ALT", "SHIFT")

AT_RELEASE = {"ALT": ("ALT_L", "ALT_R"), "CTRL": ("CONTROL_L", "CONTROL_R"), "SUPER": ("SUPER_L", "SUPER_R")}
AT_KEY_RE = re.compile(r"^[A-Za-z0-9_]+$")

MSG = {
    "ru": {
        "no_var": "нет переменной %s на верхнем уровне конфига — бинд пропущен",
        "no_file": "нет файла ",
        "updated": "конфиг обновлён",
        "same": "конфиг без изменений",
        "no_hyprctl": "hyprctl не найден",
        "hang": "hyprctl завис",
        "err": "ошибка в конфиге Hyprland: ",
        "rollback": "конфиг возвращён к прежнему состоянию, ошибка: ",
        "sees": "Hyprland видит биндов: %d из %d",
        "no_sees": "Hyprland НЕ видит биндов — проверь конфиг Hyprland (hyprland.lua или hyprland.conf)",
        "missing": "Hyprland не видит: %s",
        "conflict": "конфликт, комбинация занята дважды: %s",
        "auto_mod": "auto = %s",
        "at_bad": "Alt+Tab: неподдерживаемая комбинация — бинд пропущен",
    },
    "en": {
        "no_var": "no top-level variable %s in the config — bind skipped",
        "no_file": "file not found: ",
        "updated": "config updated",
        "same": "config unchanged",
        "no_hyprctl": "hyprctl not found",
        "hang": "hyprctl hung",
        "err": "Hyprland config error: ",
        "rollback": "config restored to its previous state, error: ",
        "sees": "Hyprland sees binds: %d of %d",
        "no_sees": "Hyprland does NOT see the binds — check your Hyprland config (hyprland.lua or hyprland.conf)",
        "missing": "Hyprland does not see: %s",
        "conflict": "conflict, combination is bound twice: %s",
        "auto_mod": "auto = %s",
        "at_bad": "Alt+Tab: unsupported combination — bind skipped",
    },
}
T = MSG["ru"]


# ошибка, когда hyprctl недоступен; в args[0] лежит ключ сообщения из MSG
class HyprctlError(Exception):
    pass


# запускает hyprctl с аргументами и возвращает его stdout
def hyprctl(*args):
    try:
        r = subprocess.run(["hyprctl", *args], timeout=10, capture_output=True, text=True)
    except FileNotFoundError:
        raise HyprctlError("no_hyprctl")
    except subprocess.TimeoutExpired:
        raise HyprctlError("hang")
    return r.stdout


# список биндов, которые сейчас знает Hyprland (hyprctl binds -j), при кривом ответе пустой
def load_binds():
    try:
        data = json.loads(hyprctl("binds", "-j"))
        return data if isinstance(data, list) else []
    except ValueError:
        return []


# True, если в выводе configerrors есть настоящая ошибка
def has_errs(s):
    s = (s or "").strip()
    return bool(s) and "no errors" not in s.lower()


# экранирует строку и оборачивает в кавычки для lua
def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


# разбивает строку модификаторов ('SUPER+shift', 'control alt') на список имён.
# Если встретилось незнакомое слово - возвращает None
def norm_mod_tokens(s):
    out = []
    for t in re.split(r"[\s+]+", str(s).strip().upper()):
        if not t:
            continue
        t = "CTRL" if t == "CONTROL" else t
        if t not in MASKS:
            return None
        if t not in out:
            out.append(t)
    return out or None


# строка модификаторов -> числовая маска Hyprland (или None)
def mask_of(mod_str):
    toks = norm_mod_tokens(mod_str) if mod_str else None
    if not toks:
        return None
    m = 0
    for t in toks:
        m |= MASKS[t]
    return m


# числовая маска -> читаемое имя вроде "SUPER + SHIFT"
def mask_name(mask):
    return " + ".join(n for n in MASK_ORDER if mask & MASKS[n])


# ищет главный модификатор конфига. Сначала самую частую переменную в hl.bind(NAME .. ...)
# с верхнего уровня (и её значение, если оно строковый литерал), если не вышло - самую частую маску
# среди биндов Hyprland. Возвращает (имя_переменной | None, значение | None)
def detect_main_mod(content, binds_json):
    if FMT == "conf":
        declared = {n: v.strip() for n, v in CONF_VAR_RE.findall(content)}
        uses = CONF_USE_RE.findall(content)
        top_level = lambda n: n in declared
    else:
        declared = {n: v for n, v in LIT_RE.findall(content)}
        uses = USE_RE.findall(content)
        top_level = lambda n: re.search(r"^(?:local\s+)?%s\s*=" % re.escape(n), content, re.M)
    name = value = None
    for cand, _ in Counter(uses).most_common():
        if top_level(cand):
            name = cand
            if cand in declared and norm_mod_tokens(declared[cand]):
                value = " + ".join(norm_mod_tokens(declared[cand]))
            break
    if value is None and binds_json:
        masks = Counter(b.get("modmask") for b in binds_json
                        if b.get("key") and isinstance(b.get("modmask"), int) and b.get("modmask"))
        if masks:
            value = mask_name(masks.most_common(1)[0][0]) or None
    return name, value


# экранирует команду для hyprland.conf: переводы строк в пробел, «#» удваивается (иначе это комментарий)
def conf_str(s):
    return str(s).replace("\r", " ").replace("\n", " ").replace("#", "##")


# одна строка бинда.
#   lua:  hl.bind("SUPER + SHIFT + D", hl.dsp.exec_cmd("cmd"))
#   conf: bind = SUPER SHIFT, D, exec, cmd
# mods - модификаторы текстом («SUPER + SHIFT»); mods_var - имя переменной главного модификатора,
# если бинд идёт через неё (в conf это «$mainMod»); action_is_var - action это имя переменной, а не команда
def bind_line(mods, key, action, release=False, mods_var=None, action_is_var=False):
    if FMT == "conf":
        m = ("$" + mods_var) if mods_var else " ".join(norm_mod_tokens(mods) or [str(mods)])
        act = ("$" + action) if action_is_var else conf_str(action)
        return "%s = %s, %s, exec, %s" % ("bindr" if release else "bind", m, key, act)
    keyexpr = ('%s .. " + %s"' % (mods_var, key)) if mods_var else lua_str("%s + %s" % (mods, key))
    act = action if action_is_var else lua_str(action)
    return "hl.bind(%s, hl.dsp.exec_cmd(%s)%s)" % (keyexpr, act, ", { release = true }" if release else "")


# собирает строки для Alt+Tab (переключение вперёд, назад и подтверждение при отпускании модификатора)
# и список комбинаций, которые потом надо проверить в Hyprland
def alttab_lines(at, notes):
    mod = str(at.get("mod", "ALT")).upper()
    mod = "CTRL" if mod == "CONTROL" else mod
    key = str(at.get("key", "Tab"))
    prefix = str(at.get("prefix") or "quickshell ipc").strip() or "quickshell ipc"
    if mod not in AT_RELEASE or not AT_KEY_RE.match(key):
        notes.append(T["at_bad"])
        return [], []
    out = [
        bind_line(mod, key, prefix + " call shell alttab"),
        bind_line(mod + " + SHIFT", key, prefix + " call shell alttabPrev"),
    ]
    for rk in AT_RELEASE[mod]:
        out.append(bind_line(mod, rk, prefix + " call shell alttabCommit", release=True))
    m = MASKS[mod]
    exp = [(m, key.upper(), False, "%s + %s" % (mod, key)),
           (m | MASKS["SHIFT"], key.upper(), False, "%s + SHIFT + %s" % (mod, key))]
    return out, exp


# собирает весь управляемый блок для конфига: по строке hl.bind на каждый бинд плюс alttab.
# Возвращает текст блока и список ожидаемых комбинаций для проверки после reload
def build_block(mod, binds, content, notes, alttab, main):
    name, value = main
    lines = [begin_mark()]
    expected = []
    for b in binds:
        key = str(b.get("key", "")).strip()
        cmd = str(b.get("cmd", ""))
        action_var = b.get("var")
        if not KEY_RE.match(key):
            continue
        key = key if key.lower().startswith("mouse:") else key.upper()
        if action_var:
            if FMT == "conf":
                var_ok = action_var in {n for n, _ in CONF_VAR_RE.findall(content)}
            else:
                var_ok = bool(re.search(r"^(?:local\s+)?%s\s*=" % re.escape(action_var), content, re.M))
            if not re.match(r"^[A-Za-z_]\w*$", action_var) or not var_ok:
                notes.append(T["no_var"] % (("$" if FMT == "conf" else "") + action_var))
                continue
        elif not cmd:
            continue

        if mod == "auto" and name:
            mods_var = name
            mod_str = None
            mask = mask_of(value)
            label = "%s + %s" % (value or name, key)
        else:
            mods_var = None
            mod_str = value if (mod == "auto" and value) else ("SUPER" if mod == "auto" else mod)
            mask = mask_of(mod_str)
            label = "%s + %s" % (mod_str, key)
        lines.append(bind_line(mod_str, key, action_var if action_var else cmd,
                               mods_var=mods_var, action_is_var=bool(action_var)))
        if mask is not None:
            expected.append((mask, key.upper(), False, label))

    if alttab and alttab.get("enabled"):
        at_lines, at_exp = alttab_lines(alttab, notes)
        lines.extend(at_lines)
        expected.extend(at_exp)
    lines.append(end_mark())
    return "\n".join(lines) + "\n", expected


# для hyprland.conf: текст файлов, подключённых через «source = …» (до 3 уровней вложенности).
# Нужен только чтобы найти там $mainMod и $fileManager; писать в них мы ничего не будем
def sourced_text(path, depth=0, seen=None):
    seen = seen if seen is not None else {os.path.realpath(path)}
    if depth >= 3:
        return ""
    try:
        with open(path, "r", encoding="utf-8") as f:
            src = f.read()
    except OSError:
        return ""
    out = []
    for raw in CONF_SOURCE_RE.findall(src):
        pat = os.path.expanduser(raw.strip())
        if not os.path.isabs(pat):
            pat = os.path.join(os.path.dirname(path), pat)
        for p in sorted(glob.glob(pat)):
            rp = os.path.realpath(p)
            if rp in seen or not os.path.isfile(rp):
                continue
            seen.add(rp)
            try:
                with open(rp, "r", encoding="utf-8") as f:
                    out.append(f.read())
            except OSError:
                continue
            out.append(sourced_text(rp, depth + 1, seen))
    return "\n".join(out)


# записывает файл через временный файл и os.replace, чтобы при сбое не остался обрубок
def atomic_write(path, text):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".tmp_")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


# точка входа: читает json из аргумента, переписывает блок в конфиге, делает reload,
# откатывает при новых ошибках и печатает статус (его потом показывает меню настроек)
def main():
    if len(sys.argv) < 2:
        sys.exit("usage: qsbinds.py '<json>'")
    global T
    cfg = json.loads(sys.argv[1])
    T = MSG.get(cfg.get("lang"), MSG["ru"])

    mod = cfg.get("mod", "auto")
    if mod != "auto":
        toks = norm_mod_tokens(mod)
        mod = " + ".join(toks) if toks else "auto"

    path = os.path.realpath(HYPRLAND_CONF)
    if not os.path.isfile(path):
        sys.exit(T["no_file"] + HYPRLAND_CONF)
    global FMT
    FMT = "lua" if (HYPRLAND_CONF.lower().endswith(".lua") or path.lower().endswith(".lua")) else "conf"
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()

    errs_before = None
    binds_before = []
    try:
        errs_before = hyprctl("configerrors").strip()
        binds_before = load_binds()
    except HyprctlError:
        pass

    base = BLOCK_RE.sub("\n", content).rstrip("\n") + "\n"
    notes = []
    expected = []
    # для conf переменные могут лежать в подключённых через source файлах, ищем и там
    scan = base + ("\n" + sourced_text(path) if FMT == "conf" else "")
    main_mod = detect_main_mod(scan, binds_before)
    alttab = cfg.get("alttab") if isinstance(cfg.get("alttab"), dict) else {}
    if cfg.get("enabled") or alttab.get("enabled"):
        binds_in = cfg.get("binds", []) if cfg.get("enabled") else []
        block, expected = build_block(mod, binds_in, scan, notes, alttab, main_mod)
        updated = base + "\n" + block
    else:
        updated = base

    changed = updated != content
    if changed:
        backup = path + ".qs-bak"
        if not os.path.exists(backup):
            shutil.copy2(path, backup)
        atomic_write(path, updated)
        print(T["updated"])
    else:
        print(T["same"])

    try:
        hyprctl("reload")
        errs = hyprctl("configerrors").strip()
        binds = load_binds()

        if changed and errs_before is not None and has_errs(errs) and errs != errs_before:
            atomic_write(path, content)
            hyprctl("reload")
            print(T["rollback"] + errs.replace("\n", " ")[:200])
            return
    except HyprctlError as e:
        print(T[e.args[0]])
        return

    for note in notes:
        print(note)

    if has_errs(errs):
        print(T["err"] + errs.replace("\n", " ")[:200])
        return
    if not (cfg.get("enabled") or alttab.get("enabled")):
        return

    if mod == "auto" and main_mod[1] and cfg.get("enabled"):
        print(T["auto_mod"] % (main_mod[1] + (" (%s)" % main_mod[0] if main_mod[0] else "")))

    if not expected:
        return
    seen = Counter((b.get("modmask"), str(b.get("key", "")).upper(), bool(b.get("release")), b.get("submap", ""))
                   for b in binds if b.get("key"))
    have = {k[:3] for k in seen}
    missing = [lbl for m, k, r, lbl in expected if (m, k, r) not in have]
    conflicts = sorted({lbl for m, k, r, lbl in expected
                        if sum(c for kk, c in seen.items() if kk[:3] == (m, k, r)) > 1})
    ok = len(expected) - len(missing)
    if ok == 0:
        print(T["no_sees"])
    elif missing:
        print(T["sees"] % (ok, len(expected)))
        print(T["missing"] % ", ".join(missing))
    else:
        print(T["sees"] % (ok, len(expected)))
    if conflicts:
        print(T["conflict"] % ", ".join(conflicts))


if __name__ == "__main__":
    main()
