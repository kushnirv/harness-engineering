#!/usr/bin/env bash
# Читает лог загрузок инструкций и отвечает на вопрос, который иначе решается на веру:
# какие правила доехали до контекста и по какой причине.
#
# Usage:  scripts/instructions-report.sh [--verdict]
#   --verdict   короткий вывод: фильтрует ли `paths:` (см. критерий ниже)
#
# Критерий проверки фильтрации: у scoped-правила причина загрузки обязана быть
# `path_glob_match`, а не `session_start`. Если scoped-правило приходит на старте — глоб
# не фильтрует. Если не приходит вообще ни с одной причиной — правило мёртвое, и это
# хуже нефильтрующего глоба: оно выглядит рабочим, но в контекст не попадает никогда.
set -uo pipefail

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || pwd)}"
CONF="${REPO_ROOT}/.harness.conf"
# shellcheck source=/dev/null
[[ -f "$CONF" ]] && . "$CONF"
LOG="${REPO_ROOT}/${METRICS_DIR:-docs/metrics}/instructions-load.log"
RULES_DIR="${REPO_ROOT}/.claude/rules"

if [[ ! -f "$LOG" ]]; then
  printf 'Лога нет: %s\n' "${LOG#"$REPO_ROOT"/}"
  printf 'Хук InstructionsLoaded пишет его при загрузке инструкций. Пустой лог означает либо\n'
  printf 'что сессия не стартовала после установки хука, либо что хук не сработал.\n'
  exit 1
fi

VERDICT_ONLY=0
[[ "${1:-}" == "--verdict" ]] && VERDICT_ONLY=1

# Какие правила объявлены scoped — считаем по файлам, а не по памяти.
scoped_files() {
  local f
  while IFS= read -r f; do
    [[ "$(head -1 "$f")" == "---" ]] || continue
    head -20 "$f" | grep -qE '^paths:' || continue
    printf '%s\n' "${f#"$REPO_ROOT"/}"
  done < <(find "$RULES_DIR" -name '*.md' 2>/dev/null | LC_ALL=C sort)
}

if [[ "$VERDICT_ONLY" -eq 0 ]]; then
  printf '=== загрузки по причине ===\n'
  awk -F'\t' '{ c[$2]++ } END { for (r in c) printf "  %-18s %s\n", r, c[r] }' "$LOG" | LC_ALL=C sort
  printf '\n=== файлы, пришедшие в контекст ===\n'
  awk -F'\t' '{ key = $4 "\t" $2; if (!(key in seen)) { seen[key] = 1; printf "  %-42s %s\n", $4, $2 } }' "$LOG" \
    | LC_ALL=C sort -u
  printf '\n'
fi

printf '=== вердикт по scoped-правилам ===\n'
rc=0
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  reasons="$(awk -F'\t' -v f="$rel" '$4 == f { print $2 }' "$LOG" | LC_ALL=C sort -u | tr '\n' ' ')"
  if [[ -z "$reasons" ]]; then
    printf '  %-42s НЕ ЗАГРУЖАЛОСЬ НИ РАЗУ — правило мёртвое либо ни один совпавший файл не читали\n' "$rel"
    rc=1
  elif [[ "$reasons" == *session_start* ]]; then
    printf '  %-42s приходит на старте (%s) — глоб НЕ фильтрует\n' "$rel" "${reasons% }"
    rc=1
  else
    printf '  %-42s %s — фильтрация работает\n' "$rel" "${reasons% }"
  fi
done < <(scoped_files)

exit "$rc"
