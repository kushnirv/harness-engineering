#!/usr/bin/env bash
# Линт чистоты CORE: правило, которое едет ВСЕМ, не должно опираться на один стек.
#
# Usage:  bash scripts/lint-core-purity.sh [--quiet]
#   --quiet   только итог и провал (для вызова из другого скрипта)
#
# Что помечает:
#   1. стек-токен из scripts/core-denylist.txt в тексте CORE-правила;
#   2. висячую ссылку `Gotcha N` — в CORE реестра нет, у свежего инстанса она не резолвится
#      ни во что: место под обоснование занято, обоснования нет;
#   3. голую дату (`29.07`, `2026-07-29`) без указания, что именно она доказывает.
#
# Порог ratchet в scripts/lint-core-purity.baseline, двигается ТОЛЬКО вниз. Причина та же,
# что у остальных проверок репозитория: гейт, краснеющий на накопленном долге, выключают
# в первый день. Красный означает «долг вырос на этом заходе».
#
# Escape-hatch: `<!-- core-ok: причина -->` в строке или в предыдущей. Пустая причина не
# принимается — иначе метка становится способом не думать.
#
# Не `set -e`: grep без совпадений — ответ, а не ошибка.
# И НЕ `set -f`, в отличие от check-ac-refs.sh: там маски идут в `find` без кавычек и glob
# надо гасить, а здесь наоборот — `CORE_GLOBS` обязан раскрыться в список файлов. Токены
# денилиста передаются в `grep -F` в кавычках, гасить для них нечего.

set -u

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
DENYLIST="${CORE_DENYLIST:-${REPO_ROOT}/scripts/core-denylist.txt}"
BASELINE_FILE="${CORE_PURITY_BASELINE:-${REPO_ROOT}/scripts/lint-core-purity.baseline}"

# Что считается CORE-текстом. Скрипты и JSON не берём: там стек-токен законен по природе
# (`npm ci` внутри guard'а — это команда, а не правило для агента).
CORE_GLOBS="${CORE_PURITY_GLOBS:-${REPO_ROOT}/skeleton/.claude/rules/common/*.md ${REPO_ROOT}/skeleton/.claude/skills/*/SKILL.md}"

say()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$1"; }
warn() { printf 'lint-core-purity: %s\n' "$1" >&2; }

if [ ! -f "$DENYLIST" ]; then
  warn "нет файла денилиста: $DENYLIST — судить не по чему, проверка пропущена"
  exit 0
fi

# shellcheck disable=SC2086
FILES="$(ls -1 $CORE_GLOBS 2>/dev/null)"
if [ -z "$FILES" ]; then
  warn "по маскам '$CORE_GLOBS' нет ни одного файла — проверка пропущена"
  exit 0
fi

TOKENS="$(grep -v '^[[:space:]]*#' "$DENYLIST" | grep -v '^[[:space:]]*$')"
if [ -z "$TOKENS" ]; then
  warn "денилист пуст (только комментарии) — проверка пропущена"
  exit 0
fi

HITS_FILE="$(mktemp)"
trap 'rm -f "$HITS_FILE"' EXIT

# Помеченная строка = файл:номер:причина. Считаем СТРОКИ, а не совпадения: два токена в
# одной строке — одна единица работы, иначе счётчик зависит от плотности слов.
for f in $FILES; do
  base="$(basename "$f")"

  # 1. Стек-токены.
  printf '%s\n' "$TOKENS" | while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    grep -inF -- "$tok" "$f" 2>/dev/null | while IFS=: read -r ln rest; do
      printf '%s\t%s\t%s\t%s\n' "$base" "$ln" "стек-токен: $tok" "$rest"
    done
  done

  # 2. Висячие ссылки на реестр ловушек и 3. голые даты.
  grep -inE 'Gotcha [0-9]+' "$f" 2>/dev/null | while IFS=: read -r ln rest; do
    printf '%s\t%s\t%s\t%s\n' "$base" "$ln" "висячая ссылка Gotcha" "$rest"
  done
  grep -inE '(^|[^0-9])[0-3][0-9]\.[01][0-9]([^0-9]|$)|20[0-9]{2}-[01][0-9]-[0-3][0-9]' "$f" 2>/dev/null \
    | while IFS=: read -r ln rest; do
      printf '%s\t%s\t%s\t%s\n' "$base" "$ln" "голая дата" "$rest"
    done
done > "$HITS_FILE"

# Escape-hatch: строка с `core-ok: причина` либо строка НАД ней с такой же меткой.
# Метка без причины не считается — `core-ok:` с пустым хвостом остаётся помеченным.
FILTERED="$(mktemp)"
trap 'rm -f "$HITS_FILE" "$FILTERED"' EXIT
while IFS="$(printf '\t')" read -r base ln reason text; do
  [ -z "${base:-}" ] && continue
  full=""
  for f in $FILES; do
    [ "$(basename "$f")" = "$base" ] && full="$f" && break
  done
  [ -z "$full" ] && continue
  own="$(sed -n "${ln}p" "$full" 2>/dev/null)"
  prev=""
  [ "$ln" -gt 1 ] && prev="$(sed -n "$((ln - 1))p" "$full" 2>/dev/null)"
  # Регекс, а не glob-`case`: нужно «после core-ok: идёт хотя бы один значащий символ», а
  # glob такого не выражает — `[!-[:space:]]*` матчит и пустой хвост, и метка без причины
  # проходила (поймано мутацией). `>` и `-` исключены, иначе закрывающий `-->` читается
  # как причина.
  if printf '%s\n%s\n' "$own" "$prev" | grep -qE 'core-ok:[[:space:]]*[^[:space:]>-]'; then
    continue
  fi
  printf '%s\t%s\t%s\t%s\n' "$base" "$ln" "$reason" "$text"
done < "$HITS_FILE" > "$FILTERED"

# Уникальные СТРОКИ (файл + номер), не совпадения.
N="$(cut -f1,2 "$FILTERED" | sort -u | grep -c . )"

BASELINE=0
if [ -f "$BASELINE_FILE" ]; then
  BASELINE="$(tr -dc '0-9' < "$BASELINE_FILE")"
  [ -z "$BASELINE" ] && { warn "в файле порога нет числа: $BASELINE_FILE — считаю 0"; BASELINE=0; }
else
  warn "нет файла порога: $BASELINE_FILE — считаю 0"
fi

say "CORE-чистота: $N помеченных строк при пороге $BASELINE"

if [ "$QUIET" -eq 0 ] && [ "$N" -gt 0 ]; then
  say ""
  say "Разбивка по файлам:"
  cut -f1,2 "$FILTERED" | sort -u | cut -f1 | sort | uniq -c | while read -r cnt file; do
    say "  $file — $cnt"
  done
  say ""
  say "Строки (первые 40):"
  sort -u "$FILTERED" | head -40 | while IFS="$(printf '\t')" read -r base ln reason text; do
    say "  $base:$ln — $reason"
    say "      ${text}"
  done
fi

if [ "$N" -gt "$BASELINE" ]; then
  printf 'CORE-ЧИСТОТА: %s помеченных строк при пороге %s — долг вырос на этом заходе.\n' \
    "$N" "$BASELINE" >&2
  printf 'Либо переформулируй нейтрально, либо унеси в rules/lang/<lang>.md, либо поставь\n' >&2
  printf '<!-- core-ok: причина --> с настоящей причиной. Порог поднимать нельзя: ratchet вниз.\n' >&2
  exit 1
fi

if [ "$N" -lt "$BASELINE" ]; then
  say "порог можно опустить: $BASELINE → $N (ratchet двигается только вниз)"
fi

exit 0
