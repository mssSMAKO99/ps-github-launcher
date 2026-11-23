# AGENTS.md — паспорт проекта GitHub Launcher

Постоянный контекст для агента. Читать до начала работы; текущий шаг — `CURRENT_TASK.md`.

## 1. Что это
WPF-лаунчер репозиториев GitHub (в духе WinUtil): поиск аккаунта, список репозиториев, выбор версии релиза и файла, безопасная загрузка/распаковка в `{BaseDir}\{user}\{repo}`, опциональный запуск. Дистрибутив — один файл `GitHubLauncher.ps1`, два пути запуска:

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\GitHubLauncher.ps1
irm https://mssSMAKO99.github.io/gl | iex
```

`https://` обязателен (`irm` не принимает URI без схемы). Артефакт хранится в git, копия `gl` без расширения публикуется в корень `msssmako99.github.io`. UI, сообщения и комментарии — по-английски.

## 2. Жёсткие ограничения
- Windows PowerShell 5.1 + WPF; UI-поток обязан быть STA (в MTA — relaunch).
- Артефакт: UTF-8 **без BOM** и **только ASCII**, иначе `Compile.ps1` падает: Pages отдаёт файл без charset, PS 5.1 читает ANSI, `irm | iex` ломается.
- Запрещено: `Import-Module`, `#requires -Modules`, `Invoke-WebRequest`.
- Всё в одном файле: XAML и иконка в base64. Без сторонних библиотек, Pester и `Application`.
- WPF трогает только UI-поток; воркеры пишут в `$sync.Events` (`ConcurrentQueue`), UI забирает события `DispatcherTimer` раз в 120 мс.

## 3. Карта кода
- `src/01-Bootstrap` пути/логи/STA → `02-Config` настройки/DPAPI → `03-Api` REST и рейтинг ассетов → `04-Downloader` загрузка → `05-Archive` распаковка → `06-Launcher` папки/маркер/MOTW/суммы/запуск → `07-Workers` задания пула → `08-Main` окно, состояние, события, UI → `09-Appearance` темы (swap палитры через DynamicResource) и GIF-плеер.
- `ui/Styles.xaml` палитра и шаблоны, `ui/MainWindow.xaml` главное окно (маркер `<!-- GHL_STYLES_INJECT -->`), `ui/PickerWindow.xaml` выбор файла.
- `Compile.ps1` сборка, `dev.ps1` запуск из исходников, `tests/` unit+mock+окна, `tools/` XAML-проверка, скриншоты, live-тест.

## 4. Поток данных
`Repos` → выбор строки → `Release` (**список версий**) → ассеты выбранной версии → `Download` (воркер: загрузка → сумма → распаковка → MOTW → маркер) → бейдж. Маркер `.ghl.json` — единственный признак «Downloaded».

## 5. Сборка и проверки
- `.\Compile.ps1` — +1 к `VERSION`, артефакт в корне; `-NoVersionBump -Version 1.2.0` — режим CI.
- `tests\Run-Tests.ps1 -Offline` — unit; `tests\Run-MockTests.ps1` — mock API и окна (нужен STA).
- `tools\Capture-Ui.ps1` — скриншот реального окна. Сдача: сборка чистая, mock-набор зелёный, скриншот проверен, артефакт ASCII/no-BOM.

## 6. Правила изменений
- Порядок модулей фиксирован в `Compile.ps1` (`$expectedOrder`); новый файл = правка списка.
- Новая настройка: default в `Get-GhlDefaultConfig` → нормализация в `Get-GhlConfig` → `Save-GhlUiConfig`/`Initialize-GhlUiFromConfig` → README.
- Новый элемент XAML: префикс по типу (`btn/txt/lst/cb/chk/rb/img/pnl/prg`) и запись в `Get-GhlUiMap`, иначе `Get-GhlNamedElement` бросит исключение.
- Новый воркер: `Get-GhlWorker*` + `Join-GhlWorkerScript` + имя в `Get-GhlWorkerNames` (иначе проверка сборки падает или задание умирает в рантайме).
- Никаких сетевых и тяжёлых дисковых вызовов в UI-потоке.
- Цвета — только из палитры `Styles.xaml`; hex в окнах запрещён.
- Источники: ASCII, CRLF, без BOM. `config.json`: увеличивать `Version` и мигрировать.

## 7. Подводные камни
- `@()` вокруг `List<T>` падает на Win11 PS — использовать `.ToArray()`; один элемент массива после JSON становится скаляром, поэтому всегда `@(...)`.
- `AllowsTransparency` = слоёное окно: клип фона вручную, тяжёлые эффекты дороги.
- Второй `Application` в сессии невозможен → окна на `ShowDialog` со своими стилями.
- Свойство под `BeginAnimation(..., HoldEnd)` остаётся анимированным: снимать анимацию (`BeginAnimation(prop, $null)`) перед ручной установкой значения.

## 8. Дорожная карта
- **M1 (готово):** версии релизов, гигиена, багфиксы.
- **M2 (готово):** GitHub Actions: `build.yml` (reusable), `ci.yml`, `release.yml`;
  релиз на тег `v*`, nightly на `main`, `gl` на Pages.
- **M3 (текущий):** 4 темы-палитры с живым переключением, анимированный GIF-фон,
  секция Appearance, миграция конфига. См. `CURRENT_TASK.md`.
- **M4:** UX-полировка: мягкая палитра, настройки вкладками, чипы, фокус-ринги.
- **M5:** избранные репозитории в дополнение к избранным авторам.