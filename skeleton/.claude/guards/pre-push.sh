#!/usr/bin/env sh
# Ярус 3: gate + секрет-скан + полные тесты. Порядок от дешёвого к дорогому.
#
# Логика лежит здесь, а не в `.husky/pre-push`: `.husky` не доставляет ни Copier
# (`_exclude`), ни bootstrap — он копируется руками, и всё, что там написано, работает
# только у того, кто этот шаг сделал. Активация локальная (`.git/hooks/pre-push` ставит
# bootstrap), логика версионируется и едет как CORE.
#
# POSIX sh: git зовёт хук напрямую, bash не гарантирован.

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CONF="${REPO_ROOT}/.harness.conf"
CONF_FOUND=no
# shellcheck source=/dev/null
[ -f "$CONF" ] && { . "$CONF"; CONF_FOUND=yes; }

# 1. Gate: то же, что на Stop (type-check + lint + build), без тестов.
# `</dev/null` обязателен. gate.sh читает stdin до EOF (`HOOK_INPUT="$(cat)"`) — он же
# Stop-хук. Git подаёт pre-push на stdin список ref'ов: без изоляции gate съедает его и
# парсит как JSON, а при ручном прогоне из терминала ждёт EOF и висит.
bash "${REPO_ROOT}/.claude/guards/gate.sh" </dev/null || exit 1

# 2. Секрет-скан. Push — последняя точка, где секрет ещё не ушёл наружу; после него
# ротация ключа обязательна, даже если коммит удалён.
if [ -n "${SECRET_SCAN_CMD:-}" ]; then
  ( cd "$REPO_ROOT" && eval "$SECRET_SCAN_CMD" ) || {
    echo "HARNESS: секрет-скан упал — push остановлен." >&2
    exit 1
  }
elif [ "$CONF_FOUND" = yes ]; then
  # Молчать нельзя: отсутствие скана неотличимо от пройденного скана, а цена ошибки —
  # утёкший ключ. Настроенный харнесс без этой переменной — осознанный выбор, но он
  # должен быть виден.
  echo "HARNESS: SECRET_SCAN_CMD пуст — секреты перед push не проверяются." >&2
fi

# 3. Полные тесты. На Stop их нет: медленно для каждого хода агента, там пофайловый сенсор.
if [ -n "${GATE_TEST_CMD:-}" ]; then
  ( cd "$REPO_ROOT" && eval "$GATE_TEST_CMD" ) || exit 1
elif [ "$CONF_FOUND" = yes ]; then
  # Молчать нельзя по той же причине, что и про секрет-скан: не запускавшиеся тесты
  # неотличимы от прошедших, а следующий шаг ещё и посчитает покрытие по старому отчёту.
  echo "HARNESS: GATE_TEST_CMD пуст — полные тесты перед push не гоняются." >&2
fi

# 4. Покрытие изменённых строк — ПОСЛЕ тестов: отчёт создают они.
# Скрипт сам молчит, если COVERAGE_REPORT не задан или отчёта нет.
if [ -x "${REPO_ROOT}/scripts/check-diff-coverage.sh" ]; then
  bash "${REPO_ROOT}/scripts/check-diff-coverage.sh" --quiet </dev/null || exit 1
elif [ "$CONF_FOUND" = yes ]; then
  # Инстанс подняли до появления скрипта и не перекатывали — покрытие изменённых строк не
  # проверяется. Тихий пропуск тут читался бы как пройденная проверка.
  echo "HARNESS: scripts/check-diff-coverage.sh нет — покрытие изменённых строк не проверено." >&2
fi
