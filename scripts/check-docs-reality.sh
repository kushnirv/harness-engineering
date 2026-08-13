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
for pat in "Не запушено" "три коммита" "28 тудушек" "dual-tool" "git вне скоупа" \
           "fenris недоступен" "едут ровно три"; do
  P_HITS="$(grep -rn -- "$pat" "${PUBLIC[@]}" 2>/dev/null || true)"
  L_HITS="$(grep -rn -- "$pat" "${LOGS[@]}" 2>/dev/null \
            | grep -v '«\|→\|снято\|неверно\|была ложной\|разморожен' || true)"
  # ${pat} в скобках обязательно: bash 3.2 на macOS затягивает следующий многобайтный
  # символ в имя переменной → «unbound variable» на определённой переменной.
  check "нет устаревшего: ${pat}" "" "${P_HITS}${L_HITS}"
done

# 2. Числа проверок совпадают с прогоном. Число в доке = обещание, которое можно проверить.
BS="$(bash scripts/verify-bootstrap.sh 2>&1 | grep -c '^  ok ')"
# Якорь `^  ok ` обязателен: `grep -c ok` считал ЛЮБУЮ строку с этими буквами, а verify-copier
# печатает путь случайного temp-каталога — стоило `ok` попасть в `tmp.XXXX`, и число прыгало
# с 7 на 8. Проверка чисел сама давала случайный красный (поймано мутацией 13.08).
CP="$(bash scripts/verify-copier.sh 2>&1 | grep -c '^  ok ')"
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

# 6. Перечисление шагов Яруса 3 нигде не короче самого яруса. Дрейф ловится вторым местом:
# диаграмма обновлена, а вторая копия списка — нет. Так и вскрылось на README 13.08: там Ярус 3
# остался четырёхшаговым после того, как сверка AC стала пятым шагом.
SHORT=""
while IFS=: read -r file ln _; do
  [[ -z "${file:-}" ]] && continue
  CTX="$(sed -n "${ln},$((ln + 2))p" "$file")"
  printf '%s' "$CTX" | grep -q 'AC' || SHORT="${SHORT}${file}:${ln} "
done < <(grep -rn 'секрет-скан' "${PUBLIC[@]}" 2>/dev/null || true)
check "перечисления Яруса 3 называют сверку AC" "" "$SHORT"

# 7. Назвал четыре яруса — скажи, что нулевой шаблон не ставит. Ярус 0 (pre-commit) заводит
# проект: линтер у каждого стека свой, bootstrap ставит только git-хук pre-push. Запрещать само
# число нельзя — как модель ярусов четыре, и оглавление вправе их перечислить. Ловится другое:
# перечисление БЕЗ оговорки, потому что оно читается как «четыре хука из коробки» (так и было
# в шапке README до 13.08).
TIER0=""
for f in "${PUBLIC[@]}"; do
  [[ -f "$f" ]] || continue
  grep -q 'четырёх ярусах\|четыре яруса' "$f" || continue
  grep -q 'Ярус 0.*\(не ставит\|заводит проект\)\|pre-commit.*\(не ставит\|заводит проект\)' "$f" \
    || TIER0="${TIER0}${f} "
done
check "документ с четырьмя ярусами оговаривает, что Ярус 0 не поставляется" "" "$TIER0"

# 8. У каждого дока из цикла доставки есть шаблон. Список рос (3 → 8), и всякая его копия в тексте
# устаревала молча; сверять надо цикл с диском, а не доку с памятью.
NODOC=""
DOC_LINE="$(grep -o 'for DOC in [A-Za-z0-9 _-]*' scripts/bootstrap.sh | head -1 | sed 's/for DOC in //')"
# Пустой разбор — провал, а не пропуск: цикл переписали, проверка перестала что-либо сверять и
# продолжила печатать `ok`. Это ровно тот false green, за которым весь этот скрипт и написан.
if [[ -z "$DOC_LINE" ]]; then
  check "цикл доставки доков найден в bootstrap.sh" "найден" "не найден"
