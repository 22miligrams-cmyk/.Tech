#!/usr/bin/env python3
# qsbinds.py - пишет бинды запуска лаунчеров Quickshell в hyprland.lua.
# Вызывается из SettingsMenu.qml (вкладка «Бинды») с одним аргументом - json:
#   qsbinds.py '{"enabled": true, "mod": "auto", "binds": [{"key": "D", "cmd": "..."}]}'
# Скрипт сам дописывает в конец конфига управляемый блок между маркерами qs-binds и делает hyprctl reload,
# остальной конфиг не трогает. enabled=false убирает блок. mod="auto" - берёт главный модификатор из конфига,
# иначе можно задать SUPER / ALT / CTRL / SHIFT или комбинацию через "+". Необязательное поле "alttab"
# добавляет бинды переключателя окон. После записи проверяется, что Hyprland увидел все бинды,
# нет ли конфликтов, а если конфиг после записи дал новые ошибки - файл откатывается назад.
# Путь к конфигу берётся из $QS_HYPR_CONF (симлинки разворачиваются).
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter

HYPRLAND_CONF = os.environ.get("QS_HYPR_CONF", os.path.expanduser("~/.config/hypr/hyprland.lua"))

BEGIN = "-- >>> qs-binds (генерируется настройками Quickshell, руками не править)"
END = "-- <<< qs-binds"
BLOCK_RE = re.compile(r"\n*-- >>> qs-binds[^\n]*\n.*?-- <<< qs-binds[^\n]*\n?", re.S)

USE_RE = re.compile(r"hl\.bind\(\s*([A-Za-z_]\w*)\s*\.\.")
LIT_RE = re.compile(r'^(?:local\s+)?([A-Za-z_]\w*)\s*=\s*"([A-Za-z_ +]+)"', re.M)

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
        "no_sees": "Hyprland НЕ видит биндов — проверь hyprland.lua",
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
        "no_sees": "Hyprland does NOT see the binds — check hyprland.lua",
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
    declared = {n: v for n, v in LIT_RE.findall(content)}
    top_level = lambda n: re.search(r"^(?:local\s+)?%s\s*=" % re.escape(n), content, re.M)
    name = value = None
    for cand, _ in Counter(USE_RE.findall(content)).most_common():
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


# собирает lua-строки для Alt+Tab (переключение вперёд, назад и подтверждение при отпускании модификатора)
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
        "hl.bind(%s, hl.dsp.exec_cmd(%s))" % (lua_str(mod + " + " + key), lua_str(prefix + " call shell alttab")),
        "hl.bind(%s, hl.dsp.exec_cmd(%s))" % (lua_str(mod + " + SHIFT + " + key), lua_str(prefix + " call shell alttabPrev")),
    ]
    for rk in AT_RELEASE[mod]:
        out.append("hl.bind(%s, hl.dsp.exec_cmd(%s), { release = true })"
                   % (lua_str(mod + " + " + rk), lua_str(prefix + " call shell alttabCommit")))
    m = MASKS[mod]
    exp = [(m, key.upper(), False, "%s + %s" % (mod, key)),
           (m | MASKS["SHIFT"], key.upper(), False, "%s + SHIFT + %s" % (mod, key))]
    return out, exp


# собирает весь управляемый блок для конфига: по строке hl.bind на каждый бинд плюс alttab.
# Возвращает текст блока и список ожидаемых комбинаций для проверки после reload
def build_block(mod, binds, content, notes, alttab, main):
    name, value = main
    lines = [BEGIN]
    expected = []
    for b in binds:
        key = str(b.get("key", "")).strip()
        cmd = str(b.get("cmd", ""))
        action_var = b.get("var")
        if not KEY_RE.match(key):
            continue
        key = key if key.lower().startswith("mouse:") else key.upper()
        if action_var:
            if not re.match(r"^[A-Za-z_]\w*$", action_var) or not re.search(
                    r"^(?:local\s+)?%s\s*=" % re.escape(action_var), content, re.M):
                notes.append(T["no_var"] % action_var)
                continue
        elif not cmd:
            continue

        if mod == "auto" and name:
            keyexpr = '%s .. " + %s"' % (name, key)
            mask = mask_of(value)
            label = "%s + %s" % (value or name, key)
        else:
            mod_str = value if (mod == "auto" and value) else ("SUPER" if mod == "auto" else mod)
            keyexpr = lua_str("%s + %s" % (mod_str, key))
            mask = mask_of(mod_str)
            label = "%s + %s" % (mod_str, key)
        action = action_var if action_var else lua_str(cmd)
        lines.append("hl.bind(%s, hl.dsp.exec_cmd(%s))" % (keyexpr, action))
        if mask is not None:
            expected.append((mask, key.upper(), False, label))

    if alttab and alttab.get("enabled"):
        at_lines, at_exp = alttab_lines(alttab, notes)
        lines.extend(at_lines)
        expected.extend(at_exp)
    lines.append(END)
    return "\n".join(lines) + "\n", expected


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
    main_mod = detect_main_mod(base, binds_before)
    alttab = cfg.get("alttab") if isinstance(cfg.get("alttab"), dict) else {}
    if cfg.get("enabled") or alttab.get("enabled"):
        binds_in = cfg.get("binds", []) if cfg.get("enabled") else []
        block, expected = build_block(mod, binds_in, base, notes, alttab, main_mod)
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
