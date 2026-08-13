#!/usr/bin/env bash
# Покрытие ИЗМЕНЁННЫХ строк с ratchet-порогом. Ярус 3 (pre-push).
#
# Usage: bash scripts/check-diff-coverage.sh [--quiet]
#
# Почему diff, а не пары «файл ↔ тест». Проверка «у изменённого исходника есть парный тест»
# краснеет на рефакторинге, переименовании, правке конфигов и генерённом коде — и лечится это
# только allowlist'ами и флагом-обходом, который в итоге ставят всегда. Скоуп на изменённые
# строки снимает проблему без исключений: правка без новой логики не добавляет непокрытых строк
# и проходит бесплатно. Так считают diff-cover и Codecov patch coverage.
#
# Почему НЕ «тест написан раньше кода». Такой проверки нет ни у одного найденного инструмента, и
# причина структурная: хук видит состояние дерева, а не последовательность появления строк, а
# rebase и squash стирают порядок задним числом. Обещать порядок — значит обещать невозможное.
#
# Bypass-флага здесь нет намеренно. Порог поднимается осознанной правкой файла, которая видна в
# ревью; флаг «пропустить» ставят уставшими на третий день и больше не снимают.
#
# Зависимостей нет: Cobertura XML разбирается python3, который и так нужен gate.sh.

set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# shellcheck source=/dev/null
[ -f "${REPO_ROOT}/.harness.conf" ] && . "${REPO_ROOT}/.harness.conf"

COVERAGE_REPORT="${COVERAGE_REPORT:-}"
DIFF_COVER_BASE="${DIFF_COVER_BASE:-}"
DIFF_COVER_BASELINE="${DIFF_COVER_BASELINE:-${REPO_ROOT}/scripts/check-diff-coverage.baseline}"

say()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$1"; }
warn() { printf 'diff-coverage: %s\n' "$1" >&2; }

# --- Ненастроенность: fail-open, но вслух ------------------------------------------
if [ -z "$COVERAGE_REPORT" ]; then
  warn "COVERAGE_REPORT не задан в .harness.conf — покрытие изменённых строк не проверяется"
  exit 0
fi

if [ ! -f "${REPO_ROOT}/${COVERAGE_REPORT}" ] && [ ! -f "$COVERAGE_REPORT" ]; then
  warn "отчёта покрытия нет: $COVERAGE_REPORT — сначала прогон тестов с coverage, потом эта проверка"
  exit 0
fi
[ -f "$COVERAGE_REPORT" ] || COVERAGE_REPORT="${REPO_ROOT}/${COVERAGE_REPORT}"

# База сравнения. Дефолт — upstream текущей ветки, иначе точка ветвления от master/main.
if [ -z "$DIFF_COVER_BASE" ]; then
  DIFF_COVER_BASE="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
fi
if [ -z "$DIFF_COVER_BASE" ]; then
  for b in master main; do
    git -C "$REPO_ROOT" rev-parse --verify -q "$b" >/dev/null 2>&1 && { DIFF_COVER_BASE="$b"; break; }
  done
fi
if [ -z "$DIFF_COVER_BASE" ]; then
  warn "не нашёл базу сравнения (нет upstream, нет master/main) — задай DIFF_COVER_BASE"
  exit 0
fi

MERGE_BASE="$(git -C "$REPO_ROOT" merge-base HEAD "$DIFF_COVER_BASE" 2>/dev/null || echo "$DIFF_COVER_BASE")"

# --- Порог -----------------------------------------------------------------------
BASELINE=0
if [ -f "$DIFF_COVER_BASELINE" ]; then
  BASELINE="$(tr -dc '0-9' < "$DIFF_COVER_BASELINE")"
  [ -z "$BASELINE" ] && { warn "в файле порога нет числа: $DIFF_COVER_BASELINE — считаю 0"; BASELINE=0; }
else
  warn "нет файла порога: $DIFF_COVER_BASELINE — считаю 0"
fi