else
  for d in $DOC_LINE; do
    [[ -f "skeleton/.claude/docs/${d}.md.template" ]] || NODOC="${NODOC}${d} "
  done
  check "у каждого дока из цикла bootstrap есть шаблон" "" "$NODOC"
fi

# 9. Открытые чекбоксы TODO живут в одном месте — иначе счёт двоится.
FIRST_OPEN="$(grep -n '^- \[ \]' docs/plans/TODO.md | head -1 | cut -d: -f1)"
SECTION="$(grep -n '^## Остаток' docs/plans/TODO.md | cut -d: -f1)"
# Ни одного открытого чекбокса — утверждение «все они в секции» верно на пустом множестве.
# Первая версия считала это провалом и дала ложный красный ровно на том заходе, где остаток
# закрылся: проверка наказывала за доделанную работу.
NOTE=""
if [[ -z "$FIRST_OPEN" ]]; then R=да; NOTE="открытых чекбоксов в TODO нет"
elif [[ -n "$SECTION" && "$FIRST_OPEN" -gt "$SECTION" ]]; then R=да
else R=нет; fi
check "все открытые чекбоксы в секции «Остаток»" "да" "$R"
[[ -n "$NOTE" ]] && printf '       %s\n' "$NOTE"

# 10. Ссылки ВНУТРИ skeleton на `.claude/docs/*.md`: либо док доставляется циклом bootstrap, либо
# ссылка помечена условной («приезжает с lang-pack», «если есть»). Проверка 3 сюда не доставала —
# она ходит по докам репозитория, а не по тому, что едет потребителю. Это ровно тот дефект,
# который закрывал коммит `8a5677a` (CORE ссылался на девять несуществующих файлов) и который
# после него ничем не охранялся. Окно — строка и следующая: оговорка часто на переносе.
DANGLING=""
DELIVERED2="$(grep -o 'for DOC in [A-Za-z0-9 _-]*' scripts/bootstrap.sh | head -1 | sed 's/for DOC in //')"
while IFS= read -r hit; do
  [[ -z "$hit" ]] && continue
  loc="${hit%%:*}"; rest="${hit#*:}"; lnum="${rest%%:*}"
  [[ "$lnum" =~ ^[0-9]+$ ]] || continue
  CTX="$(sed -n "${lnum},$((lnum + 1))p" "$loc" 2>/dev/null)"
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    name="$(basename "$ref" .md)"
    case " $DELIVERED2 " in *" $name "*) continue ;; esac
    printf '%s' "$CTX" | grep -q 'lang-pack\|если\|оттуда же' \
      || DANGLING="${DANGLING}${loc}:${lnum}(${name}) "
  done < <(printf '%s' "${hit#*:*:}" | grep -o '\.claude/docs/[A-Za-z0-9_-]\+\.md' | sort -u)
done < <(grep -rn '\.claude/docs/[A-Za-z0-9_-]\+\.md' skeleton/.claude/rules skeleton/.claude/skills \
           skeleton/.claude/docs skeleton/CLAUDE.md.template 2>/dev/null || true)
check "ссылки skeleton на доки: доставляется или помечена условной" "" "$DANGLING"

# N. Собственное число этого скрипта в доке. Числа verify-* сверяются прогоном (проверка 2), а
# своё сидело в TODO непроверенным — единственное число в доках, за которым ничего не стояло.
#
# Сверяем ЧИСЛО ПРОВЕРОК (`OK+FAIL+1`), не число зелёных. Первая версия брала `OK+1` — и любой
# одиночный настоящий дефект давал ВТОРОЙ, ложный FAIL: «ждали 16, получили 17», хотя 17 в доке
# верно. Читатель шёл править верное число (нашло независимое ревью 13.08). Число проверок от
# результатов не зависит, поэтому красное остаётся ровно одно — то, которое настоящее.
DOC_DR="$(grep -o 'check-docs-reality` [0-9]\+ проверок' docs/plans/TODO.md | head -1 | grep -o '[0-9]\+' || true)"
check "check-docs-reality: число проверок в доке = факту" "$((OK + FAIL + 1))" "$DOC_DR"

printf '\n%s ok / %s FAIL\n' "$OK" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
