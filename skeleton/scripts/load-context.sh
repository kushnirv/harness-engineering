#!/usr/bin/env bash
# SessionStart: активные спеки + долгая память владельца, если вика заведена.
# stdout идёт в контекст агента. SessionStart принимает только command-хуки.
#
# Один файл на оба канала доставки: это имя носили два разных скрипта — версия в skeleton
# и heredoc в bootstrap. Корень через CLAUDE_PROJECT_DIR: `dirname/../..` уводил выше репо,
# конфиг не находился, вика не грузилась, ошибка уходила в невидимый stderr.

set -uo pipefail

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

SPECS="$(ls "$REPO_ROOT"/docs/specs/spec-*.md 2>/dev/null || true)"

if [[ -z "$SPECS" ]]; then
  echo "Спеки среза нет. Первый шаг — копия docs/specs/_template.md → spec-<дата>-<срез>.md."
  echo "Пока нет файла спеки с заполненными AC — код не начинаем."
else
  echo "Активные спеки:"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    OPEN="$(grep -c '^- \[ \]' "$f" 2>/dev/null || true)"
    echo "  $(basename "$f") — незакрытых галок: ${OPEN:-0}"
  done <<< "$SPECS"
fi

CONF="${REPO_ROOT}/.harness.conf"
# shellcheck source=/dev/null
[[ -f "$CONF" ]] && source "$CONF"

# Личный слой вне репо: адрес вики в версионируемом конфиге уехал бы в общий git.
# Домашний каталог, а не `.harness.conf.local` рядом: `git add -A` не захватит то,
# чего в дереве нет, и забытая строка в .gitignore не станет утечкой.
LOCAL_CONF="${HARNESS_LOCAL_CONF:-${HOME}/.harness/$(basename "$REPO_ROOT").conf}"
# shellcheck source=/dev/null
[[ -f "$LOCAL_CONF" ]] && source "$LOCAL_CONF"

# Вики нет — законная конфигурация, слой опциональный.
[[ -z "${WIKI_PATH:-}" ]] && exit 0

# Путь задан, каталога нет — сбой, и молчать нельзя: владелец считает память загруженной.
if [[ ! -d "$WIKI_PATH" ]]; then
  echo ""
  echo "ВНИМАНИЕ: WIKI_PATH ведёт в несуществующий каталог: $WIKI_PATH"
  echo "Долгая память НЕ загружена. Поправь путь в $LOCAL_CONF"
  exit 0
fi

echo ""
echo "=== Долгая память проекта (личный слой, вне репозитория) ==="

if [[ -f "${WIKI_PATH}/overview.md" ]]; then
  echo ""
  echo "--- overview.md ---"
  cat "${WIKI_PATH}/overview.md"
fi

if [[ -f "${WIKI_PATH}/log.md" ]]; then
  echo ""
  echo "--- log.md (последние 30 строк) ---"
  tail -30 "${WIKI_PATH}/log.md"
fi

echo ""
echo "=== Конец памяти ==="
