#!/usr/bin/env bash
# Закрывающая проверка Н1: доки не утверждают того, что перестало быть правдой.
# Прогон из корня harness-template.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

OK=0; FAIL=0
check() { # имя · ожидание · факт
  if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"; OK=$((OK+1))
  else printf 'FAIL   %s — ждали «%s», получили «%s»\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

# Публичные доки — читаются как факт, устаревшее утверждение в них равно лжи.
PUBLIC=(docs/architecture.md docs/decisions.md docs/runbook-copier-rollout-v0.1.7.md
        docs/runbook-delivery-v0.2.0.md docs/specify-implement-review.md README.md CLAUDE.md)
# Рабочий лог — там цитата устаревшей строки законна («было X → стало Y»), поэтому
# цитаты и стрелки отфильтровываются, а голое утверждение всё равно ловится.
LOGS=(docs/plans/TODO.md docs/plans/2026-08-12-harness-master-plan.md)
DOCS=("${PUBLIC[@]}" "${LOGS[@]}")

# 1. Устаревшие утверждения. Каждое было правдой и перестало.
for pat in "Не запушено" "три коммита" "28 тудушек" "dual-tool" "git вне скоупа" "fenris недоступен"; do
  P_HITS="$(grep -rn -- "$pat" "${PUBLIC[@]}" 2>/dev/null || true)"
  L_HITS="$(grep -rn -- "$pat" "${LOGS[@]}" 2>/dev/null \
            | grep -v '«\|→\|снято\|неверно\|была ложной\|разморожен' || true)"
  # ${pat} в скобках обязательно: bash 3.2 на macOS затягивает следующий многобайтный
  # символ в имя переменной → «unbound variable» на определённой переменной.
  check "нет устаревшего: ${pat}" "" "${P_HITS}${L_HITS}"
done

# 2. Числа проверок совпадают с прогоном. Число в доке = обещание, которое можно проверить.
BS="$(bash scripts/verify-bootstrap.sh 2>&1 | grep -c '^  ok ')"
CP="$(bash scripts/verify-copier.sh 2>&1 | grep -c 'ok')"
DOC_BS="$(grep -o 'verify-bootstrap` [0-9]\+ ok' docs/plans/TODO.md | head -1 | grep -o '[0-9]\+' || true)"
DOC_CP="$(grep -o 'verify-copier` [0-9]\+ ok' docs/plans/TODO.md | head -1 | grep -o '[0-9]\+' || true)"
check "verify-bootstrap: док = прогон" "$BS" "$DOC_BS"
check "verify-copier: док = прогон" "$CP" "$DOC_CP"

# 3. Ссылки на файлы внутри репо резолвятся. Битая ссылка = та же ложь, что неверное число.
BROKEN=""
for f in "${DOCS[@]}"; do
  [[ -f "$f" ]] || { BROKEN="${BROKEN}${f}(нет самого дока) "; continue; }
  # markdown-ссылки вида [текст](путь) — только локальные, без http и без якорей
  while IFS= read -r link; do
    [[ -z "$link" ]] && continue
    [[ "$link" == http* || "$link" == \#* ]] && continue
    target="${link%%#*}"
    [[ -z "$target" ]] && continue
    # Ссылка относительна СВОЕМУ доку, а не корню репо: `[план](2026-08-12-...)` внутри
    # docs/plans/ резолвится в docs/plans/2026-08-12-..., иначе проверка даёт ложный красный.
    [[ "$target" == /* ]] || target="$(dirname "$f")/$target"
    [[ -e "$target" ]] || BROKEN="${BROKEN}${f} -> ${target} "
  done < <(grep -o '](\([^)]*\))' "$f" | sed 's/^](//; s/)$//')
done
check "локальные md-ссылки резолвятся" "" "$BROKEN"

# 4. Дерево в architecture.md не упоминает того, чего нет на диске.
MISSING=""
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  find . -name "$name" -not -path './.git/*' -print -quit | grep -q . || MISSING="$MISSING$name "
done < <(grep -o '[a-z0-9_-]\+\.sh' docs/architecture.md | sort -u)
check "все .sh из дерева architecture.md существуют" "" "$MISSING"

# 5. Обратное направление: существующий скрипт назван в дереве.
# Направление «упомянут → существует» (проверка 4) ловит битую ссылку, но НЕ ловит дрейф от
# нового файла: добавил скрипт, в доку не вписал — проверка молчит. Слепую зону нашло
# независимое ревью 13.08 ровно на том заходе, где эта проверка появилась: она сама не
# заметила собственного отсутствия в дереве.
UNLISTED=""
for f in scripts/*.sh scripts/lib/*.sh skeleton/.claude/guards/*.sh skeleton/scripts/*.sh; do
  [[ -e "$f" ]] || continue
  grep -q "$(basename "$f")" docs/architecture.md || UNLISTED="${UNLISTED}${f} "
done
check "каждый скрипт назван в дереве architecture.md" "" "$UNLISTED"

# 6. Открытые чекбоксы TODO живут в одном месте — иначе счёт двоится.
FIRST_OPEN="$(grep -n '^- \[ \]' docs/plans/TODO.md | head -1 | cut -d: -f1)"
SECTION="$(grep -n '^## Остаток' docs/plans/TODO.md | cut -d: -f1)"
if [[ -n "$FIRST_OPEN" && -n "$SECTION" && "$FIRST_OPEN" -gt "$SECTION" ]]; then R=да; else R=нет; fi
check "все открытые чекбоксы в секции «Остаток»" "да" "$R"

printf '\n%s ok / %s FAIL\n' "$OK" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
