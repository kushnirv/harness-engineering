#!/usr/bin/env bash
# Smoke test: проверяет что харнесс работает как задумано.
# Запускать после setup и после любого рефактора структуры.
#
# Гонять В ИНСТАНСЕ (проект с раскатанным харнессом), не в репе-шаблоне: тут
# нет ни .harness.conf, ни .claude/guards/, и проверять нечего. Запуск не там
# даёт exit 3 «ничего не проверено» — не зелёный (нечего проверять ≠ всё живо)
# и не красный (кривой запуск ≠ поломанный харнесс).
#
# Тесты:
#   1. .harness.conf существует и читается
#   2. guard исполняем
#   3. guard блокирует readonly зону (exit 2)
#   4. guard пропускает разрешённый путь (exit != 2)
#   5. sensor существует и исполняем
#   6. load-context.sh существует (опционально)
#   7. gate: защита от петли держит (stop_hook_active → exit 0 без прогона GATE_CMD)
#   8. /note capture: append.sh исполняем

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

# NB: PASS=$((...)) не ((PASS++)) — `((expr))` возвращает exit 1 когда результат 0,
# и под `set -e` это роняет скрипт на первом же ok()/fail() (счётчик стартует с 0).
ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== verify-harness ==="
echo ""

# 0. Запущен не в инстансе, а в самом шаблоне? Отдельный выход. Раньше тут был FAIL,
# то есть шаблон вечно «красный» на собственной проверке, хотя ломать в нём нечего.
# Признак шаблона — `.harness.conf.example` рядом (в инстанс он не доставляется ни
# одним каналом) или каталог `skeleton/` выше.
CONF="${REPO_ROOT}/.harness.conf"
if [[ ! -f "$CONF" ]] \
   && { [[ -f "${REPO_ROOT}/.harness.conf.example" ]] || [[ -d "${REPO_ROOT}/skeleton" ]]; }; then
  echo "  [SKIP] это шаблон харнесса, не проект — .harness.conf нет, раскатывать нечего."
  echo ""
  echo "Ничего не проверено. Смотри по назначению:"
  echo "  инстанс    → cd <проект> && bash scripts/verify-harness.sh"
  echo "  сам шаблон → bash scripts/verify-bootstrap.sh    (раскатка bootstrap'ом)"
  echo "               bash scripts/verify-copier.sh       (раскатка Copier'ом)"
  echo "               bash scripts/check-docs-reality.sh  (доки против кода)"
  exit 3
fi

# 1. .harness.conf
if [[ -f "$CONF" ]]; then
  source "$CONF"
  ok ".harness.conf найден и читается"
else
  fail ".harness.conf не найден в ${REPO_ROOT}"
  echo ""
  echo "Создай его из примера в шаблоне харнесса:"
  echo "  cp <harness-template>/skeleton/.harness.conf.example .harness.conf"
  echo "  # Заполни WATCH_DIR, READONLY_ZONES, TEST_CMD, GATE_CMD"
  exit 1
fi

# 2. guard существует и исполняем
GUARD="${REPO_ROOT}/.claude/guards/block-zones.sh"
if [[ -x "$GUARD" ]]; then
  ok "block-zones.sh исполняем"
else
  fail "block-zones.sh не найден или не исполняем: ${GUARD}"
fi

# 3. guard блокирует readonly зону
if [[ -n "${READONLY_ZONES:-}" ]]; then
  FIRST_ZONE=$(echo "$READONLY_ZONES" | awk '{print $1}')
  TEST_FILE="${REPO_ROOT}/${FIRST_ZONE}/test-verify.txt"

  GUARD_OUT=$(echo "{\"tool_input\": {\"path\": \"${TEST_FILE}\"}}" | bash "$GUARD" 2>&1) || GUARD_EXIT=$?
  GUARD_EXIT=${GUARD_EXIT:-0}

  if [[ "$GUARD_EXIT" -eq 2 ]]; then
    ok "guard блокирует readonly зону '${FIRST_ZONE}' (exit 2)"
  else
    fail "guard НЕ заблокировал readonly зону '${FIRST_ZONE}' (exit ${GUARD_EXIT})"
  fi
