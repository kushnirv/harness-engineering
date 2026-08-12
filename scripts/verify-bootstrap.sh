#!/usr/bin/env bash
# Самопроверка bootstrap.sh. Прогон: bash scripts/verify-bootstrap.sh
# Разворачивает Python-инстанс во временной папке и проверяет 32 условия по группам:
#   разворот      — дорендер трёх файлов харнесса, подмена сенсора, плейсхолдеры, smoke, время
#   doc-каркас    — ARCHITECTURE/gotchas/REVIEW, секции данных и логики, маркеры незаполненного
#   лог и MOC     — docs/log.md, docs/MOC.md с ярусами
#   карта доков   — блок в CLAUDE.md, отсутствие @-импортов
#   сенсор в деле — сигнал на красном тесте, молчание на зелёном
#   роли-агенты   — дефолт без них, флаг --agents доставляет
# Второй инстанс (lang=none) разворачивается только для проверки флага --agents.
set -uo pipefail

TPL="$(cd "$(dirname "$0")/.." && pwd)"
FAILED=0

# Скрипт перезаписывает один и тот же .py дважды за секунду — ровно тот случай,
# где Python считает устаревший .pyc валидным (mtime совпал) и исполняет старый код.
export PYTHONDONTWRITEBYTECODE=1

check() {
  if [[ "$2" == "$3" ]]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1 — ожидалось [$3], получено [$2]"
    FAILED=1
  fi
}

P="$(mktemp -d)"
# Нормализация обязательна: mktemp отдаёт /var/..., а git rev-parse внутри той же
# папки вернёт /private/var/... (/var — симлинк на macOS). Хуки сравнивают пути
# строкой и молча вышли бы с нулём, показав «сенсор молчит» на исправном сенсоре.
P="$(cd "$P" && pwd -P)"
cd "$P" || exit 1

echo "== Разворот Python-инстанса =="
START=$(date +%s)
bash "$TPL/scripts/bootstrap.sh" probe python >/dev/null 2>&1
ELAPSED=$(( $(date +%s) - START ))

[[ -f "$P/CLAUDE.md" ]] && R=yes || R=no
check "CLAUDE.md дорендерен" "$R" yes

[[ -f "$P/.claude/settings.json" ]] && R=yes || R=no
check "settings.json дорендерен" "$R" yes

[[ -f "$P/.harness.conf" ]] && R=yes || R=no
check "harness.conf создан" "$R" yes

[[ -f "$P/docs/specs/_template.md" ]] && R=yes || R=no
check "шаблон спеки на месте" "$R" yes

[[ -f "$P/.claude/guards/run-pytest-hook.sh" ]] && R=yes || R=no
check "Python-сенсор приехал" "$R" yes

grep -q "run-pytest-hook.sh" "$P/.claude/settings.json" 2>/dev/null && R=yes || R=no
check "сенсор подменён на pytest" "$R" yes

grep -q 'PYTEST_MODE="map"' "$P/.harness.conf" 2>/dev/null && R=yes || R=no
check "режим сенсора map" "$R" yes

if grep -q "<[A-Z_]\{2,\}>" "$P/CLAUDE.md" "$P/.claude/settings.json" 2>/dev/null; then R=есть; else R=нет; fi
check "незаменённых плейсхолдеров нет" "$R" нет

[[ -x "$P/scripts/load-context.sh" ]] && R=yes || R=no
check "SessionStart-скрипт существует и исполняем" "$R" yes

CTX_OUT=$(cd "$P" && bash scripts/load-context.sh 2>&1)
echo "$CTX_OUT" | grep -q "код не начинаем" && R=yes || R=no
check "SessionStart напоминает про spec-first" "$R" yes

# log-append.sh: правило в workflow.md и скил end-session требуют его ПО ИМЕНИ и
# запрещают Edit для лога. Проверяем не наличие, а работу — файл на месте, но не
# вставляющий запись, оставил бы правило неисполнимым при зелёной проверке.
[[ -x "$P/scripts/log-append.sh" ]] && R=yes || R=no
check "log-append.sh доставлен и исполняем" "$R" yes

LOG_BEFORE=$(wc -l < "$P/docs/log.md" 2>/dev/null | tr -d ' ')
printf '## 2026-01-01 — проверка доставки\n\nстрока из verify-bootstrap\n' > "$P/.probe-entry.md"
(cd "$P" && bash scripts/log-append.sh .probe-entry.md >/dev/null 2>&1) && R=yes || R=no
check "log-append вставляет запись" "$R" yes

