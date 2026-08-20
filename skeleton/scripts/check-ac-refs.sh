#!/usr/bin/env bash
# Сверка «критерий приёмки ↔ тест»: у каждого AC-ID из спеки обязана быть хотя бы одна
# ссылка из теста. Дыра иначе невидима — галочку `[x]` в спеке ставит себе сам автор,
# и покрытие требований остаётся единственной непроверяемой частью работы.
#
# Usage:  bash scripts/check-ac-refs.sh [--quiet]
#   --quiet   только итог и провалы (для вызова из хука)
#
# Ratchet вместо allowlist: порог лежит в файле и двигается ТОЛЬКО вниз. Скрипт краснеет,
# когда несосланных стало больше порога — то есть дыру внёс этот заход. Накопленный долг
# виден отдельной строкой и не блокирует: иначе проверку выключат в первый же день.
#
# Fail-open на своей ненастроенности: нет спек, нет тестов, ноль ID — предупреждение и
# exit 0. Скрипт живёт в общем репозитории и запускается у каждого; проверка, роняющая
# чужую работу на пустом месте, научит команду обходить весь ярус целиком.
#
# Не `set -e`: `grep` без совпадений — ответ, а не ошибка.
# `-f` (noglob): маски идут в find без кавычек, иначе `-o -name X` не разобьётся на токены.
# Без noglob `*.test.ts` схлопывается в имя файла из CWD → find пуст → fail-open.

set -uf

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

# Имя REPO_ROOT, а не своё: .harness.conf у инстансов ссылается на него в путях
# (например AC_TEST_DIR="$REPO_ROOT/src"), и при другом имени source упал бы под set -u.
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "${REPO_ROOT}/.harness.conf" ] && . "${REPO_ROOT}/.harness.conf"

# Формат ID. Дефолт узкий намеренно: широкий (`[A-Z]+-[0-9]+`) поймал бы ADR-13,
# GATE-2 и прочее, и проверка начала бы требовать тесты для номеров решений.
AC_ID_RE="${AC_ID_RE:-AC-[0-9]+}"
AC_SPECS_DIR="${AC_SPECS_DIR:-${REPO_ROOT}/docs/specs}"
AC_TEST_DIR="${AC_TEST_DIR:-${REPO_ROOT}}"
AC_TEST_GLOBS="${AC_TEST_GLOBS:-}"
AC_BASELINE_FILE="${AC_BASELINE_FILE:-${REPO_ROOT}/scripts/check-ac-refs.baseline}"

say()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$1"; }
warn() { printf 'check-ac-refs: %s\n' "$1" >&2; }

# --- Ненастроенность: молчать нельзя, ронять нельзя -------------------------------
if [ -z "$AC_TEST_GLOBS" ]; then
  warn "AC_TEST_GLOBS не задан в .harness.conf — сверка AC↔тест не работает"
  exit 0
fi

if [ ! -d "$AC_SPECS_DIR" ]; then
  warn "нет каталога спек: $AC_SPECS_DIR — проверка пропущена"
  exit 0
fi

# --- ID из спек: ТОЛЬКО чекбоксы секции Verification ------------------------------
# Брать ID из всего файла нельзя: тот же ID упоминают в «Изменениях» и в тексте,
# и тогда проверка считала бы критерием любое упоминание.
# `! -name '_*'` обязателен: docs/specs/_template.md — ШАБЛОН, его примеры (`AC-001`)
# не критерии. Без исключения свежий инстанс краснел бы сразу после разворота, требуя
# тесты для placeholder'ов из шаблона.
SPEC_IDS="$(
  find "$AC_SPECS_DIR" -name '*.md' ! -name '_*' -type f 2>/dev/null | while IFS= read -r f; do
    awk '
      /^## / { inside = ($0 ~ /^## Verification/) ? 1 : 0; next }
      inside && /^[[:space:]]*- \[[ xX]\]/ { print }
    ' "$f"
  done | grep -oE "$AC_ID_RE" | sort -u
)"

N_SPEC="$(printf '%s' "$SPEC_IDS" | grep -c . )"

if [ "$N_SPEC" -eq 0 ]; then
  warn "ни одного ID по шаблону '$AC_ID_RE' в чекбоксах Verification — проверка пропущена"
  exit 0
fi

# --- ID из тестов ----------------------------------------------------------------
# AC_TEST_GLOBS — пробел-разделённый список масок ("*.test.ts *.test.tsx" / "test_*.py").
INCLUDES=""
for g in $AC_TEST_GLOBS; do
  INCLUDES="$INCLUDES --include=$g"
done

# Сначала — есть ли вообще файлы по маскам. Это НЕ то же, что «есть ли ссылки»:
#   файлов нет      → тесты не написаны или маска не та → fail-open, судить не о чем;
#   файлы есть, ссылок нет → покрытия нет ВООБЩЕ, это максимальная дыра, а не
#                            ненастроенность. Второй случай раньше отдавал зелёный.
FIND_EXPR=""
for g in $AC_TEST_GLOBS; do
  FIND_EXPR="$FIND_EXPR -o -name $g"
done
FIND_EXPR="${FIND_EXPR# -o }"

# shellcheck disable=SC2086
N_FILES="$(find "$AC_TEST_DIR" \( $FIND_EXPR \) -type f 2>/dev/null | grep -c . )"

