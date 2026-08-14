#!/usr/bin/env bash
# Раскладывает реестр ловушек по файлам согласно scripts/gotchas-partition.map.
# Записи, которых в карте нет, уезжают в архив: архив ищется грепом, в JIT-таблицу
# не входит и потому не тратит контекст агента.
#
# Usage:  scripts/gotchas-partition.sh [--dry-run]
#   --dry-run   посчитать и показать раскладку, ничего не записывать
#
# Почему скриптом, а не руками: единственная реальная опасность здесь — молча потерять
# запись при нарезке. Скрипт сверяет множество ID до и после и при расхождении не
# перезаписывает ничего. Проверять надо разделитель, а не его вывод.
#
# Почему не `set -e`: `grep` без совпадений — ответ, а не ошибка.
set -uo pipefail

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONF="${REPO_ROOT}/.harness.conf"
# shellcheck source=/dev/null
[[ -f "$CONF" ]] && . "$CONF"

DOCS="${REPO_ROOT}/.claude/docs"
MAP="${REPO_ROOT}/scripts/gotchas-partition.map"
ARCHIVE_NAME="${GOTCHA_ARCHIVE_NAME:-gotchas-archive.md}"

# Префикс заголовка записи. Дефолт — формат шаблонного реестра (`## §7 — правило`).
# Проект, нумерующий иначе (`## Gotcha 7:`), задаёт свой в .harness.conf.
# Это НЕ косметика: замер на боевом инстансе — форматы двух реестров различались, и скрипт
# с зашитым чужим префиксом не распознал бы ни одной записи, то есть увёл БЫ ВЕСЬ реестр
# в архив, отчитавшись «множества ID совпали» (совпали бы: оба пустые).
GOTCHA_ID_PREFIX="${GOTCHA_ID_PREFIX:-## §}"

# Экранируем префикс для grep -E: значение приходит из конфига, там может быть точка или скобка.
PREFIX_RE="$(printf '%s' "$GOTCHA_ID_PREFIX" | sed 's/[][\.*^$(){}?+|]/\\&/g')"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

# Карты нет — создаём дефолтную и продолжаем. Раньше здесь стоял отказ, и это была дыра
# доставки, а не защита: карта лежит в скелете как `.map.template`, а Copier режет всё по маске
# `*.template`, то есть в инстансе, обновлённом через `copier update`, карты не появлялось НИКОГДА
# и скрипт падал при первом запуске. Замер 14.08: `[partition] нет карты`, код 1 на свежем рендере.
# Дефолт безопасен: он оставляет ВСЕ записи в живом файле (пустая карта увела бы их в архив).
if [[ ! -f "$MAP" ]]; then
  mkdir -p "$(dirname "$MAP")"
  {
    printf '# Карта раскладки реестра ловушек: <целевой файл> <ID через пробел>\n'
    printf '#\n'
    printf '# Создана автоматически при первом прогоне. Живым считается запись, на которую\n'
    printf '# ссылается правило, док, спека или тест, ЛИБО которая поймала повтор. Всё, чего\n'
    printf '# нет в карте, уезжает в архив — он ищется грепом и в контекст агента не грузится.\n'
    printf '#\n'
    printf '# НОВАЯ запись обязана попасть в карту сразу: иначе следующий прогон уведёт её\n'
    printf '# в архив, и свежее знание исчезнет тише всего — без ошибки и без следа в diff.\n'
    printf '#\n'
    printf '# Ниже перечислены ВСЕ текущие ID: дефолт ничего не архивирует. Раскладывай по темам\n'
    printf '# сам, ориентир — до 30 KB на файл.\n'
    printf 'gotchas.md %s\n' "$(grep -hoE "^${PREFIX_RE}[0-9]+" "$DOCS"/gotchas*.md 2>/dev/null | grep -oE '[0-9]+' | LC_ALL=C sort -un | tr '\n' ' ')"
  } > "$MAP"
  printf '[partition] карты не было, создана из текущего реестра: %s\n' "${MAP#"$REPO_ROOT"/}" >&2
