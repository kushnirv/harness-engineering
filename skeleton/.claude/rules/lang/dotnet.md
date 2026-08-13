---
paths:
  - "**/*.cs"
  - "**/*.csproj"
  - "**/*.sln"
---

# .NET / ASP.NET Core Web API — правила (грузятся только на совпавших файлах)

> Цель — ASP.NET Core Web API на .NET 9/10. Другой профиль (WPF, MAUI, консоль) — часть правил
> ниже про ASP.NET Core неприменима, правь под себя.
>
> **Эти правила НЕ дублируют гейт.** Проверено по списку default-enabled диагностик .NET 10:
> из перечисленного ниже сборка ловит почти ничего. `async void` — правила нет вообще;
> `CA1849` (sync-over-async) и `CA2007` (ConfigureAwait) по умолчанию выключены, а `CA2254`
> (шаблон лога) идёт как suggestion и в вывод `dotnet build` не попадает. Захочешь гейт —
> поднимай severity в `.editorconfig` руками. Удалять правила как «покрытые сборкой» нельзя.

## Асинхронность

- **`async void` — запрещено.** Исключение из такого метода не попадает на Task, а летит на
  пул потоков: `try/catch` вокруг вызова его не поймает, процесс падает. В Web API законных
  `async void` нет. Навязала сигнатуру чужая абстракция — тело сведи к одной строке
  `await DoAsync()`, логику держи в `async Task`.
- **`.Result` / `.Wait()` / `.GetAwaiter().GetResult()` в коде запроса — запрещено.** Причина —
  голодание пула потоков, а не дедлок: своего `SynchronizationContext` в ASP.NET Core нет, так
  что получаешь деградацию времён ответа под нагрузкой. Три конструкции не эквивалентны:
  `.Wait()`/`.Result` заворачивают в `AggregateException`, `.GetAwaiter().GetResult()` бросают
  первое. Законно — синхронный `Dispose` без `IAsyncDisposable` и уже завершённая задача
  (`IsCompletedSuccessfully`). Конструкторы и тесты в исключения НЕ входят: для первого есть
  async-фабрика, для второго `async Task`-методы.
- **`ConfigureAwait(false)` в коде приложения не ставить** — там нет ни `SynchronizationContext`,
  ни своего `TaskScheduler`, вызов ничего не меняет. В переносимой библиотеке, которая может
  уехать в другой хост, — ставить на каждом `await`. Запрет только на булев overload:
  `ConfigureAwaitOptions.SuppressThrowing` и `ForceYielding` меняют семантику и разрешены.
- **`await Task.WhenAll(...)` бросает только первое исключение.** Нужны все — сохрани задачу в
  переменную, оберни `await` в `try/catch` и читай `whenAll.Exception?.InnerExceptions`.
  `?.` обязателен: если ни одна не упала, но одна отменена, `Exception` равен null.

## Nullable

- **Верь аннотациям внутри, проверяй на входе.** Не добавляй null-проверку там, где тип говорит
  non-null. Но аннотации в рантайме не проверяются, поэтому на границе доверия проверка нужна:
  DTO из JSON/формы/query, конфигурация, материализация EF, рефлексия, интероп, библиотеки без
  NRT. `!` — чисто компиляторный, `x!` в рантайме это просто `x`: он гасит предупреждение, а не
  защищает, и превращает диагностируемую ошибку в `NullReferenceException` дальше по стеку.

## DI и время жизни

- **Scoped/Transient не инжектить в Singleton.** Ловится на `builder.Build()`, но **только в
  Development**: `ValidateScopes`+`ValidateOnBuild` хост включает при `IsDevelopment()`. В
  Production оба флага выключены — тишина. Форсировать:
  `builder.Host.UseDefaultServiceProvider(o => { o.ValidateScopes = true; o.ValidateOnBuild = true; })`.
  Проверка слепа к открытым генерикам, фабричным регистрациям и типам вне контейнера.
- **Инжектированное не диспозить** — владелец контейнер. Диспозишь сам только то, что создал сам
  (`AddSingleton(new X())`). Ручной скоуп — `CreateAsyncScope()` + `await using`: `CreateScope()`
  при сервисе с обоими интерфейсами молча уйдёт в синхронный `Dispose`, и асинхронная очистка не
  выполнится.

