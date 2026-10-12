# atomic_write.py
#
# Общая атомарная запись файла для питоновских скриптов шелла
# (launchers/colors.py и settings/qsbinds.py): так правим в одном месте.
#
# Подключение (скрипты лежат в соседних папках, поэтому добавляем common в sys.path):
#   sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "common"))
#   from atomic_write import atomic_write
import os
import shutil
import tempfile


# Пишет файл атомарно: сначала во временный, потом подменяет целиком.
# Так читатели (FileView в QML) никогда не увидят половину файла.
# Симлинки раскрываются до записи: если файл - ссылка (stow, dotfiles-репозиторий),
# пишем в настоящий файл, а сама ссылка остаётся на месте.
def atomic_write(path, text):
    path = os.path.realpath(path)          # идём по симлинку к настоящему файлу
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp_")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        if os.path.exists(path):
            shutil.copymode(path, tmp)     # сохраняем права оригинала
        else:
            os.chmod(tmp, 0o644)           # mkstemp даёт 0600, для нового файла не годится
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