# --- Считаем ---------------------------------------------------------------------
# Строки берём из `git diff --unified=0`: нужны номера ДОБАВЛЕННЫХ и изменённых строк, удалённые
# покрывать нечем. Покрытие — из Cobertura (line hits). Пересечение и есть предмет проверки.
RESULT="$(
  git -C "$REPO_ROOT" diff --unified=0 --no-color "$MERGE_BASE" -- . \
  | COVERAGE_XML="$COVERAGE_REPORT" REPO="$REPO_ROOT" python3 -c '
import os, re, sys, xml.etree.ElementTree as ET

# 1. Изменённые строки из diff: {путь: {номера}}
changed, path = {}, None
for raw in sys.stdin:
    if raw.startswith("+++ "):
        p = raw[4:].strip()
        path = None if p == "/dev/null" else re.sub(r"^b/", "", p)
    elif raw.startswith("@@") and path:
        m = re.search(r"\+(\d+)(?:,(\d+))?", raw)
        if m:
            start = int(m.group(1)); count = int(m.group(2) or 1)
            changed.setdefault(path, set()).update(range(start, start + count))

if not changed:
    print("NOCHANGE 0 0"); sys.exit(0)

# 2. Покрытие из Cobertura. filename в отчёте может быть относительным к своему корню —
# сопоставляем по суффиксу пути, иначе отчёт и diff не сойдутся ни на одном файле.
tree = ET.parse(os.environ["COVERAGE_XML"])
cov = {}
for cls in tree.iter("class"):
    fn = cls.get("filename") or ""
    for ln in cls.iter("line"):
        try:
            num = int(ln.get("number")); hits = int(ln.get("hits") or 0)
        except (TypeError, ValueError):
            continue
        cov.setdefault(fn, {})[num] = hits

def lookup(p):
    if p in cov: return cov[p]
    for fn in cov:
        if p.endswith(fn) or fn.endswith(p): return cov[fn]
    return None

total = covered = 0
misses = []
for p, lines in sorted(changed.items()):
    table = lookup(p)
    if table is None:      # файл вне отчёта (не код или не собирался) — не судим
        continue
    for n in sorted(lines):
        if n not in table: # строка не исполняемая (комментарий, пустая) — не судим
            continue
        total += 1
        if table[n] > 0: covered += 1
        else: misses.append("%s:%d" % (p, n))

if total == 0:
    print("NOLINES 0 0"); sys.exit(0)
pct = int(covered * 100 / total)
print("OK %d %d" % (pct, total))
for m in misses[:20]:
    print("MISS " + m)
' 2>/dev/null
)"

STATUS="$(printf '%s' "$RESULT" | head -1 | awk '{print $1}')"
PCT="$(printf '%s' "$RESULT" | head -1 | awk '{print $2}')"
TOTAL="$(printf '%s' "$RESULT" | head -1 | awk '{print $3}')"

case "${STATUS:-EMPTY}" in
  NOCHANGE) warn "против $DIFF_COVER_BASE изменений нет — проверять нечего"; exit 0 ;;
  NOLINES)  warn "в изменениях нет исполняемых строк из отчёта покрытия — проверка пропущена"; exit 0 ;;
  OK)       : ;;
  *)        warn "не смог разобрать отчёт покрытия ($COVERAGE_REPORT) — проверка пропущена"; exit 0 ;;
esac

say "diff-coverage: ${PCT}% из ${TOTAL} изменённых строк покрыто (порог ${BASELINE}%)"

if [ "$PCT" -lt "$BASELINE" ]; then
  printf 'ПОКРЫТИЕ ИЗМЕНЕНИЙ %s%% ПРИ ПОРОГЕ %s%% — дыру внёс этот заход.\n' "$PCT" "$BASELINE" >&2
  printf '%s\n' "$RESULT" | sed -n 's/^MISS /  без теста: /p' >&2
  printf 'Либо покрой изменения тестом, либо осознанно опусти порог в %s.\n' "$DIFF_COVER_BASELINE" >&2
  exit 1
fi

if [ "$PCT" -gt "$BASELINE" ]; then
  say "порог можно поднять: ${BASELINE}% → ${PCT}% (ratchet двигается только в сторону строгости)"
fi

exit 0
