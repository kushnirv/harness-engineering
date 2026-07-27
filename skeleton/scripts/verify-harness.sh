#!/usr/bin/env bash
# Smoke test: проверяет что харнесс работает как задумано.
# Запускать после setup и после любого рефактора структуры.
#
# Работает в двух режимах (определяется по раскладке):
#   - инстанс:      guards в .claude/guards/ (обычный проект на харнессе)
#   - репо шаблона: guards в skeleton/.claude/guards/ (разработка самого харнесса)
#
# .harness.conf опционален: нет файла → дефолты, проверки конфига помечаются SKIP.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

# NB: PASS=$((...)) не ((PASS++)) — `((expr))` возвращает exit 1 когда результат 0,
# и под `set -e` это роняет скрипт на первом же ok()/fail() (счётчик стартует с 0).
ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  [SKIP] $1"; }

echo "=== verify-harness ==="
echo ""

# 0. Режим: инстанс или репо шаблона
if [[ -d "${REPO_ROOT}/.claude/guards" ]]; then
  CLAUDE_DIR="${REPO_ROOT}/.claude"
elif [[ -d "${REPO_ROOT}/skeleton/.claude/guards" ]]; then
  CLAUDE_DIR="${REPO_ROOT}/skeleton/.claude"
else
  fail "не найдено ни .claude/guards, ни skeleton/.claude/guards в ${REPO_ROOT}"
  echo ""
  echo "=== Результат: ${PASS} pass / ${FAIL} fail ==="
  exit 1
fi
GUARDS="${CLAUDE_DIR}/guards"

# 1. .harness.conf (опционален — без него работаем на дефолтах)
CONF="${REPO_ROOT}/.harness.conf"
if [[ -f "$CONF" ]]; then
  source "$CONF"
  ok ".harness.conf найден и читается"
else
  skip ".harness.conf не найден — использую дефолты (в инстансе он должен быть)"
fi
READONLY_ZONES="${READONLY_ZONES:-dist}"
WATCH_DIR="${WATCH_DIR:-src}"

# 2. guard существует и исполняем
GUARD="${GUARDS}/block-zones.sh"
if [[ -x "$GUARD" ]]; then
  ok "block-zones.sh исполняем"
else
  fail "block-zones.sh не найден или не исполняем: ${GUARD}"
fi

# 3. guard блокирует readonly зону
FIRST_ZONE=$(echo "$READONLY_ZONES" | awk '{print $1}')
TEST_FILE="${REPO_ROOT}/${FIRST_ZONE}/test-verify.txt"

GUARD_OUT=$(echo "{\"tool_input\": {\"path\": \"${TEST_FILE}\"}}" | bash "$GUARD" 2>&1) || GUARD_EXIT=$?
GUARD_EXIT=${GUARD_EXIT:-0}

if [[ "$GUARD_EXIT" -eq 2 ]]; then
  ok "guard блокирует readonly зону '${FIRST_ZONE}' (exit 2)"
else
  fail "guard НЕ заблокировал readonly зону '${FIRST_ZONE}' (exit ${GUARD_EXIT})"
fi

# 4. guard пропускает разрешённый путь
ALLOWED_FILE="${REPO_ROOT}/${WATCH_DIR}/some-component.tsx"
GUARD_OUT2=$(echo "{\"tool_input\": {\"path\": \"${ALLOWED_FILE}\"}}" | bash "$GUARD" 2>&1) || GUARD_EXIT2=$?
GUARD_EXIT2=${GUARD_EXIT2:-0}

if [[ "$GUARD_EXIT2" -ne 2 ]]; then
  ok "guard пропускает разрешённый путь '${WATCH_DIR}' (exit ${GUARD_EXIT2})"
else
  fail "guard ошибочно блокирует разрешённый путь '${WATCH_DIR}'"
fi

# 5. дочерние sensor-хуки на месте
for hook in run-test-hook.sh run-pytest-hook.sh; do
  if [[ -x "${GUARDS}/${hook}" ]]; then
    ok "${hook} исполняем"
  else
    fail "${hook} не найден или не исполняем: ${GUARDS}/${hook}"
  fi
done

# 6. load-context.sh (опционально)
if [[ -f "${REPO_ROOT}/scripts/load-context.sh" || -f "${REPO_ROOT}/skeleton/scripts/load-context.sh" ]]; then
  ok "load-context.sh найден (опционально)"
else
  skip "load-context.sh не найден — SessionStart без долгосрочной памяти"
fi

# 7. /note capture skill (append.sh исполняем)
NOTE_APPEND="${CLAUDE_DIR}/skills/note/append.sh"
if [[ -x "$NOTE_APPEND" ]]; then
  ok "/note capture skill: append.sh исполняем"
else
  fail "/note append.sh не найден или не исполняем: ${NOTE_APPEND}"
fi

# 8. sensor-диспетчер
DISPATCH="${GUARDS}/sensor.sh"
if [[ -x "$DISPATCH" ]]; then
  ok "sensor.sh (диспетчер) исполняем"