fi

# Входы — все файлы реестра, какие есть сейчас. Скрипт идемпотентен: повторный прогон
# перекладывает те же записи по обновлённой карте, поэтому вернуть запись из архива
# можно строкой в карте, без ручного переноса текста.
IN_MAIN="${DOCS}/gotchas.md"
[[ -f "$IN_MAIN" ]] || { printf '[partition] нет входа: %s\n' "$IN_MAIN" >&2; exit 1; }

INPUTS=("$IN_MAIN")
while IFS= read -r f; do
  [[ "$f" == "$IN_MAIN" ]] && continue
  INPUTS+=("$f")
done < <(find "$DOCS" -maxdepth 1 -name 'gotchas*.md' | LC_ALL=C sort)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Карта в вид "id:target,id:target" — awk принимает её одной переменной.
MAP_ARG="$(awk '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  { for (i = 2; i <= NF; i++) printf "%s:%s,", $i, $1 }
' "$MAP")"

# Заголовок записи — любая строка `## `. Номер есть не у всех: две записи попали в
# реестр без нумерации, и потерять их молча было бы ровно тем провалом, от которого
# здесь стоит сверка.
awk -v map="$MAP_ARG" -v work="$WORK" -v archive="$ARCHIVE_NAME" -v prefix="$GOTCHA_ID_PREFIX" '
  # Сравнение строкой, а не регексом: префикс приходит извне, и мета-символ в нём
  # (точка, скобка) сделал бы регекс тихо неверным вместо ошибки.
  function id_of(line,   rest, i, c, num) {
    if (substr(line, 1, length(prefix)) != prefix) return ""
    rest = substr(line, length(prefix) + 1)
    num = ""
    for (i = 1; i <= length(rest); i++) {
      c = substr(rest, i, 1)
      if (c >= "0" && c <= "9") num = num c
      else break
    }
    return num
  }
  function target_of(line,   id) {
    id = id_of(line)
    if (id == "") return archive
    return (id in T) ? T[id] : archive
  }
  function flush() {
    if (buf == "") return
    printf "%s", buf >> (work "/" curfile)
    buf = ""
  }
  BEGIN {
    n = split(map, pairs, ",")
    for (i = 1; i <= n; i++) {
      if (pairs[i] == "") continue
      split(pairs[i], kv, ":")
      T[kv[1]] = kv[2]
      TARGETS[kv[2]] = 1
    }
  }
  FNR == 1 {
    flush()
    # Шапка живого файла (frontmatter с `description`) — часть роутинга, её сохраняем
    # на месте. Шапку архива отбрасываем: скрипт её генерирует заново, иначе метка
    # копилась бы с каждым прогоном.
    base = FILENAME; sub(/^.*\//, "", base)
    curfile = (base in TARGETS) ? base : archive
    skippre = (base == archive)
  }
  /^## / {
    flush()
    skippre = 0
    curfile = target_of($0)
    id = id_of($0)
    total++
    if (id != "") print id >> (work "/ids-before.txt")
    else          print "NONUM-" total >> (work "/ids-before.txt")
    printf "%s", "" >> (work "/" curfile)
  }
  { if (!skippre) buf = buf $0 "\n" }
  END { flush(); print total > (work "/total.txt") }
' "${INPUTS[@]}"

TOTAL_IN="$(cat "${WORK}/total.txt")"