LOG_AFTER=$(wc -l < "$P/docs/log.md" 2>/dev/null | tr -d ' ')
[[ "${LOG_AFTER:-0}" -gt "${LOG_BEFORE:-0}" ]] && R=yes || R=no
check "лог вырос после вставки" "$R" yes

# Запись обязана лечь ПЕРЕД старыми: лог читается сверху.
FIRST_HDR=$(grep -m1 '^## ' "$P/docs/log.md" 2>/dev/null)
[[ "$FIRST_HDR" == *"проверка доставки"* ]] && R=yes || R=no
check "новая запись легла сверху" "$R" yes

(cd "$P" && : > .empty-entry.md && bash scripts/log-append.sh .empty-entry.md >/dev/null 2>&1) && R=прошло || R=отказ
check "пустая запись отклонена" "$R" отказ

# --- Сверка AC ↔ тест -----------------------------------------------------------
# На шаблон спеки ссылается docs/specs/_template.md, поэтому скрипт обязан доехать.
[[ -x "$P/scripts/check-ac-refs.sh" ]] && R=yes || R=no
check "check-ac-refs.sh доставлен и исполняем" "$R" yes

[[ -f "$P/scripts/check-ac-refs.baseline" ]] && R=yes || R=no
check "baseline порога создан" "$R" yes

grep -q '^AC_TEST_GLOBS="[^"]\+"' "$P/.harness.conf" 2>/dev/null && R=yes || R=no
check "AC_TEST_GLOBS заполнен под стек" "$R" yes

# Свежий инстанс: спек нет → судить не о чем, обязан быть тихий успех.
(cd "$P" && bash scripts/check-ac-refs.sh --quiet >/dev/null 2>&1) && R=0 || R=не0
check "без спек проверка не падает" "$R" 0

# Спека с критерием, теста нет → обязан упасть. Это и есть та дыра, ради которой скрипт.
mkdir -p "$P/docs/specs"
printf '# Спека: проба\n\n## Verification (AC)\n\n- [ ] **AC-001** — критерий без теста\n' \
  > "$P/docs/specs/spec-probe.md"
(cd "$P" && bash scripts/check-ac-refs.sh --quiet >/dev/null 2>&1) && R=прошло || R=упало
check "AC без теста ловится" "$R" упало

# Ссылка из теста появилась → обязан пройти. Каталог и маску берём из .harness.conf,
# иначе проверка молча разошлась бы с тем, что реально настроено в инстансе.
AC_DIR_CONF=$(grep '^AC_TEST_DIR=' "$P/.harness.conf" | sed 's/^AC_TEST_DIR="//; s/"$//; s|\$REPO_ROOT|'"$P"'|')
AC_GLOB_ONE=$(grep '^AC_TEST_GLOBS=' "$P/.harness.conf" | sed 's/^AC_TEST_GLOBS="//; s/"$//' | awk '{print $1}')
mkdir -p "$AC_DIR_CONF"
AC_PROBE_FILE="$AC_DIR_CONF/${AC_GLOB_ONE//\*/ac_probe}"

# Регресс на глоббинг: без noglob маска схлопывается в имя файла из корня, find пуст,
# проверка уходит в fail-open. Кейс различающий: AC есть, теста нет → обязано УПАСТЬ.
DECOY="$P/${AC_GLOB_ONE//\*/decoy}"
: > "$DECOY"
(cd "$P" && bash scripts/check-ac-refs.sh --quiet >/dev/null 2>&1) && R=прошло || R=упало
check "маска не схлопывается в файл из корня" "$R" упало
rm -f "$DECOY"
# Контент — КОММЕНТАРИЙ: `#` валиден и в .py, и в .ts. Голый текст сделал бы файл
# несобираемым, и следующая проверка (smoke-тест инстанса) упала бы из-за этой пробы.
printf '# AC-001 — ссылка из теста для verify-bootstrap\n' > "$AC_PROBE_FILE"
(cd "$P" && bash scripts/check-ac-refs.sh --quiet >/dev/null 2>&1) && R=прошло || R=упало
check "AC со ссылкой из теста проходит" "$R" прошло

# ID вне секции Verification критерием не считается — иначе любое упоминание требовало теста.
# AC-777 кладём ИМЕННО ЧЕКБОКСОМ и в другую секцию: обычным текстом проверка декоративна —
# мутация показала, что на сломанном разборе секций она не краснеет (ID вне чекбокса
# не берётся и так).
printf '\n## Изменения\n\n- [ ] **AC-777** — пункт изменений, не критерий приёмки\n' \
  >> "$P/docs/specs/spec-probe.md"
