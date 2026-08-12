#!/usr/bin/env bash
# Разворот проекта с харнессом одной командой.
# Прогон из целевой ПУСТОЙ папки:
#   bash /path/to/harness-template/scripts/bootstrap.sh <имя> [lang]
# lang: python | vue | go | php | none (по умолчанию python)
#
# Что делает: создаёт проект → зовёт copier с нужным языковым паком →
# дорендеривает CLAUDE.md / settings.json / .harness.conf (copier их не привозит,
# в скелете они лежат как .template/.example) → подменяет сенсор по языку → smoke.
set -euo pipefail

NAME="${1:?нужно имя проекта: bootstrap.sh <имя> [lang] [--agents]}"
LANG_PACK="${2:-python}"
# ADR-13: роли-агенты instance-owned, авто-доставки нет. Флаг = явное принятие.
WITH_AGENTS=no
[[ "${3:-}" == "--agents" ]] && WITH_AGENTS=yes

# Гард на непустую папку. Требование «запускать из пустой папки» стояло только
# комментарием в шапке, а uv init / git init / copier молча работают в любой — и разворот
# уехал в корень рабочего каталога со всеми проектами: git init там сломал определение
# границ репозитория для всех хуков (инцидент 30.07). .DS_Store игнорируем, его создаёт macOS.
EXISTING="$(ls -A 2>/dev/null | grep -v '^\.DS_Store$' || true)"
if [[ -n "$EXISTING" ]]; then
  {
    echo "Отказ: папка $(pwd) не пуста."
    echo "Найдено: $(echo "$EXISTING" | head -3 | tr '\n' ' ')"
    echo
    echo "Bootstrap разворачивает проект в ТЕКУЩУЮ папку. Создай пустую и зайди в неё:"
    echo "  mkdir -p $NAME && cd $NAME && bash $0 $NAME $LANG_PACK"
  } >&2
  exit 1
fi
TPL="$(cd "$(dirname "$0")/.." && pwd)"

case "$LANG_PACK" in
  python)
    command -v uv >/dev/null || { echo "нужен uv: https://docs.astral.sh/uv/" >&2; exit 1; }
    uv init --package --name "$NAME" . >/dev/null
    uv add --dev pytest ruff >/dev/null
    WATCH_DIR="src"
    TEST_CMD="uv run pytest -q"
    SENSOR="run-pytest-hook.sh"
    READONLY="__pycache__ .pytest_cache .ruff_cache .venv"
    GATE_CMD="uv run ruff check . && uv run ruff format --check ."
    GATE_TEST_CMD="uv run pytest"
    PKG_PATH="src/$NAME"
    LANG_VER="Python 3.12+ (uv-managed)"
    BUILD_TOOL="uv"
    TEST_FW="pytest"
    OTHER_TOOLS="ruff (lint + format)"
    ;;
  vue|go|php|none)
    git init -q .
    WATCH_DIR="src"
    TEST_CMD="npx vitest related --run"
    SENSOR="run-test-hook.sh"
    READONLY="dist"
    GATE_CMD="npm run type-check && npm run lint"
    GATE_TEST_CMD="npm test"
    PKG_PATH="src"
    LANG_VER="TypeScript / Node"
    BUILD_TOOL="npm"
    TEST_FW="vitest"
    OTHER_TOOLS="eslint"
    ;;
  *)
    echo "неизвестный lang: $LANG_PACK (python|vue|go|php|none)" >&2
    exit 1
    ;;
esac

# Поля, которые до постановки задачи неизвестны, получают честный маркер, а не
# остаются голым плейсхолдером: незаполненное должно читаться как незаполненное.
TODO_MARK="— заполнить при скрининге"
# Внутри code-блока с деревом структуры длинный маркер превращается в мусор
# ("— заполнить при скрининге/     ← основная единица"). Там нужен короткий.
TODO_SHORT="TODO"

command -v copier >/dev/null || { echo "нужен copier: uv tool install copier" >&2; exit 1; }