# Сверка: сколько заголовков вошло и сколько лежит в результатах.
TOTAL_OUT=0
for out in "$WORK"/*.md; do
  c="$(grep -c '^## ' "$out")"
  TOTAL_OUT=$(( TOTAL_OUT + c ))
  printf '  %-22s %3s записей  %6s байт\n' "$(basename "$out")" "$c" "$(wc -c <"$out" | tr -d ' ')"
done

printf 'заголовков на входе: %s · в результатах: %s\n' "$TOTAL_IN" "$TOTAL_OUT"

if [[ "$TOTAL_IN" -ne "$TOTAL_OUT" ]]; then
  printf '[partition] потеря записей: %s → %s. Ничего не записано.\n' "$TOTAL_IN" "$TOTAL_OUT" >&2
  exit 1
fi

# Сверка по множествам, а не по числу: равное количество не значит тот же состав.
grep -hoE "^${PREFIX_RE}[0-9]+" "${INPUTS[@]}" | grep -oE '[0-9]+' | LC_ALL=C sort -u >"${WORK}/set-before"
grep -hoE "^${PREFIX_RE}[0-9]+" "$WORK"/*.md    | grep -oE '[0-9]+' | LC_ALL=C sort -u >"${WORK}/set-after"

# Вырожденный вход: ни одной записи не распознано. Без этой ветки скрипт печатает
# «множества ID совпали: 0» и уводит весь реестр в архив — зелёный отчёт при полной потере.
if [[ ! -s "${WORK}/set-before" ]]; then
  printf '[partition] по префиксу "%s" не найдено НИ ОДНОЙ записи в реестре.\n' "$GOTCHA_ID_PREFIX" >&2
  printf 'Формат заголовков не совпадает с GOTCHA_ID_PREFIX — проверь .harness.conf.\n' >&2
  printf 'Ничего не записано.\n' >&2
  exit 1
fi
DIFF="$(comm -3 "${WORK}/set-before" "${WORK}/set-after")"
if [[ -n "$DIFF" ]]; then
  printf '[partition] множества ID разошлись:\n%s\nНичего не записано.\n' "$DIFF" >&2
  exit 1
fi
printf 'множества ID совпали: %s уникальных\n' "$(wc -l <"${WORK}/set-before" | tr -d ' ')"

if [[ "$DRY" -eq 1 ]]; then
  printf '[partition] dry-run, результаты лежат в %s\n' "$WORK" >&2
  trap - EXIT
  exit 0
fi

# Метка архива ставится здесь, а не в тексте записей: она про сам файл, а не про ловушки.
# Условие на существование обязательно: когда в архив не уехало НИ ОДНОЙ записи (свежий проект,
# все записи в карте), файла нет — и безусловная сборка печатала `cat: нет файла` в stderr,
# а потом создавала пустышку с одной шапкой. Док, который выглядит реестром и пуст, хуже
# отсутствующего: его открывают и делают вывод. Поймано прогоном 14.08.
ARCH="${WORK}/${ARCHIVE_NAME}"
if [[ ! -f "$ARCH" ]]; then
  printf '[partition] в архив не уехало ничего — файл архива не создаётся.\n' >&2
else
{
  printf '# Архив реестра ловушек\n\n'
  printf 'Записи, на которые не ссылается ни правило, ни док, ни спека, ни тест, и которые\n'
  printf 'не поймали повтор. Не удалены: `grep` по этому файлу работает, а состав живой части\n'
  printf 'определяется картой `scripts/gotchas-partition.map`.\n\n'
  printf 'В JIT-таблице `CLAUDE.md` архива нет намеренно — агент его не грузит.\n'
  printf 'Возврат записи в живую часть = строка в карте плюс прогон `scripts/gotchas-partition.sh`.\n\n'
  printf -- '---\n\n'
  cat "$ARCH"
} >"${ARCH}.tmp"
mv "${ARCH}.tmp" "$ARCH"
fi

for out in "$WORK"/*.md; do
  mv "$out" "${DOCS}/$(basename "$out")"
done

# Входной файл, которого нет среди целей, опустел: его записи разъехались. Удаляем,
# иначе следующий прогон прочитает пустышку как источник.
for in_f in "${INPUTS[@]}"; do
  base="$(basename "$in_f")"
  [[ -f "${DOCS}/${base}" ]] && grep -q '^## ' "${DOCS}/${base}" && continue
  rm -f "${DOCS}/${base}"
  printf '[partition] опустевший файл удалён: %s\n' "$base" >&2
done

printf '[partition] готово.\n' >&2
