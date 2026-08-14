#!/usr/bin/env bash
# Пути CORE-слоя относительно корня инстанса. Только это синкается.
CORE_PATHS=(
  ".claude/guards/block-zones.sh"
  ".claude/guards/gate.sh"
  ".claude/guards/run-test-hook.sh"
  ".claude/guards/nudge.sh"
  ".claude/guards/pre-push.sh"
  ".claude/skills/note/append.sh"
  ".claude/skills/note/SKILL.md"
  ".claude/skills/end-session/SKILL.md"
  ".claude/skills/task/SKILL.md"
  ".claude/skills/plan/SKILL.md"
  ".claude/skills/rename/SKILL.md"
  ".claude/rules/common/git.md"
  ".claude/rules/common/testing.md"
  ".claude/rules/common/workflow.md"
  ".claude/rules/common/methodology-routing.md"
  ".claude/rules/common/context-hygiene.md"
  ".claude/rules/common/comments.md"
  "docs/specs/_template.md"
  # Скрипты, на которые ссылаются правила и settings.json.
  "scripts/log-append.sh"
  "scripts/check-ac-refs.sh"
  "scripts/check-diff-coverage.sh"
  "scripts/load-context.sh"
  # Смоук самого харнесса. Живёт с харнессом, а не в репе-шаблоне: проверять нечего там,
  # где .claude/guards/ и .harness.conf отсутствуют.
  "scripts/verify-harness.sh"
)