else
  fail "sensor.sh не найден или не исполняем: ${DISPATCH}"
fi

# 9. диспетчер молчит на неизвестном расширении и не падает
DISPATCH_EXIT=0
echo "{\"tool_input\": {\"file_path\": \"${REPO_ROOT}/README.md\"}}" | bash "$DISPATCH" >/dev/null 2>&1 || DISPATCH_EXIT=$?
if [[ "$DISPATCH_EXIT" -eq 0 ]]; then
  ok "sensor.sh fail-open на нерелевантном файле (exit 0)"
else
  fail "sensor.sh упал на нерелевантном файле (exit ${DISPATCH_EXIT})"
fi

# 10-12. Роутинг sensor'а (фикстура: временная репа).
# Проверяем три сценария:
#   - монорепа JS: тесты запускаются в БЛИЖАЙШЕМ воркспейсе, не в корне
#   - Python: тесты в воркспейсе с pyproject.toml
#   - legacy-конфиг (одностековый TEST_CMD, без JS_*): продолжает работать
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "${FIXTURE}/apps/web/src" "${FIXTURE}/apps/api/tests"
: > "${FIXTURE}/package.json"
: > "${FIXTURE}/apps/web/package.json"
: > "${FIXTURE}/apps/web/src/Btn.tsx"
: > "${FIXTURE}/apps/api/pyproject.toml"
: > "${FIXTURE}/apps/api/svc.py"
: > "${FIXTURE}/apps/api/tests/test_svc.py"

# Конфиг фикстуры в том же ${VAR:-} стиле, что и настоящий: иначе source затрёт env.
cat > "${FIXTURE}/.harness.conf" <<'CONF'
PY_WATCH_DIR="${PY_WATCH_DIR:-}"
PY_TEST_CMD="${PY_TEST_CMD:-}"
PY_TEST_WORKDIR="${PY_TEST_WORKDIR:-}"
PYTEST_MODE="${PYTEST_MODE:-map}"
JS_WATCH_DIR="${JS_WATCH_DIR:-}"
JS_TEST_CMD="${JS_TEST_CMD:-}"
JS_TEST_WORKDIR="${JS_TEST_WORKDIR:-}"
WATCH_DIR="${WATCH_DIR:-}"
TEST_CMD="${TEST_CMD:-}"
TEST_WORKDIR="${TEST_WORKDIR:-}"
CONF

# Пробник вместо реального раннера: пишет свой cwd и молчит (mute the green).
# $PWD, а не `pwd -P`: mktemp на macOS отдаёт путь через симлинк (/var → /private/var),
# и физический путь не совпал бы с ожидаемым.
cat > "${FIXTURE}/probe.sh" <<'PROBE'
echo "$PWD" > "$(dirname "$0")/probe-out"
PROBE

probe_workspace() { # $1 = изменённый файл, $2 = имя переменной с командой
  rm -f "${FIXTURE}/probe-out"
  echo "{\"tool_input\": {\"file_path\": \"${FIXTURE}/${1}\"}}" \
    | env REPO_ROOT="$FIXTURE" "${2}=bash ${FIXTURE}/probe.sh" \
      bash "$DISPATCH" >/dev/null 2>&1 || true
  [[ -f "${FIXTURE}/probe-out" ]] && cat "${FIXTURE}/probe-out" || echo "<не запускался>"
}

JS_WS="$(probe_workspace "apps/web/src/Btn.tsx" JS_TEST_CMD)"
if [[ "$JS_WS" == "${FIXTURE}/apps/web" ]]; then
  ok "sensor.sh: .tsx → тесты в ближайшем JS-воркспейсе (apps/web)"
else
  fail "sensor.sh: .tsx ушёл не в тот воркспейс: ожидалось ${FIXTURE}/apps/web, получено ${JS_WS}"
fi

PY_WS="$(probe_workspace "apps/api/svc.py" PY_TEST_CMD)"
if [[ "$PY_WS" == "${FIXTURE}/apps/api" ]]; then
  ok "sensor.sh: .py → тесты в ближайшем Python-воркспейсе (apps/api)"
else
  fail "sensor.sh: .py ушёл не в тот воркспейс: ожидалось ${FIXTURE}/apps/api, получено ${PY_WS}"
fi

# legacy: одностековый конфиг (TEST_CMD, JS_* пусты) — файл в корневом воркспейсе
: > "${FIXTURE}/root-file.ts"
LEGACY_WS="$(probe_workspace "root-file.ts" TEST_CMD)"
if [[ "$LEGACY_WS" == "${FIXTURE}" ]]; then
  ok "sensor.sh: legacy TEST_CMD без JS_* работает (корневой воркспейс)"
else
  fail "sensor.sh: legacy TEST_CMD сломан: ожидалось ${FIXTURE}, получено ${LEGACY_WS}"
fi

echo ""
echo "=== Результат: ${PASS} pass / ${FAIL} fail ==="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
