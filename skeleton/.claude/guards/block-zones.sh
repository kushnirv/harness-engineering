#!/usr/bin/env bash
# Guard: блокирует запись в READONLY_ZONES.
# PreToolUse(Edit/Write/Bash) — Claude Code.
# exit 2 → блокирует в обоих контекстах.
#
# Конфиг (.harness.conf):
#   READONLY_ZONES — пробел-разделённый список (напр. "dist storybook-static")

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CONF="${REPO_ROOT}/.harness.conf"
[[ -f "$CONF" ]] && source "$CONF"

READONLY_ZONES="${READONLY_ZONES:-dist}"

export HOOK_INPUT
HOOK_INPUT="$(cat || true)"

[[ "$HOOK_INPUT" =~ ^[[:space:]]*$ ]] && exit 0

# Recursive walk: ищем file_path в любом месте JSON
TARGET_FILE="$(python3 <<'PY'
import json, os

raw = os.environ.get("HOOK_INPUT", "")
if not raw.strip():
    print(""); raise SystemExit

try:
    data = json.loads(raw)
except (json.JSONDecodeError, TypeError):
    print(""); raise SystemExit

def walk(obj, acc):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in ("file_path", "filePath", "path", "target_file") and isinstance(v, str):
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

# Bash tool: читаем command и grep на READONLY_ZONES
if [[ -z "$TARGET_FILE" ]]; then
  BASH_CMD="$(python3 -c "
import json, os
raw = os.environ.get('HOOK_INPUT', '')
try:
    data = json.loads(raw)
    print(data.get('tool_input', {}).get('command', ''))
except:
    print('')
")"
  for zone in $READONLY_ZONES; do
    zone="${zone#/}"; zone="${zone%/}"          # снять обрамляющие слеши: "dist/" → "dist"
    [[ -z "$zone" ]] && continue                # пустая зона после нормализации → пропустить
    # §6: эвристика на grep, а не разбор шелла. Отличить реальную закавыченную запись
    # (`cp a "dist"/b` — bash склеит в dist/b) от простого упоминания имени в строке
    # (`echo "x > dist/y" >> log`) без токенизации нельзя, поэтому УПОМИНАНИЕ ТОЖЕ
    # БЛОКИРУЕТСЯ. Выбор осознанный: попытка вырезать кавычки до матча снимала ложный
    # блок и открывала обход — на security-гварде пере-блок лучше тихой дыры.
    # zone-как-путь: опц. путь-префикс + zone + граница токена
    ZONE_PATH="([^[:space:]\"';|&]*/)?${zone}(/|[[:space:]]|\"|'|;|&|\||\$)"

    # 1) redirect (> >> 2> &>) или tee с целью в зоне
    # 2) команды записи (cp/mv/rm/rmdir/mkdir/touch) с путём в зоне
    if echo "$BASH_CMD" | grep -qE ">>?[[:space:]]*(\"|')?${ZONE_PATH}" \
       || echo "$BASH_CMD" | grep -qE "(^|[[:space:]|])tee([[:space:]]+-[a-zA-Z]+)*[[:space:]]+(\"|')?${ZONE_PATH}" \
       || echo "$BASH_CMD" | grep -qE "(^|[[:space:]|;&])(cp|mv|rm|rmdir|mkdir|touch)([[:space:]]+(-{1,2}[a-zA-Z-]+))*[[:space:]]+([^|;&]*[[:space:]])?(\"|')?${ZONE_PATH}"; then
      echo "GUARD BLOCKED: Bash command writes into '${zone}/' (read-only zone)." >&2
      echo "Use the build command instead of writing directly." >&2
      exit 2
    fi
  done
  exit 0
fi

for zone in $READONLY_ZONES; do
  zone="${zone#/}"; zone="${zone%/}"            # снять обрамляющие слеши: "dist/" → "dist"
  [[ -z "$zone" ]] && continue                  # пустая зона после нормализации → пропустить
  # Матчим zone как ПОЛНЫЙ сегмент пути: обёртка /…/ + */zone/* ловит и top-level
  # (dist/x), и вложенный (monorepo packages/<пакет>/dist/x), и саму папку (dist).
  # Сегмент целиком, не префикс → НЕ ловит соседа distribution/. Работает для
  # абсолютного и относительного TARGET_FILE (обёртка нормализует границы).
  case "/${TARGET_FILE}/" in
    */"${zone}"/*)
      echo "GUARD BLOCKED: '${zone}/' is a read-only zone (generated files)." >&2
      echo "Use the build command instead of writing directly." >&2
      exit 2
      ;;
  esac
done

exit 0
