#!/usr/bin/env bash
# Синтаксис всех shell-скриптов репозитория. Ярус 3, шаг 1 — самый дешёвый.
#
# Зачем: шаблон поставляет потребителю больше десятка `.sh` (шесть guard-хуков плюс CORE-скрипты),
# и ни одна из четырёх остальных проверок в них не заглядывает. Синтаксическая ошибка в
# `gate.sh` вскрывалась бы на чужом инстансе, в момент, когда хук молча не сработал.
#
# Проверяльщик выбирается по ШЕБАНГУ, а не один для всех: `dash -n` на bash-файле упал бы на
# `[[ ]]` и выдал ложный красный, а bash в sh-режиме на macOS — это bash 3.2, он проглотит
# башизмы, которые в CI под Linux уронят файл. Проверка не тем интерпретатором, которым файл
# запустится, бесполезна в обе стороны.
#
# `-n` читает синтаксис и НЕ исполняет. Это важно: часть файлов — хуки, которые при исполнении
# полезли бы в git и в конфиг проекта.
#
# ГРАНИЦА, замер 14.08 на пяти мутациях в POSIX-файле. `dash -n` ловит: массив `a=(x y)`,
# here-string `<<<`, `function f() {}`. НЕ ловит: `[[ ]]`, `(( ))`, `${VAR^^}` — для dash это
# синтаксически валидно (`[[` разбирается как имя команды), отказ был бы в рантайме, а `-n`
# до рантайма не доходит. То есть проверка отсекает часть башизмов, а не все, и обещать
# «POSIX-совместимость доказана» она не может.
#
# Полностью этот класс закрывает только shellcheck (он различает `--shell=sh` и `--shell=bash`
# семантически). На машине его может не быть, поэтому он необязателен — но его отсутствие
# печатается строкой: молчаливо пропущенная проверка неотличима от пройденной.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

FAIL=0
N_BASH=0
N_POSIX=0
N_OTHER=0

while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  SHEBANG="$(head -1 "$f")"
  case "$SHEBANG" in
    *"env bash"*|*"/bash")
      N_BASH=$((N_BASH + 1))
      bash -n "$f" || { echo "  СИНТАКСИС (bash): $f"; FAIL=$((FAIL + 1)); }
      ;;
    *"env sh"*|*"/sh")
      N_POSIX=$((N_POSIX + 1))
      # POSIX-файл проверяем dash'ем: на macOS /bin/sh — это bash 3.2 в sh-режиме, он
      # проглотит массивы и `[[ ]]`, а в CI под Linux /bin/sh это dash, и файл упадёт там.
      if [[ -x /bin/dash ]]; then
        /bin/dash -n "$f" || { echo "  СИНТАКСИС (dash): $f"; FAIL=$((FAIL + 1)); }
      else
        echo "  ДЕГРАДАЦИЯ: dash нет, $f проверен /bin/sh — башизм тут не поймается"
        /bin/sh -n "$f" || { echo "  СИНТАКСИС (sh): $f"; FAIL=$((FAIL + 1)); }
      fi
      ;;
    *)
      N_OTHER=$((N_OTHER + 1))
      echo "  БЕЗ ШЕБАНГА или чужой интерпретатор: $f ($SHEBANG)"
      FAIL=$((FAIL + 1))
      ;;
  esac
done < <(git ls-files '*.sh')

TOTAL=$((N_BASH + N_POSIX + N_OTHER))

# Вакуумный пропуск: ноль файлов на входе — это сломанный перебор, а не чистая репа.
# Без этой ветки скрипт отчитался бы зелёным, ничего не проверив.
if [[ "$TOTAL" -eq 0 ]]; then
  echo "ПРОВАЛ: не найдено ни одного .sh — перебор сломан (git ls-files пуст?)"
  exit 1
fi

if command -v shellcheck >/dev/null 2>&1; then
  SC_FAIL=0
  while IFS= read -r f; do
    shellcheck --severity=error --shell=bash "$f" || SC_FAIL=$((SC_FAIL + 1))
  done < <(git ls-files '*.sh')
  if [[ "$SC_FAIL" -gt 0 ]]; then
    echo "  shellcheck: ошибок в $SC_FAIL файлах"
    FAIL=$((FAIL + SC_FAIL))
  fi
else
  echo "  shellcheck не установлен — семантика (кавычки, SC2086) НЕ проверена. brew install shellcheck"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "lint-shell: ${TOTAL} ok (bash ${N_BASH} · posix ${N_POSIX})"
  exit 0
fi

echo "lint-shell: провалов ${FAIL} из ${TOTAL}"
exit 1
