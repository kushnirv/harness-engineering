# harness-template

Language-agnostic шаблон харнесса для **Claude Code** и **Cursor**.

Харнесс = `CLAUDE.md` + хуки (guard / sensor / gate) + skills + path-scoped rules +
связь с долгосрочной памятью. Ядро не зависит от стека: Vue, Go, PHP, бэкенд.
Языковая специфика — отдельным слоем (`rules/lang/` + `lang-packs/`).

## Зачем

Модель недетерминирована: мыслит токенами, не знает специфики кодовой базы.
Без структуры агент застревает, галлюцинирует, тихо ломает логику.

Харнесс компенсирует:

- **Контекст** — не дать агенту попасть в «глупую зону».
- **Верификация** — не доверять выводу, а проверять (хуки на exit-кодах).
- **Оркестрация** — длинные задачи разбиты на шаги с сохранением состояния.
- **Изоляция** — безопасное выполнение в песочницах.

Это **supervised-харнесс** (человек на цикле), не автономный loop-runner.
Набор сознательно MVP — «строй от отказов».

## Setup

```bash
# Новый проект — одна команда, харнесс работает из коробки:
copier copy gh:kushnirv/harness-engineering ~/projects/my-app --trust
# Вопросы: project_name, lang (основной пак), extra_langs (доп. паки для монорепы)
```

Что приезжает: CORE (guards / skills / rules) + стартовый скаффолд — `CLAUDE.md`,
`.claude/settings.json` (хуки уже подключены), `.harness.conf` (fail-open),
`scripts/`. Скаффолд — instance-owned: `copier update` его не перезаписывает
(`_skip_if_exists`), обновляется только CORE.

Стартовое состояние — fail-open: тестовые команды пусты → sensor и gate молчат,
guard (readonly-зоны) и nudge работают сразу. Появился стек — заполни в
`.harness.conf` `JS_TEST_CMD` / `PY_TEST_CMD` / `GATE_CMD` (примеры в комментариях).

Sensor-диспетчер универсален: обычный однопакетный репозиторий, один стек или
монорепа с несколькими воркспейсами — одна проводка. Роутинг по расширению файла
(`.py` → pytest, `.ts/.tsx/...` → JS-раннер), корень воркспейса определяется
автоматически (ближайший `package.json` / `pyproject.toml`).

Опционально после copy:

- **git-side gate на pre-push**: (Node) возьми `skeleton/.husky/pre-push` из этого
  репозитория + `"prepare": "husky || true"` в package.json; не-Node стек — повесь
  `.claude/guards/gate.sh` + `GATE_TEST_CMD` на pre-push вручную (`.githooks` + `core.hooksPath`).
- **языковой пакет со скилами** под свой стек — `skeleton/lang-packs/`.

> Обновление ядра: `copier update` внутри инстанса. Обратный канал (подъём
> generic-находок в шаблон) — в [docs/architecture.md](docs/architecture.md).

## Проверить, что живо

```bash
bash scripts/verify-harness.sh
```

Smoke-тест: guard блокирует запись в readonly-зону (exit 2), sensor fail-open,
роутинг диспетчера по воркспейсам (фикстура), legacy-конфиг, `/note`.
Работает и в свежем инстансе (сразу после `copier copy`), и в этом репозитории.

## Что дальше

- **Как устроено** — диаграммы, дерево, dual-tool, языковые слои, память,
  capture-flow, Copier-sync → [docs/architecture.md](docs/architecture.md)
- **Параметры конфига** — самодокументированы в
  [skeleton/.harness.conf](skeleton/.harness.conf)
- **Методология Specify → Implement → Review** →
  [docs/specify-implement-review.md](docs/specify-implement-review.md)
- **Архитектурные решения (ADR)** → [docs/decisions.md](docs/decisions.md)
- Агенту вход — не здесь, а в `skeleton/CLAUDE.md.jinja` (раздел «Агенту на входе»).

## Когда НЕ нужно

- Проект < 1 недели жизни — overhead не окупится.
- Нет тестов — sensor без тестов бесполезен.
- Один разработчик без AI-агентов — харнесс для агентов, не для людей.
