#!/usr/bin/env bash
# Обратный канал: поднимает CORE-изменения инстанса в темплейт (рабочее дерево).
# Git НЕ трогает — ветку/PR пользователь создаёт сам (см. вывод).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib/layers.sh"
TPL="$HERE/../skeleton"
TPL_ROOT="$(cd "$HERE/.." && pwd)"
INSTANCE="${1:?usage: harness-contribute.sh <instance-path>}"

# Режим по умолчанию — ПРЕДЛОЖИТЬ, не перезаписать. Раньше скрипт делал безусловный
# `cp инстанс → шаблон`, и это ломало ровно то, для чего он существует: инструмент молча
# исходил из того, что инстанс новее шаблона. Замер 14.08 на самом зрелом инстансе: прогон
# перезаписал бы 20 файлов и снёс 613 строк, которые существуют ТОЛЬКО в шаблоне (работа,
# сделанная после последнего тега). Защитой был diff на ~1300 строк «посмотри глазами» —
# то есть проверка, которую нельзя пройти внимательно.
#
# Теперь: инстансовая версия кладётся рядом как `<файл>.from-instance`, показывается diff и
# СЧЁТ строк в обе стороны. Перезапись — только явным `--apply`, и даже он отказывается, если
# в шаблоне есть строки, которых нет в инстансе (то есть подъём потерял бы работу шаблона).
APPLY=0
[ "${2:-}" = "--apply" ] && APPLY=1

changed=0
risky=0
echo "== CORE-изменения инстанса → темплейт =="
for p in "${CORE_PATHS[@]}"; do
  tpl_file="$TPL/$p"; [ -f "$tpl_file" ] || tpl_file="$TPL/$p.template"
  inst_file="$INSTANCE/$p"
  [ -f "$inst_file" ] || continue
  diff -q "$tpl_file" "$inst_file" >/dev/null 2>&1 && continue

  # Счёт в обе стороны: `<` — строки только шаблона (их и теряет слепой cp), `>` — только инстанса.
  only_tpl="$(diff "$tpl_file" "$inst_file" 2>/dev/null | grep -c '^<' || true)"
  only_inst="$(diff "$tpl_file" "$inst_file" 2>/dev/null | grep -c '^>' || true)"

  echo "  --- $p: только в шаблоне ${only_tpl} стр. · только в инстансе ${only_inst} стр. ---"
  diff "$tpl_file" "$inst_file" || true

  if [ "$APPLY" -eq 1 ] && [ "${only_tpl:-0}" -eq 0 ]; then
    cp "$inst_file" "$tpl_file"; changed=1
    echo "      → перезаписан (шаблон ничего своего не терял)"
  elif [ "$APPLY" -eq 1 ]; then
    cp "$inst_file" "${tpl_file}.from-instance"
    risky=1
    echo "      → НЕ перезаписан: в шаблоне ${only_tpl} своих строк. Версия инстанса рядом: $(basename "$tpl_file").from-instance"
  else
    cp "$inst_file" "${tpl_file}.from-instance"
    echo "      → предложено: $(basename "$tpl_file").from-instance (перезапись — флагом --apply)"
  fi
done

if [ "$risky" -eq 1 ]; then
  echo ""
  echo "ЧАСТЬ ФАЙЛОВ НЕ ПЕРЕЗАПИСАНА: в шаблоне есть строки, которых нет в инстансе." >&2
  echo "Слепой подъём стёр бы их. Сведи руками из *.from-instance и удали эти файлы." >&2
fi

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
