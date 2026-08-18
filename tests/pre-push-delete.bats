#!/usr/bin/env bats
# Поведение pre-push на push'ах, которые ничего не отправляют.
#
# Зачем: `git push --delete <ветка>` не несёт ни одного объекта, а полный Ярус 3 отрабатывал
# на нём целиком — замер 18.08, ~50 секунд на удаление ветки. Дорогая проверка, срабатывающая
# там, где проверять нечего, выключается вместе с полезными случаями.
#
# Формат stdin pre-push (git): `<local ref> <local sha> <remote ref> <remote sha>` на каждый ref;
# у удаления local sha из нулей. Тест закрепляет три ветки: чистое удаление пропускается,
# обычный и СМЕШАННЫЙ push проверяются. Третья важнее первых двух: `push --delete a master`
# отправляет объекты, и пропуск там был бы дырой, а не оптимизацией.
#
# Имена латиницей намеренно — bats 1.14 ломается на кириллице в заголовке @test.

setup() {
  GUARD="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)/skeleton/.claude/guards/pre-push.sh"
  ZERO=0000000000000000000000000000000000000000
  LIVE=abc1230000000000000000000000000000000000
  # Песочница без gate.sh: если ранний выход НЕ сработал, скрипт попытается позвать гейт и
  # споткнётся. Различаем именно «дошёл до гейта / не дошёл» — это и есть предмет теста.
  SANDBOX="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$SANDBOX/.claude/guards"
  printf 'GATE_CMD="true"\n' > "$SANDBOX/.harness.conf"
  cp "$GUARD" "$SANDBOX/.claude/guards/pre-push.sh"
  ( cd "$SANDBOX" && git init -q . )
}

@test "delete-only push skips tier 3" {
  run bash -c "cd '$SANDBOX' && printf '(delete) $ZERO refs/heads/x $LIVE\n' | sh .claude/guards/pre-push.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"только удаляет"* ]]
  [[ "$output" != *"gate.sh"* ]]
}

@test "normal push does not skip" {
  run bash -c "cd '$SANDBOX' && printf 'refs/heads/x $LIVE refs/heads/x $ZERO\n' | sh .claude/guards/pre-push.sh"
  [[ "$output" != *"только удаляет"* ]]
}

@test "mixed push with one live ref does not skip" {
  run bash -c "cd '$SANDBOX' && { printf '(delete) $ZERO refs/heads/y $LIVE\n'; printf 'refs/heads/x $LIVE refs/heads/x $ZERO\n'; } | sh .claude/guards/pre-push.sh"
  [[ "$output" != *"только удаляет"* ]]
}

@test "empty stdin does not skip - manual run must still check" {
  run bash -c "cd '$SANDBOX' && sh .claude/guards/pre-push.sh </dev/null"
  [[ "$output" != *"только удаляет"* ]]
}