(cd "$P" && bash scripts/check-ac-refs.sh --quiet >/dev/null 2>&1) && R=прошло || R=упало
check "ID вне секции Verification не считается" "$R" прошло

# Прибираем пробы: инстанс проверяют дальше (smoke-тест, гейт), и наши файлы не должны
# в этом участвовать. Проверка, которая пачкает объект проверки, врёт о следующих шагах.
echo "== SessionStart: фаза работы и личный слой =="

[[ -x "$P/scripts/load-context.sh" ]] && R=yes || R=no
check "load-context.sh доставлен и исполняем" "$R" yes

# Вывод забираем в переменную, а не через `| grep -q`: grep закрывает пайп на первом
# совпадении, писатель получает SIGPIPE, и pipefail красит конвейер — проверка провалилась бы
# на исправном скрипте.
#
# Спека на месте (создана выше) — хук обязан её увидеть. Раньше корень считался как
# `dirname/../..`, уводил выше репо, и хук молча не находил ни спек, ни конфига.
LC_OUT="$(cd "$P" && bash scripts/load-context.sh 2>/dev/null)"
[[ "$LC_OUT" == *"spec-probe.md"* ]] && R=yes || R=no
check "видит активную спеку" "$R" yes

# Личный слой: адрес вики приходит ИЗ-ВНЕ репозитория, командный конфиг о нём не знает.
LOCAL_CONF="$P/../local-probe.conf"
mkdir -p "$P/../wiki-probe"
printf '# overview-проба\n' > "$P/../wiki-probe/overview.md"
printf 'WIKI_PATH="%s"\n' "$P/../wiki-probe" > "$LOCAL_CONF"
LC_OUT="$(cd "$P" && HARNESS_LOCAL_CONF="$LOCAL_CONF" bash scripts/load-context.sh 2>/dev/null)"
[[ "$LC_OUT" == *"overview-проба"* ]] && R=yes || R=no
check "вика грузится из личного конфига" "$R" yes

# Тот же прогон без личного конфига обязан молчать про вику, иначе слой не изолирован.
LC_OUT="$(cd "$P" && HARNESS_LOCAL_CONF="$P/../нет-такого.conf" bash scripts/load-context.sh 2>/dev/null)"
[[ "$LC_OUT" == *"Долгая память"* ]] && R=печатает || R=молчит
check "без личного конфига про вику молчит" "$R" молчит

grep -q '^WIKI_PATH=' "$P/.harness.conf" && R=есть || R=нет
check "WIKI_PATH не попал в командный конфиг" "$R" нет

rm -rf "$LOCAL_CONF" "$P/../wiki-probe"
rm -f "$AC_PROBE_FILE" "$P/docs/specs/spec-probe.md"

(cd "$P" && uv run pytest -q >/dev/null 2>&1) && R=green || R=red
check "smoke-тест зелёный" "$R" green

[[ $ELAPSED -lt 20 ]] && R=fast || R=slow
check "разворот меньше 20 с (факт: ${ELAPSED}с)" "$R" fast

echo "== Doc-каркас =="
for DOC in ARCHITECTURE gotchas REVIEW; do
  [[ -f "$P/.claude/docs/$DOC.md" ]] && R=yes || R=no
  check "$DOC.md дорендерен" "$R" yes
done

if grep -q "<[A-Z_]\{2,\}>\|{{[A-Z_]*}}" "$P/.claude/docs/"*.md 2>/dev/null; then R=есть; else R=нет; fi
check "плейсхолдеров в doc-каркасе нет" "$R" нет

grep -q "заполнить при скрининге" "$P/.claude/docs/ARCHITECTURE.md" 2>/dev/null && R=yes || R=no
check "незаполненное помечено маркером" "$R" yes

grep -q "pytest" "$P/.claude/docs/ARCHITECTURE.md" 2>/dev/null && R=yes || R=no
check "языковые значения подставлены (pytest)" "$R" yes

grep -q "^## Модель данных" "$P/.claude/docs/ARCHITECTURE.md" 2>/dev/null && R=yes || R=no
check "секция «Модель данных» есть" "$R" yes

grep -q "^## Бизнес-логика" "$P/.claude/docs/ARCHITECTURE.md" 2>/dev/null && R=yes || R=no
check "секция «Бизнес-логика» есть" "$R" yes

# Внутри дерева структуры длинный маркер читается как мусор ("— заполнить.../ ← ...").
# В code-блоке нужен короткий; найдено прогоном 30.07.
grep -q "TODO/ *←" "$P/.claude/docs/ARCHITECTURE.md" 2>/dev/null && R=yes || R=no
check "в дереве структуры короткий маркер" "$R" yes

