#!/usr/bin/env bash
# Обратный канал: поднимает CORE-изменения инстанса в темплейт (рабочее дерево).
# Git НЕ трогает — ветку/PR пользователь создаёт сам (см. вывод).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/layers.sh"
TPL="$HERE/../skeleton"
TPL_ROOT="$(cd "$HERE/.." && pwd)"
INSTANCE="${1:?usage: harness-contribute.sh <instance-path>}"

changed=0
echo "== CORE-изменения инстанса → темплейт =="
for p in "${CORE_PATHS[@]}"; do
  tpl_file="$TPL/$p"; [ -f "$tpl_file" ] || tpl_file="$TPL/$p.template"
  inst_file="$INSTANCE/$p"
  if [ -f "$inst_file" ] && ! diff -q "$tpl_file" "$inst_file" >/dev/null 2>&1; then
    echo "  --- PULLED UP: $p (template < / instance >) ---"
    diff "$tpl_file" "$inst_file" || true   # покажи, ЧТО поднимаем — защита от подъёма старой версии
    cp "$inst_file" "$tpl_file"; changed=1
  fi
done

if [ "$changed" -eq 1 ]; then
  echo ""
  echo "CORE-изменения скопированы в skeleton/."

  # Гейт чистоты — здесь, в точке подъёма. Скрипт копирует ИНСТАНСОВУЮ версию правила поверх
  # шаблонной, а инстансовая по природе полна его стека: так стек-специфика и приезжает в CORE,
  # который едет всем остальным. Порог ratchet, поэтому линт краснеет только на выросшем долге.
  # Не блокируем: файлы уже скопированы, а откат — git-операция, зона владельца. Сигнал плюс
  # команда отката полезнее, чем exit посреди сделанной работы.
  if [ -x "$TPL_ROOT/scripts/lint-core-purity.sh" ]; then
    echo ""
    if bash "$TPL_ROOT/scripts/lint-core-purity.sh"; then
      echo "Чистота CORE: долг не вырос."
    else
      echo ""
      echo "ВНИМАНИЕ: поднятое добавило стек-специфики в CORE (см. строки выше)."
      echo "Варианты: переформулировать нейтрально · унести в rules/lang/<lang>.md ·"
      echo "пометить <!-- core-ok: причина -->. Откат целиком:"
      echo "  git -C \"$TPL_ROOT\" checkout -- skeleton/"
    fi
  else
    echo "ВНИМАНИЕ: scripts/lint-core-purity.sh нет — чистота CORE не проверена." >&2
  fi

  echo ""
  echo "Дальше — твоя зона git: проверь и реши сам:"
  echo "  git -C \"$TPL_ROOT\" diff skeleton/"
  echo "  затем создай ветку и PR вручную."
else
  echo "Нет CORE-расхождений для контрибуции."
fi
