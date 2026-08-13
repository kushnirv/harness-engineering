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

# Свежесть отчёта. Покрытие, посчитанное до последней правки, описывает прошлый код: гейт
# отчитался бы зелёным по коду, которого уже нет. Сравниваем со самым свежим изменённым файлом.
NEWEST=""
# core.quotepath=false и здесь: без него путь с юникодом приходит в кавычках с escape-
# последовательностями, файл не находится, NEWEST остаётся пустым — и проверка свежести молча
# не выполняется. Ровно тот же дефект, что и в парсере diff ниже.
for f in $(git -C "$REPO_ROOT" -c core.quotepath=false diff --name-only "$MERGE_BASE" 2>/dev/null); do
  [ -f "${REPO_ROOT}/$f" ] || continue
  [ -z "$NEWEST" ] && NEWEST="${REPO_ROOT}/$f"
  [ "${REPO_ROOT}/$f" -nt "$NEWEST" ] && NEWEST="${REPO_ROOT}/$f"
done
if [ -n "$NEWEST" ] && [ "$NEWEST" -nt "$COVERAGE_REPORT" ]; then
  warn "отчёт покрытия старее изменённых файлов ($COVERAGE_REPORT) — прогони тесты с coverage заново"
  warn "покрытие НЕ проверено: судить по устаревшему отчёту хуже, чем не судить"
  exit 0
fi

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
# Список файлов дерева: без него неоднозначность записи отчёта не определить. Запись
# `src/utils.py` подходит и `frontend/src/utils.py`, и `backend/src/utils.py` — какая из них
# посчитана, по отчёту не видно, и судить нельзя ни по одной.
TREE_LIST="$(mktemp)"
trap 'rm -f "$TREE_LIST"' EXIT
git -C "$REPO_ROOT" ls-files > "$TREE_LIST" 2>/dev/null || : > "$TREE_LIST"

RESULT="$(
  git -C "$REPO_ROOT" -c core.quotepath=false diff --unified=0 --no-color "$MERGE_BASE" -- . \
  | COVERAGE_XML="$COVERAGE_REPORT" TREE_LIST="$TREE_LIST" python3 -c '
import os, re, sys, xml.etree.ElementTree as ET

# 1. Изменённые строки из diff: {путь: {номера}}
changed, path = {}, None
for raw in sys.stdin:
    if raw.startswith("+++ "):
        p = raw[4:].strip()
        # Путь может прийти в кавычках: git цитирует имена с пробелами и табами даже при
        # core.quotepath=false. Без снятия кавычек файл не сойдётся ни с одной записью отчёта
        # и молча выпадет из проверки.
        if len(p) > 1 and p[0] == '"' and p[-1] == '"':
            p = p[1:-1]
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

# Совпадение только по ГРАНИЦЕ сегмента пути: `endswith` без этого условия склеивает
# `frontend/src/utils.py` с записью `src/utils.py` из другого пакета, и строки судятся по чужой
# таблице покрытия. Хвост `utils.py` тоже совпал бы с `my_utils.py`.
def seg_suffix(long, short):
    return long == short or long.endswith("/" + short)

AMBIGUOUS = set()

def candidates(p):
    if p in cov: return [p]
    return [fn for fn in cov if seg_suffix(p, fn) or seg_suffix(fn, p)]

# Спорные записи отчёта считаются по ВСЕМУ дереву, а не по изменённым файлам. Иначе защита не
# работает в самом частом случае: изменён один `frontend/src/utils.py`, в дереве есть ещё
# `backend/src/utils.py`, а в отчёте одна запись `src/utils.py` — конфликт есть, но среди
# изменённых файлов он не виден, и строки судятся по чужому покрытию.
try:
    tree = [ln.strip() for ln in open(os.environ["TREE_LIST"]) if ln.strip()]
except OSError:
    tree = []

_owner = {}
for _f in tree:
    for _fn in candidates(_f):
        if _fn == _f: continue      # точное совпадение однозначно по определению
        _owner.setdefault(_fn, []).append(_f)

_contested = {fn for fn, fs in _owner.items() if len(fs) > 1}

def lookup(p):
    if p in cov: return cov[p]      # точный путь — сомнений нет
    cands = [fn for fn in candidates(p) if fn not in _contested]
    if not cands:
        if candidates(p):           # кандидаты были, но все спорные
            AMBIGUOUS.add(p)
        return None
    if len(cands) > 1:
        AMBIGUOUS.add(p)
        return None
    return cov[cands[0]]

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
    print("NOLINES 0 0")
    for a in sorted(AMBIGUOUS)[:20]:
        print("AMBIG " + a)
    sys.exit(0)
pct = int(covered * 100 / total)
print("OK %d %d" % (pct, total))
for m in misses[:20]:
    print("MISS " + m)
for a in sorted(AMBIGUOUS)[:20]:
    print("AMBIG " + a)
' 2>/dev/null
)"

STATUS="$(printf '%s' "$RESULT" | head -1 | awk '{print $1}')"
PCT="$(printf '%s' "$RESULT" | head -1 | awk '{print $2}')"
TOTAL="$(printf '%s' "$RESULT" | head -1 | awk '{print $3}')"

case "${STATUS:-EMPTY}" in
  NOCHANGE) warn "против $DIFF_COVER_BASE изменений нет — проверять нечего"; exit 0 ;;
  NOLINES)
    warn "в изменениях нет исполняемых строк из отчёта покрытия — проверка пропущена"
    printf '%s\n' "$RESULT" | sed -n 's/^AMBIG /  неоднозначный путь (не сужу): /p' >&2
    exit 0 ;;
  OK)       : ;;
  *)        warn "не смог разобрать отчёт покрытия ($COVERAGE_REPORT) — проверка пропущена"; exit 0 ;;
esac

say "diff-coverage: ${PCT}% из ${TOTAL} изменённых строк покрыто (порог ${BASELINE}%)"
printf '%s\n' "$RESULT" | sed -n 's/^AMBIG /diff-coverage: неоднозначный путь, файл не судится: /p' >&2

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