# --vcs-ref HEAD обязателен. Без него copier для git-шаблона берёт последний ТЕГ
# (сейчас v0.1.8 от 23.06), а не рабочую копию — новые файлы скелета в инстанс
# не попадают и отсутствуют молча. Флот раскатывается с тега осознанно; локальная
# разработка кита должна видеть текущее состояние. Найдено прогоном 29.07.
copier copy --trust --defaults --overwrite --vcs-ref HEAD \
  --data project_name="$NAME" --data lang="$LANG_PACK" "$TPL" . >/dev/null

# Дорендер трёх файлов. Незаменённый плейсхолдер ломает харнесс молча,
# поэтому подставляются все шесть, включая пустой WIKI_PATH.
render() {
  sed -e "s|<PROJECT_NAME>|$NAME|g" \
      -e "s|{{PROJECT}}|$NAME|g" \
      -e "s|<PACKAGE_PATH>|$PKG_PATH|g" \
      -e "s|<WATCH_DIR>|$WATCH_DIR|g" \
      -e "s|<TEST_CMD>|$TEST_CMD|g" \
      -e "s|<READONLY_ZONES>|$READONLY|g" \
      -e "s|<LANG_AND_VERSION>|$LANG_VER|g" \
      -e "s|<BUILD_TOOL>|$BUILD_TOOL|g" \
      -e "s|<TEST_FRAMEWORK>|$TEST_FW|g" \
      -e "s|<OTHER_TOOLS>|$OTHER_TOOLS|g" \
      -e "s|<FRAMEWORK_AND_VERSION>|$TODO_MARK|g" \
      -e "s|<MODULE_DIR>|$TODO_SHORT|g" \
      -e "s|<SHARED_DIR>|$TODO_SHORT|g" \
      -e "s|<ENTRY_POINT>|$TODO_SHORT|g" \
      -e "s|<UNIT_PATTERN>|$TODO_MARK|g" \
      -e "s|<TYPING_RULE>|$TODO_MARK|g" \
      -e "s|<QA_MARKER>|$TODO_MARK|g" \
      -e "s|<REFERENCE_PATH>|$TODO_MARK|g" \
      -e "s|<ENTITIES>|$TODO_MARK|g" \
      -e "s|<DATA_SOURCE>|$TODO_MARK|g" \
      -e "s|<DATA_INVARIANT>|$TODO_MARK|g" \
      -e "s|<MAIN_FLOW>|$TODO_MARK|g" \
      -e "s|<STATE_TRANSITIONS>|$TODO_MARK|g" \
      -e "s|<ACCESS_RULES>|$TODO_MARK|g" \
      -e "s|<WIKI_PATH>||g" "$1"
}

render "$TPL/skeleton/CLAUDE.md.template" > CLAUDE.md

mkdir -p .claude
render "$TPL/skeleton/.claude/settings.json.template" \
  | sed "s|run-test-hook.sh|$SENSOR|g" > .claude/settings.json

# Doc-каркас. Copier их не привозит: .claude/docs в _exclude, плюс маска *.template.
mkdir -p .claude/docs
for DOC in ARCHITECTURE gotchas REVIEW; do
  render "$TPL/skeleton/.claude/docs/$DOC.md.template" > ".claude/docs/$DOC.md"
done

# Лог проекта. В скелете его нет: PENDING-NOTES пишет в вику через WIKI_PATH,
# а на чужой машине вики не будет. Дата подставляется на генерации, иначе в логе
# осталась бы дата шаблона.
mkdir -p docs
cat > docs/log.md <<LOG
# Лог — $NAME

> Записи новыми сверху. Одна запись — один смысловой шаг: что сделал, что удивило,
> что дальше. Заполняется по ходу, не постфактум: восстановленный вечером лог теряет
> ровно то, что было неочевидно днём.

## $(date +%Y-%m-%d) — разворот

