# Language pack: .NET / ASP.NET Core Web API

Языковой пакет поверх абстрактного ядра `skeleton/`. Ядро не трогает.

Профиль — **ASP.NET Core Web API, .NET 9/10**. Ни Unity, ни MAUI, ни desktop: часть содержимого
про хостинг и пайплайн для них неприменима.

## Что внутри

```
lang-packs/dotnet/
├── .editorconfig.template          ← severity поднята ЯВНО, чтобы гейт краснел
└── docs/
    └── REVIEW-dotnet.md.template   ← чеклист ревью C#-кода
```

Правила, которые грузятся агенту автоматически на `*.cs`/`*.csproj`/`*.sln`, лежат отдельно —
`skeleton/.claude/rules/lang/dotnet.md` (path-scoped, едет в ядре при `lang=dotnet`).

## Зачем `.editorconfig` отдельным файлом

Правила в `rules/lang/dotnet.md` адресованы агенту и человеку. Сборка их не проверяет, и это не
предположение: из перечисленного там `async void` не имеет диагностики вообще, `CA1849`
(sync-over-async) и `CA2007` (ConfigureAwait) по умолчанию выключены, `CA2254` (шаблон лога) идёт
как suggestion и в вывод `dotnet build` не попадает.

Референсные конфиги Microsoft почти всё ставят `:suggestion` — правило формально есть, сборку не
ломает, и «собралось чисто» ничего не означает. Этот шаблон поднимает severity до `error` там,
где цена ошибки того стоит.

**Цена названа прямо:** `error` останавливает сборку, включая чужой легаси-код. На существующем
проекте включать по одной строке, а не файлом целиком.

## Как подключить

```bash
# 1. Ядро
cp -r skeleton/.claude ./
cp skeleton/.harness.conf.example ./.harness.conf

# 2. Этот пакет
#    ИМЯ БЕЗ .template: правила зовут `.claude/docs/<имя>.md`, копия «как есть»
#    оставляет ссылки битыми
for f in skeleton/lang-packs/dotnet/docs/*.md.template; do
  cp "$f" "./.claude/docs/$(basename "$f" .template)"
done
cp skeleton/lang-packs/dotnet/.editorconfig.template ./.editorconfig
#    подставить <PROJECT_NAME>, прочитать комментарии про severity и решить по каждой строке

# 3. Убрать чужие языковые правила из ядра, оставить dotnet.md
```

`bash scripts/bootstrap.sh <имя> dotnet` раскатывает ядро, заполняет `.harness.conf` под .NET и
включает Ярус 3, но **языковой пакет не копирует** — ни этот, ни vue. Шаг 2 выше остаётся
ручным в любом случае.

## Что ещё нужно проекту, а пакет не даёт

- **`<Nullable>enable</Nullable>` в `csproj`.** Без него NRT-диагностики из `.editorconfig`
  не срабатывают: severity поднята для правил, которые не запущены.
- **`-warnaserror` в `GATE_CMD`.** Иначе `error` из editorconfig доедет только до вывода, а код
  выхода останется нулевым.
- **Проверка на `async void`.** Отдельной командой в гейте (грепом), severity для неё нет.
