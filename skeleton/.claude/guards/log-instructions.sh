#!/usr/bin/env bash
# Логирует, какой файл инструкций загрузился и по какой причине. Существует ради одного
# вопроса: действительно ли `paths:` фильтрует scoped-правила, или файл с глобом молча
# не доезжает до контекста вовсе. Канареечное правило на этот вопрос не отвечает —
# отсутствие следствия одинаково выглядит и при работающей фильтрации, и при мёртвом файле.
#
# Ставится на InstructionsLoaded. Хук информационный: заблокировать загрузку не может,
# код выхода игнорируется. Поэтому в контекст он ничего не печатает — только пишет строку
# в лог, чтобы не создавать шум на каждой загрузке.
#
# Причины загрузки (`load_reason`): session_start · nested_traversal · path_glob_match ·
# include · compact. Для проверки фильтрации важен path_glob_match.
#
# Читать лог: bash scripts/instructions-report.sh
#
# Каталог лога — METRICS_DIR из .harness.conf (дефолт docs/metrics). Пара с
# instructions-report.sh: порознь они бессмысленны, поэтому путь читается из одного места.
set -uo pipefail

# Корень берём от git, а не от `dirname/..`: скрипт лежит в `.claude/guards/`, и подъём
# на один уровень даёт `.claude`, то есть лог уехал бы внутрь каталога с доками. В самом
# хуке `CLAUDE_PROJECT_DIR` задан, но скрипт запускают и руками при проверке.
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || pwd)}"
CONF="${REPO_ROOT}/.harness.conf"
# shellcheck source=/dev/null
[[ -f "$CONF" ]] && . "$CONF"
LOG="${REPO_ROOT}/${METRICS_DIR:-docs/metrics}/instructions-load.log"

INPUT="$(cat 2>/dev/null || true)"
[[ -z "$INPUT" ]] && exit 0

# python3, а не jq: у шаблона python3 уже обязателен (gate.sh, block-large-edit.sh), а jq
# в системе может отсутствовать вовсе — вторая зависимость дала бы молчаливо пустой лог,
# то есть проверку, неотличимую от пройденной.
PARSED="$(HOOK_JSON="$INPUT" python3 -c '
import json, os, sys
try:
    d = json.loads(os.environ.get("HOOK_JSON", ""))
except Exception:
    sys.exit(0)
print(d.get("load_reason", "?"))
print(d.get("file_path", "?"))
' 2>/dev/null || true)"
[[ -z "$PARSED" ]] && exit 0
REASON="$(printf '%s' "$PARSED" | sed -n 1p)"
FILE="$(printf '%s' "$PARSED" | sed -n 2p)"

# Размер берём С ДИСКА, не из payload. Замер на боевом инстансе: колонка, считавшая длину
# `file_content`, во ВСЕХ записях лога давала 0 — поля в payload нет. Декоративная колонка
# хуже отсутствующей: она читается как измеренная величина.
SIZE=0
[[ -f "$FILE" ]] && SIZE="$(wc -c < "$FILE" 2>/dev/null | tr -d " ")"

# Путь пишем относительный: абсолютные в логе мешают сравнивать прогоны на разных машинах.
# Оба пути нормализуем через `pwd -P`, и это не перестраховка: на macOS `/var` — симлинк на
# `/private/var`, поэтому payload приходит с одним префиксом, а `git rev-parse` отдаёт другой.
# Вычитание строк тогда не срабатывает, в лог уходит абсолютный путь, и отчёт объявляет
# ЖИВОЕ правило мёртвым — ложный красный вместо факта. Поймано прогоном 14.08.
ROOT_N="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)"
FILE_DIR="$(cd "$(dirname "$FILE")" 2>/dev/null && pwd -P)" || FILE_DIR=""
if [[ -n "$FILE_DIR" ]]; then
  REL="${FILE_DIR}/$(basename "$FILE")"
  REL="${REL#"${ROOT_N}"/}"
else
  REL="$FILE"
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 0
# Поля разделяет таб, выравнивание не ставим: паддинг протекал бы в значение при чтении.
printf '%s\t%s\t%s\t%s\n' "$(date +%FT%T)" "$REASON" "${SIZE:-0}" "$REL" >>"$LOG"

exit 0