Инстанс развёрнут через bootstrap. Тесты: \`$TEST_CMD\`.
LOG

if [[ "$WITH_AGENTS" == yes ]]; then
  mkdir -p .claude/agents
  cp "$TPL/skeleton/.claude/agents/"*.md .claude/agents/
fi

cat > docs/MOC.md <<'MOC'
# MOC — карта проекта

> В каком порядке это читать. Ярусы по времени, не по важности:
> ярус 0 достаточен, чтобы начать работу.

## Ярус 0 — минимум перед первой правкой

- `CLAUDE.md` — правила и роутинг, грузится всегда
- `docs/specs/spec-*.md` — активная спека среза. Нет спеки → код не начинаем

## Ярус 1 — устройство проекта

- `.claude/docs/ARCHITECTURE.md` — стек, структура, инварианты, модель данных, бизнес-логика
- `docs/log.md` — что происходило и что удивило

## Ярус 2 — по нужде

- `.claude/docs/gotchas.md` — правила, найденные на реальной работе (§-нумерация)
- `.claude/docs/REVIEW.md` — чеклист ревью
- `.claude/agents/` — роли-агенты, если раскатаны флагом `--agents`

## Как это пополняется

Находка при разборе кода → секция в `ARCHITECTURE.md`.
Грабли, которые повторятся → `§` в `gotchas.md`.
Что произошло за сессию → запись в `docs/log.md`, новыми сверху.
MOC

cat > .harness.conf <<CONF
# Сгенерировано bootstrap.sh для lang=$LANG_PACK
WATCH_DIR="$WATCH_DIR"
TEST_CMD="$TEST_CMD"
PYTEST_MODE="map"
# Байткод-кэш Python сверяется по mtime с точностью до секунды. Агент правит файл
# чаще — вторая правка в ту же секунду оставляет .pyc «актуальным», и тест исполняет
# прошлую версию кода. Сенсор отдаёт ложный сигнал. Хук делает source этого файла,
# поэтому переменная доезжает до дочернего pytest. Найдено прогоном 29.07.
export PYTHONDONTWRITEBYTECODE=1
READONLY_ZONES="$READONLY"
GATE_CMD="$GATE_CMD"
GATE_TEST_CMD="$GATE_TEST_CMD"
GATE_WORKDIR=""
WIKI_PATH=""
CONF

# settings.json.template подключает SessionStart → scripts/load-context.sh, но папка
# scripts в copier _exclude — в инстансе файла нет, и каждый старт сессии пишет ошибку
# в stderr, создавая впечатление, что контекст загружен. Генерируем минимальный.
mkdir -p scripts
cat > scripts/load-context.sh <<'CTX'
#!/usr/bin/env bash
# SessionStart: показать агенту, на какой фазе работа. Вывод уходит в его контекст.
set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SPECS=$(ls "$ROOT"/docs/specs/spec-*.md 2>/dev/null)

if [[ -z "$SPECS" ]]; then
  echo "Спеки среза нет. Первый шаг — копия docs/specs/_template.md → spec-<дата>-<срез>.md."
  echo "Пока нет файла спеки с заполненными AC — код не начинаем."
  exit 0
fi

echo "Активные спеки:"
while IFS= read -r f; do
  OPEN=$(grep -c '^- \[ \]' "$f" 2>/dev/null || true)
  echo "  $(basename "$f") — незакрытых галок: ${OPEN:-0}"
done <<< "$SPECS"
CTX
chmod +x scripts/load-context.sh

if [[ "$LANG_PACK" == python ]]; then
  mkdir -p tests
  cat > tests/test_smoke.py <<'PY'
def test_smoke() -> None:
    """Доказывает, что петля жива до первой строки задачи."""
    assert 1 + 1 == 2
PY
  uv run pytest -q
fi

echo
echo "Готово: $NAME (lang=$LANG_PACK)."
echo "Первый шаг — копия docs/specs/_template.md → docs/specs/spec-<дата>-<срез>.md."
echo "Нет файла спеки с заполненными AC → код не начинаем."
