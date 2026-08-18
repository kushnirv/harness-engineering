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

# --- shellcheck: семантика, которой синтаксический разбор не видит ---
#
# Порог info, а НЕ error. Замер 18.08: на `--severity=error` по репе 4 находки, на `warning`
# добавляются ещё, а SC2086 (неэкранированная переменная) не появляется ни там, ни там — он
# уровня info. То есть прежнее сообщение «кавычки, SC2086 НЕ проверены» обещало то, чего
# настройка не давала и при установленном инструменте: обещание было ложным в обе стороны.
#
# Интерпретатор — по шебангу, как и в синтаксической части выше. `--shell=bash` на POSIX-файле
# разрешает ровно те башизмы, ради отлова которых файл и объявлен POSIX. Сейчас такой файл
# в репе один и находок на нём ноль, то есть дефект пока без симптома — чинится как гигиена.
#
# Гейт по РОСТУ, а не по нулю (ratchet). На info в репе три десятка замечаний; блокировать всё
# сразу — значит не включить проверку никогда. Порог лежит в файле и сверяется с HEAD: поднять
# его молча нельзя, иначе ratchet превращается в разрешение на новый долг (тот же приём, что
# в check-ac-refs.sh).
SC_BASELINE_FILE="${SC_BASELINE_FILE:-${REPO_ROOT}/scripts/lint-shellcheck.baseline}"

if command -v shellcheck >/dev/null 2>&1; then
  SC_FOUND=0
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    case "$(head -1 "$f")" in
      *"env sh"*|*"/sh") SC_SHELL="sh" ;;
      *)                 SC_SHELL="bash" ;;
    esac
    N="$(shellcheck --severity=info --shell="$SC_SHELL" --format=gcc "$f" 2>/dev/null | grep -c .)"
    SC_FOUND=$((SC_FOUND + N))
  done < <(git ls-files '*.sh')

  SC_BASE=0
  if [[ -f "$SC_BASELINE_FILE" ]]; then
    SC_BASE="$(tr -dc '0-9' < "$SC_BASELINE_FILE")"
    [[ -z "$SC_BASE" ]] && { echo "  в файле порога нет числа: $SC_BASELINE_FILE — считаю 0"; SC_BASE=0; }
  else
    echo "  нет файла порога shellcheck: $SC_BASELINE_FILE — считаю 0"
  fi

  # Поднятый порог — это не «стало лучше», это разрешённый долг. Сверяем с HEAD.
  SC_REL="${SC_BASELINE_FILE#"${REPO_ROOT}"/}"
  SC_HEAD="$(git -C "$REPO_ROOT" show "HEAD:${SC_REL}" 2>/dev/null | tr -dc '0-9')"
  if [[ -n "$SC_HEAD" ]] && [[ "$SC_BASE" -gt "$SC_HEAD" ]]; then
    echo "  ПОРОГ ПОДНЯТ: $SC_HEAD → $SC_BASE в $SC_REL — так ratchet не работает"
    FAIL=$((FAIL + 1))
  fi

  if [[ "$SC_FOUND" -gt "$SC_BASE" ]]; then
    echo "  shellcheck: замечаний $SC_FOUND при пороге $SC_BASE — РОСТ, гейт красный"
    echo "  подробности: shellcheck --severity=info --shell=bash --format=gcc <файл>"
    FAIL=$((FAIL + 1))
  elif [[ "$SC_FOUND" -lt "$SC_BASE" ]]; then
    echo "  shellcheck: замечаний $SC_FOUND при пороге $SC_BASE — опусти порог: echo $SC_FOUND > $SC_REL"
  else
    echo "  shellcheck: замечаний $SC_FOUND, порог держится"
  fi
else
  echo "  ДЕГРАДАЦИЯ: shellcheck не установлен — семантика (кавычки SC2086, unused SC2034) НЕ проверена."
  echo "  brew install shellcheck"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "lint-shell: ${TOTAL} ok (bash ${N_BASH} · posix ${N_POSIX})"
  exit 0
fi

echo "lint-shell: провалов ${FAIL} из ${TOTAL}"
exit 1