## HTTP

- **`new HttpClient()` на каждый запрос — запрещено** (исчерпание портов). Бери
  `AddHttpClient<T>()` или `IHttpClientFactory`. Равноправная альтернатива по доке MS —
  singleton `HttpClient` с `SocketsHttpHandler { PooledConnectionLifetime = … }`.
- **Typed client не держать в Singleton** — он transient и рассчитан на короткую жизнь, иначе
  перестанет реагировать на смену DNS. Нужен в singleton — named client через фабрику либо
  `UseSocketsHttpHandler` с `PooledConnectionLifetime`.

## Конфигурация и секреты

- **Опции — `AddOptions<T>().Bind(...).ValidateDataAnnotations().ValidateOnStart()`** (или
  `AddOptionsWithValidateOnStart<T>()`). Без `ValidateOnStart` валидация ленивая: падает на
  первом обращении к `IOptions<T>.Value`, а если тип не резолвится — не падает никогда.
  DataAnnotations не рекурсирует во вложенные объекты: нужны `[ValidateObjectMembers]` /
  `[ValidateEnumeratedItems]`.
- **Секреты в dev — `dotnet user-secrets`**, не `appsettings*.json`, не `launchSettings.json`,
  не `.http`: эти три уезжают в git. Хранилище user-secrets не шифруется — это удобство, не
  защита. Прод — переменные окружения или Key Vault; в ИМЕНИ env-переменной разделитель `__`
  (в ключе user-secrets и в JSON двоеточие — норма).

## Пайплайн

- **Порядок middleware:** ExceptionHandler (+HSTS, не в Development) → `UseHttpsRedirection` →
  `UseStaticFiles` → `UseRouting` → `UseCors` → `UseAuthentication` → `UseAuthorization` →
  `UseAntiforgery` → `Map*`. `UseCors` строго после `UseRouting` и до `UseAuthorization`, иначе
  CORS-заголовков не будет на 401/403; и обязательно до `UseResponseCaching`.
  Автоматически ловится ровно один случай — ASP0001 на `UseAuthorization` до `UseRouting`.
  Порядок ExceptionHandler/HSTS/StaticFiles и взаимный порядок CORS↔Authorization — только глазами.

## EF Core

- **`DbContext` не thread-safe.** Ни `Task.WhenAll` над запросами одного контекста, ни
  параллельный доступ из нескольких потоков. Нужна параллельность — отдельный контекст на ветку
  через `IDbContextFactory<T>`.
- **Наружу отдавать DTO, не сущности.** `sealed record` + проекция через `Select`: сущность тянет
  навигации, ленивую подгрузку и внутреннюю схему в контракт.
- **Публичный метод возвращает материализованный результат** — `IReadOnlyList<T>` после
  `ToListAsync()`, а не отложенный `IQueryable<T>`: иначе запрос выполнится вне контекста.
- **Lazy loading по умолчанию выключен** и включается опт-ином (`UseLazyLoadingProxies()` или
  `ILazyLoader`). Не рассчитывай ни на то, что навигация подгрузится сама, ни на то, что её
  отсутствие — баг.
- **Сгенерированную миграцию читать перед применением.** `Up`/`Down` правятся руками, если
  генератор угадал неверно; пересоздание таблицы вместо переименования колонки теряет данные.
- **`Single`/`SingleOrDefault` — контракт «ровно один»**: EF ставит LIMIT 2 и бросает на второй
  строке. Берётся там, где дубль — это баг данных, о котором надо узнать. Ждёшь «ноль или один
  из многих» — `First`/`FirstOrDefault` с явной сортировкой.

## Логи

- **Структурные плейсхолдеры, не интерполяция:**
  `logger.LogWarning("Person {FirstName} failed", first)`, не `logger.LogWarning($"...{first}...")`.
  Интерполяция убивает структурированный поиск в бэкенде логов. `CA2254` есть, но идёт как
  suggestion и сборку не ломает, а несовпадение числа плейсхолдеров и перепутанный порядок
  аргументов он не видит вовсе.

> Реестр найденных ловушек проекта — `.claude/docs/gotchas.md`.