[[ -f "$P/docs/log.md" ]] && R=yes || R=no
check "docs/log.md создан" "$R" yes

[[ -f "$P/docs/MOC.md" ]] && R=yes || R=no
check "docs/MOC.md создан" "$R" yes

grep -q "Ярус 0" "$P/docs/MOC.md" 2>/dev/null && R=yes || R=no
check "MOC размечен ярусами" "$R" yes

grep -q "Проектная документация" "$P/CLAUDE.md" 2>/dev/null && R=yes || R=no
check "карта доков в CLAUDE.md есть" "$R" yes

# @-импорт затянул бы каркас в контекст на старте каждой сессии. Страховка от регресса.
if grep -qE "^@|[[:space:]]@\.claude/docs|[[:space:]]@docs/" "$P/CLAUDE.md" 2>/dev/null; then R=есть; else R=нет; fi
check "@-импортов в CLAUDE.md нет" "$R" нет

echo "== Сенсор в деле =="
mkdir -p "$P/src/probe" "$P/tests"
cat > "$P/src/probe/calc.py" <<'PY'
def add(a: int, b: int) -> int:
    return a - b
PY
cat > "$P/tests/test_calc.py" <<'PY'
from probe.calc import add


def test_add() -> None:
    assert add(2, 2) == 4
PY

HOOK_JSON='{"tool_input":{"file_path":"'"$P"'/src/probe/calc.py"}}'

set +e
OUT=$(cd "$P" && echo "$HOOK_JSON" | bash "$P/.claude/guards/run-pytest-hook.sh" 2>/dev/null)
CODE=$?
set -e
[[ $CODE -eq 1 ]] && R=cried || R=silent
check "сенсор сигналит на красном тесте" "$R" cried

echo "$OUT" | grep -q additionalContext && R=yes || R=no
check "в выводе есть additionalContext" "$R" yes

cat > "$P/src/probe/calc.py" <<'PY'
def add(a: int, b: int) -> int:
    return a + b
PY
set +e
OUT=$(cd "$P" && echo "$HOOK_JSON" | bash "$P/.claude/guards/run-pytest-hook.sh" 2>/dev/null)
CODE=$?
set -e
[[ $CODE -eq 0 && -z "$OUT" ]] && R=silent || R=noisy
check "молчит при зелёном (mute the green)" "$R" silent

echo "== Роли-агенты по флагу =="
[[ -d "$P/.claude/agents" ]] && R=есть || R=нет
check "без флага папки agents нет" "$R" нет

PA="$(mktemp -d)"; PA="$(cd "$PA" && pwd -P)"
(cd "$PA" && bash "$TPL/scripts/bootstrap.sh" probe none --agents >/dev/null 2>&1)
# `|| true` обязателен: блок сенсора выше оставляет set -e включённым, а ls по
# отсутствующей папке (или grep без совпадений) убил бы скрипт до печати итога.
# Найдено прогоном 30.07 — обрыв вывода без единого FAIL.
AGENT_COUNT=$(ls -1 "$PA/.claude/agents/" 2>/dev/null | grep -c '\.md$' || true)
# Семь, не пять: к пяти ролям из fenris в скелете уже лежали bug-triage (ADR-13) и README.
check "с флагом --agents приехало 7 файлов ролей" "$AGENT_COUNT" 7

[[ -f "$PA/.claude/agents/reviewer.md" && -f "$PA/.claude/agents/scout.md" ]] && R=yes || R=no
check "роли из fenris на месте (reviewer, scout)" "$R" yes

echo "== Гард на непустую папку =="
PB="$(mktemp -d)"; PB="$(cd "$PB" && pwd -P)"
touch "$PB/уже-есть.txt"
set +e
(cd "$PB" && bash "$TPL/scripts/bootstrap.sh" probe none >/dev/null 2>&1)
GUARD_CODE=$?
set -e
[[ $GUARD_CODE -ne 0 ]] && R=отказал || R=развернул
check "в непустой папке bootstrap отказывается" "$R" отказал

[[ -e "$PB/CLAUDE.md" || -e "$PB/.git" ]] && R=создал || R=нет
check "при отказе ничего не создано" "$R" нет

echo
echo "Инстанс: $P"
[[ $FAILED -eq 0 ]] && echo "ВСЁ ЗЕЛЁНОЕ" || echo "ЕСТЬ ПРОВАЛЫ"
exit $FAILED