else
  fail "READONLY_ZONES не задан в .harness.conf"
fi

# 4. guard пропускает разрешённый путь
if [[ -n "${WATCH_DIR:-}" ]]; then
  ALLOWED_FILE="${REPO_ROOT}/${WATCH_DIR}/some-component.vue"
  GUARD_OUT2=$(echo "{\"tool_input\": {\"path\": \"${ALLOWED_FILE}\"}}" | bash "$GUARD" 2>&1) || GUARD_EXIT2=$?
  GUARD_EXIT2=${GUARD_EXIT2:-0}

  if [[ "$GUARD_EXIT2" -ne 2 ]]; then
    ok "guard пропускает разрешённый путь '${WATCH_DIR}' (exit ${GUARD_EXIT2})"
  else
    fail "guard ошибочно блокирует разрешённый путь '${WATCH_DIR}'"
  fi
else
  fail "WATCH_DIR не задан в .harness.conf"
fi

# 5. sensor существует
SENSOR="${REPO_ROOT}/.claude/guards/run-test-hook.sh"
if [[ -x "$SENSOR" ]]; then
  ok "run-test-hook.sh исполняем"
else
  fail "run-test-hook.sh не найден или не исполняем: ${SENSOR}"
fi

# 6. load-context.sh (опционально)
LOADER="${REPO_ROOT}/scripts/load-context.sh"
if [[ -f "$LOADER" ]]; then
  ok "load-context.sh найден (опционально)"
else
  echo "  [SKIP] load-context.sh не найден — SessionStart без долгосрочной памяти"
fi

# 7. gate: защита от петли. На stop_hook_active gate обязан выйти 0 НЕ запуская
# GATE_CMD — иначе Stop-хук уходит в бесконечный цикл.
#
# Гоняем на ПОДСТАВНОМ REPO_ROOT с `GATE_CMD="exit 9"`, а не на конфиге проекта.
# Причина: на настоящем конфиге исход один и тот же и когда защита работает, и когда
# её нет — GATE_CMD проходит, gate возвращает 0. Проверка была бы вакуумной (проверено
# мутацией: защиту убрал, тест остался зелёным). Команда, которая гарантированно падает,
# делает две ветки различимыми: 0 = не запускалась, 2 = запустилась.
GATE="${REPO_ROOT}/.claude/guards/gate.sh"
if [[ -x "$GATE" ]]; then
  GATE_SANDBOX="$(mktemp -d)"
  echo 'GATE_CMD="exit 9"' > "${GATE_SANDBOX}/.harness.conf"
  GATE_EXIT=0
  printf '%s' '{"stop_hook_active": true}' \
    | REPO_ROOT="$GATE_SANDBOX" bash "$GATE" >/dev/null 2>&1 || GATE_EXIT=$?
  rm -rf "$GATE_SANDBOX"
  if [[ "$GATE_EXIT" -eq 0 ]]; then
    ok "gate.sh: защита от петли держит (stop_hook_active → GATE_CMD не запущен)"
  else
    fail "gate.sh на stop_hook_active вернул ${GATE_EXIT}: команда запустилась, Stop-хук уйдёт в цикл"
  fi
  if [[ -z "${GATE_CMD:-}" ]]; then
    echo "  [SKIP] GATE_CMD в .harness.conf пуст — Ярус 2 ничего не проверяет"
  fi
else
  fail "gate.sh не найден или не исполняем: ${GATE}"
fi

# 8. /note capture skill (append.sh исполняем).
# Путь именно в .claude/ проекта: раньше тут стоял ${REPO_ROOT}/skeleton/... — в любом
# инстансе такой папки нет, и проверка краснела всегда.
NOTE_APPEND="${REPO_ROOT}/.claude/skills/note/append.sh"
if [[ -x "$NOTE_APPEND" ]]; then
  ok "/note capture skill: append.sh исполняем"
else
  fail "/note append.sh не найден или не исполняем: ${NOTE_APPEND}"
fi

echo ""
echo "=== Результат: ${PASS} pass / ${FAIL} fail ==="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
