#!/usr/bin/env bash
# Guard на два случая, у каждого своя механика:
#
#   Edit  — тул дифает весь файл → на больших файлах висит (наблюдалось 17 мин
#           на 50KB каноне). БЛОКИРУЕТ (exit 2) и редиректит на Bash in-place.
#   Write — крупный md пишется генерацией токенов (кириллица дороже латиницы в 2-4
#           раза) → минуты в главной сессии. ПРЕДУПРЕЖДАЕТ (exit 0 + JSON
#           additionalContext), не блокирует: иногда написать надо именно здесь.
#
# Честная оговорка про Write: PreToolUse срабатывает, когда content уже сгенерирован,
# — время текущей записи не спасти. Предупреждение работает как коррекция на
# следующий раз в этой же сессии. Превентив — измеримый порог в rules/common/workflow.md.
#
# Конфиг (.harness.conf, опц.): LARGE_EDIT_KB — порог блока Edit в КБ (дефолт 40);
# LARGE_WRITE_LINES / LARGE_WRITE_KB — пороги предупреждения Write (дефолт 60 / 6).

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CONF="${REPO_ROOT}/.harness.conf"
[[ -f "$CONF" ]] && source "$CONF"

LARGE_EDIT_KB="${LARGE_EDIT_KB:-40}"
THRESHOLD=$(( LARGE_EDIT_KB * 1024 ))
LARGE_WRITE_LINES="${LARGE_WRITE_LINES:-60}"
LARGE_WRITE_KB="${LARGE_WRITE_KB:-6}"

# JSON пишем в fd 3 (см. ниже), stdout скрипта уводим в stderr: посторонний вывод
# (например echo, добавленный в .harness.conf) иначе встанет перед JSON и сломает разбор.
exec 3>&1 1>&2

export HOOK_INPUT
HOOK_INPUT="$(cat || true)"
# НЕ `${HOOK_INPUT// }`: подстановка по шаблону в bash 3.2 (дефолт macOS) суперквадратична
# по длине строки. Пока хук висел только на Edit, это было незаметно; с matcher `Edit|Write`
# через неё пошло всё содержимое записываемого файла — 24KB payload = 40 с, 48KB = >3 мин,
# то есть хук упирался в таймаут и ОТМЕНЯЛ запись. Ровно то, что guard должен был ускорять.
[[ "$HOOK_INPUT" =~ ^[[:space:]]*$ ]] && exit 0

TOOL="$(python3 -c "
import json, os
try:
    print(json.loads(os.environ.get('HOOK_INPUT','')).get('tool_name',''))
except Exception:
    print('')
")"

# --- Ветка Write: предупреждение по объёму СОДЕРЖИМОГО, не файла на диске ---
# (при Write файла ещё может не быть — мерить нечего, кроме параметров тула).
# Порог только на текстовые доки (`.md`, `.txt`): файл кода на пару сотен строк — обычное дело,
# предупреждать там значит шуметь. Расширение проверяется в python-ветке ниже.
if [[ "$TOOL" == "Write" ]]; then
  export LARGE_WRITE_LINES LARGE_WRITE_KB
  # Guard-предупреждение обязано быть fail-open: любая неожиданная форма входа или
  # кривое значение в .harness.conf не должны ронять хук — молча пропускаем.
  python3 <<'PY' >&3
import json, os, sys

try:
    data = json.loads(os.environ.get("HOOK_INPUT", ""))

    ti = data.get("tool_input")
    if not isinstance(ti, dict):
        sys.exit(0)
    path = ti.get("file_path") or ""
    content = ti.get("content")
    if not isinstance(content, str) or not path.lower().endswith((".md", ".txt")):
        sys.exit(0)

    max_lines = int(os.environ.get("LARGE_WRITE_LINES", "60"))
    max_kb = int(os.environ.get("LARGE_WRITE_KB", "6"))

    lines = content.count("\n") + 1
    size = len(content.encode("utf-8"))
    if lines <= max_lines and size <= max_kb * 1024:
        sys.exit(0)

    warn = (
        f"Крупный Write: {os.path.basename(path)} — {lines} строк / {size // 1024}KB "
        f"(порог {max_lines} строк / {max_kb}KB). Содержимое дока — генерируемые токены, "
        "на русском они в 2-4 раза дороже латиницы: такая запись стоит минут. Этот раз "
        "уже сгенерирован, не переделывай. Дальше: объёмный док из главной сессии — "
        "агенту `scribe`, дописывание секций — append через Bash, а не перезапись Write. "
        "(Если ты сам `scribe` — это твоя работа, продолжай.)"
    )
    # permissionDecision намеренно НЕ ставим: "allow" снимает интерактивное подтверждение,
    # то есть крупная запись спрашивалась бы МЕНЬШЕ мелкой. Нужен только контекст модели.
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": warn,
        }
    }, ensure_ascii=False))
except SystemExit:
    raise
except Exception:
    sys.exit(0)
PY
  exit 0
fi

# --- Ветка Edit: блок по размеру файла на диске ---
[[ "$TOOL" != "Edit" ]] && exit 0

TARGET_FILE="$(python3 <<'PY'
import json, os
raw = os.environ.get("HOOK_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    print(""); raise SystemExit

def walk(obj, acc):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in ("file_path", "filePath", "path") and isinstance(v, str):
                acc.append(v)
            walk(v, acc)
    elif isinstance(obj, list):
        for v in obj:
            walk(v, acc)

paths = []
walk(data, paths)
print(paths[0] if paths else "")
PY
)"

[[ -z "$TARGET_FILE" || ! -f "$TARGET_FILE" ]] && exit 0

SIZE=$(wc -c < "$TARGET_FILE" 2>/dev/null || echo 0)
if (( SIZE > THRESHOLD )); then
  KB=$(( SIZE / 1024 ))
  echo "GUARD BLOCKED: '${TARGET_FILE}' — ${KB}KB (> ${LARGE_EDIT_KB}KB)." >&2
  echo "Edit-тул дифает весь файл и висит (17 мин на 50KB). Правь через Bash in-place:" >&2
  echo "  python3 - <<'PY'  (читаешь файл, .replace(old,new), пишешь обратно)" >&2
  echo "или append-скриптом для логов. Не Edit-тулом на файлах такого размера." >&2
  exit 2
fi

exit 0
