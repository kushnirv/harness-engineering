# harness-template

Language-agnostic шаблон харнесса для **Claude Code**.

Харнесс = `CLAUDE.md` + хуки на четырёх ярусах (pre-commit / sensor / gate / pre-push) + skills +
path-scoped rules + связь с долгосрочной памятью. Ядро не зависит от стека: Vue, .NET, Go, PHP,
python. Языковая специфика — отдельным слоем (`rules/lang/` + `lang-packs/`).

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

**Новый проект — одной командой.** Разворачивает каркас, ставит хуки, включает Ярус 3 и гоняет
smoke сам:

```bash
mkdir -p myproj && cd myproj
bash /path/to/harness-template/scripts/bootstrap.sh myproj dotnet
# lang: python | vue | go | php | dotnet | none      (--agents — доставить роли субагентов)
```

Папка обязана быть пустой: скрипт откажется работать в непустой, чтобы `git init` не уехал
в каталог с другими проектами.

**Существующий проект — вручную, 5 шагов.** Bootstrap рассчитан на чистую раскатку, поверх
живого репозитория его не гонять:

```bash
# 1. Скопируй ядро в корень своего проекта
cp -r skeleton/.claude ./
cp skeleton/.harness.conf.example .harness.conf

# 2. Заполни .harness.conf под свой проект.
#    Все параметры с комментариями — внутри самого файла.

# 3. Сделай скрипты исполняемыми
chmod +x .claude/guards/*.sh .claude/skills/note/append.sh

# 4. Создай CLAUDE.md из шаблона и замени плейсхолдеры
cp skeleton/CLAUDE.md.template CLAUDE.md

# 5. Ярус 3 на pre-push. Логика — в .claude/guards/pre-push.sh (gate + секрет-скан +
#    полные тесты + покрытие изменённых строк), она приезжает вместе с харнессом.
#    Включить нужно локально:
printf '#!/usr/bin/env sh\nsh "$(git rev-parse --show-toplevel)/.claude/guards/pre-push.sh"\n' \
  > .git/hooks/pre-push && chmod +x .git/hooks/pre-push
#    bootstrap.sh делает этот шаг сам. Любой стек, npm не нужен.
#    (Node, если шарите хуки через package.json) вместо этого — husky:
#    cp skeleton/.husky/pre-push .husky/pre-push && chmod +x .husky/pre-push
#    package.json: "prepare": "husky || true"   (|| true чтобы CI не падал)

# (опц.) языковой пакет под свой стек
cp -r skeleton/lang-packs/vue/skills/* .claude/skills/
```

> Версионируемый sync ядра — через [Copier](https://copier.readthedocs.io)
> (`copier update`). Установка и обратный канал — в [docs/architecture.md](docs/architecture.md).

## Проверить, что живо

```bash
bash scripts/verify-harness.sh
```

Smoke-тест: guard блокирует запись в readonly-зону (exit 2), sensor зелёный,
gate, `/note`. Требует заполненного `.harness.conf` в проекте.

## Что дальше

- **Как устроено** — диаграммы, дерево, четыре яруса проверок, языковые слои, память,
  capture-flow, Copier-sync → [docs/architecture.md](docs/architecture.md)
- **Параметры конфига** — самодокументированы в
  [skeleton/.harness.conf.example](skeleton/.harness.conf.example)
- **Методология Specify → Implement → Review** →
  [docs/specify-implement-review.md](docs/specify-implement-review.md)
- **Архитектурные решения (ADR)** → [docs/decisions.md](docs/decisions.md)
- Агенту вход — не здесь, а в `skeleton/CLAUDE.md.template` (раздел «Агенту на входе»).

## Когда НЕ нужно

- Проект < 1 недели жизни — overhead не окупится.
- Нет тестов — sensor без тестов бесполезен.
- Один разработчик без AI-агентов — харнесс для агентов, не для людей.
