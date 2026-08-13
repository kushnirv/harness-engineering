---
paths:
  - "**/*.vue"
  - "**/*.ts"
  - "**/*.css"
---

# Vue / component-library — правила (грузятся только на совпавших файлах)

> Пример языкового слоя. Расширяет `common/*`, «специфика поверх общего».
> Подгоняй под свой Vue-проект или удали, если стек другой.

- **`<script setup lang="ts">`** + Composition API. Props/Emits через generics
  (`defineProps<{...}>()`), без лишнего `withDefaults`.
- **Логика классов** → отдельный `useXxxClasses.ts`, возвращает `computed<string[]>`.
- **Стили — только дизайн-токены.** Hex/rgb напрямую в `background`/`color` запрещены
  (rgba в box-shadow — ок). Сверяться с конфигом токенов, не угадывать имя.
- **Структура компонента** — по эталону проекта (`ui/`, `model/`, `lib/`, `__tests__/`,
  `__stories__/`, `index.ts`).
- **Баррел-экспорт** обновлять при добавлении компонента.
- **Сверка с макетом** (`workflow.md` требует её, инструмент — здесь): Figma ↔ localhost,
  intent-parity, не pixel-diff. Чеклист и допуски — `.claude/docs/design-conformance.md`
  (приезжает с lang-pack `vue`).
- **Real-runtime для UI** — chrome-devtools MCP; флоу в `.claude/docs/chrome-devtools-workflow.md`
  (оттуда же). Пока UI не открыт браузером, уровень verify честнее объявлять `tests-only`.
- **FSD-обоснование для среза.** Создаёшь или переносишь FSD-слайс → выдай блок: слой + почему,
  граница среза (что вошло, что намеренно НЕ вошло и куда), направление импортов. Логика выбора
  слоя и развилка entity/feature — `.claude/docs/fsd-placement.md` (приезжает с lang-pack `vue`,
  наложи его при setup). Цель: решение читается позже,
  а не живёт только в сессии.

> Реестр найденных ловушек проекта — `.claude/docs/gotchas.md`.
