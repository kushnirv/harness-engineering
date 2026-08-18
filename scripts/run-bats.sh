#!/usr/bin/env bash
# Ярус 3, поведенческий слой: тесты shell-скриптов через bats.
#
# Зачем отдельно от lint-shell.sh: тот читает текст (синтаксис + shellcheck), а этот ЗАПУСКАЕТ.
# Скрипт может быть безупречен по тексту и делать не то — статика этого не видит.
#
# Вакуумный пропуск закрыт: ноль найденных .bats это сломанный перебор, а не «тестов не нужно».
# Без этой ветки шаг отчитался бы зелёным, ничего не выполнив — тот же класс, против которого
# написана проверка числа проверок в check-docs-reality.sh.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

if ! command -v bats >/dev/null 2>&1; then
  printf 'ДЕГРАДАЦИЯ: bats не установлен — поведение скриптов НЕ проверено.\n'
  printf '  brew install bats-core\n'
  exit 3
fi

FILES="$(git ls-files 'tests/*.bats' | tr '\n' ' ')"
if [ -z "${FILES// /}" ]; then
  # Файлы могут быть ещё не добавлены в индекс — смотрим и на диск, иначе новый тест
  # не выполнится, а шаг отчитается зелёным.
  FILES="$(find tests -name '*.bats' -type f 2>/dev/null | tr '\n' ' ')"
fi

if [ -z "${FILES// /}" ]; then
  printf 'ПРОВАЛ: не найдено ни одного .bats — перебор сломан или тесты не написаны\n'
  exit 1
fi

# shellcheck disable=SC2086
bats $FILES