if [ "$N_FILES" -eq 0 ]; then
  warn "по маскам '$AC_TEST_GLOBS' в $AC_TEST_DIR нет ни одного файла — проверка пропущена"
  exit 0
fi

# shellcheck disable=SC2086
TEST_IDS="$(grep -rhoE $INCLUDES "$AC_ID_RE" "$AC_TEST_DIR" 2>/dev/null | sort -u)"
N_TEST="$(printf '%s' "$TEST_IDS" | grep -c . )"

# grep -vxF, а не `comm` с process substitution: `<(...)` — bashism, а скрипт зовут
# и через sh. Каждая строка TEST_IDS здесь отдельный фиксированный паттерн.
# Пустой TEST_IDS обрабатываем отдельно: `grep -vxF ""` матчит ЛЮБУЮ строку, то есть
# отфильтровал бы все ID и выдал ноль несосланных — ложный зелёный там, где покрытия нет.
if [ "$N_TEST" -eq 0 ]; then
  UNREF="$SPEC_IDS"
else
  UNREF="$(printf '%s\n' "$SPEC_IDS" | grep -vxF "$TEST_IDS")"
fi
N_UNREF="$(printf '%s' "$UNREF" | grep -c . )"

# --- Порог -----------------------------------------------------------------------
BASELINE=0
if [ -f "$AC_BASELINE_FILE" ]; then
  BASELINE="$(tr -dc '0-9' < "$AC_BASELINE_FILE")"
  [ -z "$BASELINE" ] && { warn "в файле порога нет числа: $AC_BASELINE_FILE — считаю 0"; BASELINE=0; }
else
  warn "нет файла порога: $AC_BASELINE_FILE — считаю 0"
fi

# --- Ratchet: порог не имеет права расти ------------------------------------------
# Без этой ветки «ratchet двигается только вниз» было объявлением, а не механизмом:
# скрипт сам предлагает поднять порог (строка про «осознанно поднимай»), и поднятая цифра
# делает любую новую дыру законной. Это самый дешёвый способ протащить непокрытый критерий
# мимо всего яруса — дешевле, чем написать тест, и не оставляет следа в выводе проверки.
#
# Сравниваем с HEAD, а не со стейджем: правка порога, ещё не закоммиченная, ловится и на
# Stop (gate), и на push — в обоих случаях интерес один, «выросло ли против последнего коммита».
#
# Границы, названные вслух:
#   • файла нет в HEAD → первичная установка порога. Сравнивать не с чем, поэтому строка,
#     а не блок: осознанность первого значения машине недоступна.
#   • нет git или нет коммитов → проверка пропускается СТРОКОЙ. Молчаливый пропуск
#     неотличим от пройденной проверки.
RATCHET_REL=""
case "$AC_BASELINE_FILE" in
  "${REPO_ROOT}"/*) RATCHET_REL="${AC_BASELINE_FILE#"${REPO_ROOT}"/}" ;;
  *) say "порог лежит вне репозитория — рост порога не сторожится" ;;
esac

if [ -n "$RATCHET_REL" ]; then
  if git -C "$REPO_ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    HEAD_BASELINE="$(git -C "$REPO_ROOT" show "HEAD:${RATCHET_REL}" 2>/dev/null | tr -dc '0-9')"
    if [ -z "$HEAD_BASELINE" ]; then
      say "порога нет в HEAD — первичная установка, ratchet сравнивать не с чем"
    elif [ "$BASELINE" -gt "$HEAD_BASELINE" ]; then
      printf 'ПОРОГ ПОДНЯТ: %s → %s в %s\n' "$HEAD_BASELINE" "$BASELINE" "$RATCHET_REL" >&2
      printf 'Ratchet двигается только вниз. Новая дыра закрывается тестом, а не правкой порога:\n' >&2
      printf 'поднятая цифра делает законными и все будущие дыры до неё.\n' >&2
      printf 'Порог обязан вырасти по причине вне этого захода (сменился формат ID, приехала\n' >&2
      printf 'чужая спека) — верни %s и подними отдельным коммитом с этой причиной.\n' "$HEAD_BASELINE" >&2
      exit 1
    fi
  else
    say "git недоступен или коммитов нет — рост порога не проверен"
  fi
fi

say "AC: $N_SPEC в спеках, $((N_SPEC - N_UNREF)) со ссылкой из теста, $N_UNREF без (порог $BASELINE)"

if [ "$N_UNREF" -gt "$BASELINE" ]; then
  printf 'AC БЕЗ ТЕСТА: %s при пороге %s — дыру внёс этот заход.\n' "$N_UNREF" "$BASELINE" >&2
  printf '%s\n' "$UNREF" | while IFS= read -r id; do
    [ -n "$id" ] && printf '  %s — нет ссылки ни из одного теста\n' "$id" >&2
  done
  printf 'Либо напиши тест и сошлись на ID, либо осознанно поднимай порог в %s.\n' \
    "$AC_BASELINE_FILE" >&2
  exit 1
fi

if [ "$N_UNREF" -lt "$BASELINE" ]; then
  say "порог можно опустить: $BASELINE → $N_UNREF (ratchet двигается только вниз)"
fi

if [ "$N_UNREF" -gt 0 ]; then
  say "накопленный долг ($N_UNREF) в пределах порога — не блокирует:"
  printf '%s\n' "$UNREF" | while IFS= read -r id; do
    [ -n "$id" ] && say "  $id"
  done
fi

exit 0
