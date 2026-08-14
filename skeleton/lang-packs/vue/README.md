# Language pack: Vue / component-library

Образцовый **языковой пакет** поверх абстрактного ядра skeleton. Показывает, как
расширять харнес под конкретный стек, не трогая generic-слой.

## Что внутри

```
lang-packs/vue/
├── skills/
│   └── add-component/SKILL.md   ← скаффолдинг Vue-компонента (/add-component)
└── docs/
    ├── dev-guide.md.template            ← как добавить компонент (Vue-флоу)
    ├── REVIEW-vue.md.template           ← Vue-специфичный чеклист ревью
    ├── fsd-placement.md.template        ← выбор слоя FSD, развилка entity/feature
    ├── design-conformance.md.template   ← сверка с макетом: intent, не пиксели
    └── chrome-devtools-workflow.md.template ← добить UI до real-runtime
```

`agents/lens-state.md` — линза доменного ревью про состояние и реактивность. В ядре её нет
намеренно: три из пяти пунктов предмета (вычисление вне `computed`, деструктуризация пропа,
ремаунт против обновления) привязаны к стеку, обобщение размыло бы предмет. Копируется в
`.claude/agents/` того проекта, который использует доменное ревью; свод делает `arbiter` из ядра.

Правила Vue (что грузится агенту автоматически на `*.vue`) лежат отдельно —
`skeleton/.claude/rules/lang/vue.md` (path-scoped).

## Как подключить

Vue-проект = ядро skeleton **плюс** этот пакет:

```bash
# 1. Скопировать ядро
cp -r skeleton/.claude ./
cp skeleton/.harness.conf.example ./.harness.conf

# 2. Наложить Vue-пакет
cp -r skeleton/lang-packs/vue/skills/add-component ./.claude/skills/
#    ИМЯ БЕЗ .template: правила зовут `.claude/docs/design-conformance.md`, а не
#    `design-conformance.md.template` — копия «как есть» оставляет ссылки битыми
for f in skeleton/lang-packs/vue/docs/*.md.template; do
  cp "$f" "./.claude/docs/$(basename "$f" .template)"
done
#    потом заполнить плейсхолдеры внутри скопированных доков
#    rules/lang/vue.md уже в ядре — оставить, удалить go.md/php.md если не нужны
```

Не-Vue стек (Go, PHP, …) — этот пакет не копируешь, берёшь/пишешь свой
(`rules/lang/<lang>.md` уже даёт точку старта).
