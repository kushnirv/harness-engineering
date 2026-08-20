#!/usr/bin/env bats
# Поведение ratchet в scripts/lint-shell.sh.
#
# Зачем именно это: ratchet — единственная часть гейта, которая решает «красный или зелёный».
# Проверялась она вручную мутацией 18.08, и первая мутация оказалась негодной — прошла
# насквозь, потому что shellcheck не флагует расширение переменной с безопасным литералом.
# Тест закрепляет проверенное поведение, чтобы вывод «ratchet работает» не приходилось
# добывать заново руками.
#
# Реальные файлы репозитория НЕ мутируются: порог подменяется через SC_BASELINE_FILE,
# который скрипт читает из окружения.
#
# ИМЕНА ТЕСТОВ ЛАТИНИЦЕЙ НАМЕРЕННО: bats 1.14 строит имя shell-функции из заголовка @test и
# на кириллице ломается — «unknown test name», прогон отчитывается «Executed 0 instead of 5».
# Ноль выполненных тестов при внешне успешном выводе, замер 18.08.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export SC_BASELINE_FILE="${BATS_TEST_TMPDIR}/baseline"
  # Фактическое число замечаний — считаем тем же способом, что и скрипт.
  FOUND=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$(head -1 "$f")" in
      *"env sh"*|*"/sh") SH="sh" ;;
      *)                 SH="bash" ;;
    esac
    # `|| true` обязателен: grep без совпадений выходит с 1, а bats гоняет setup под `set -e` —
    # файл без замечаний ронял бы весь тест. Ноль находок это ответ, не ошибка.
    N="$(shellcheck --severity=info --shell="$SH" --format=gcc "$f" 2>/dev/null | grep -c . || true)"
    FOUND=$((FOUND + N))
  done < <(git -C "$REPO_ROOT" ls-files '*.sh')
  export FOUND
}

@test "baseline equals actual - gate green" {
  printf '%s\n' "$FOUND" > "$SC_BASELINE_FILE"
  run bash "${REPO_ROOT}/scripts/lint-shell.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"порог держится"* ]]
}

@test "findings above baseline - gate red" {
  printf '%s\n' "$((FOUND - 1))" > "$SC_BASELINE_FILE"
  run bash "${REPO_ROOT}/scripts/lint-shell.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"РОСТ"* ]]
}

@test "findings below baseline - green, asks to lower" {
  printf '%s\n' "$((FOUND + 5))" > "$SC_BASELINE_FILE"
  run bash "${REPO_ROOT}/scripts/lint-shell.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"опусти порог"* ]]
}

@test "missing baseline file - counted as zero, said aloud" {
  rm -f "$SC_BASELINE_FILE"
  run bash "${REPO_ROOT}/scripts/lint-shell.sh"
  [[ "$output" == *"нет файла порога"* ]]
}

@test "garbage in baseline file - said aloud, not silent zero" {
  printf 'не число\n' > "$SC_BASELINE_FILE"
  run bash "${REPO_ROOT}/scripts/lint-shell.sh"
  [[ "$output" == *"нет числа"* ]]
}
