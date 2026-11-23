# CURRENT_TASK — M1: версии релизов + гигиена

Детальное ТЗ текущего шага. Основа — `AGENTS.md`.

## Цель

Видеть **все** версии релизов (не только latest), переключаться между ними и
скачивать любую, включая пакетную загрузку выбранной версии. Попутно убрать мёртвый
код и починить баги, мешающие этому шагу.

## Сценарии

1. Открыл репозиторий → список версий, по умолчанию последняя стабильная.
2. Выбрал старую версию → файлы обновились, Download скачивает именно её.
3. Вижу, что установлено (`.ghl.json`), и есть ли обновление.
4. Переключил «Include pre-release» → фильтр мгновенный, без сети.
5. Нет релизов → только исходники и объяснение.
6. Нет Windows-файлов у версии → кнопка недоступна с пояснением.
7. Выделил несколько репозиториев → скачивается выбранная версия для всех; где её
   нет — репозиторий пропускается с сообщением.

## A. API — `src/03-Api.ps1`

1. `Get-GhlReleases -User -Repo -Token -PerPage 30`: GET `/releases?per_page=N`;
   без фильтра prerelease; исключить `Draft`; сортировка `Published` desc (fallback
   `CreatedAt`); `Kind='norelease'` при пустом списке.
2. `Get-GhlLatestRelease` — тонкая обёртка над списком (совместимость и тесты):
   первый не-prerelease, при `-IncludePrerelease` — первый вообще.
3. `Select-GhlReleaseByTag -Releases -Tag` — найти версию, иначе `$null`.
4. `Convert-GhlRelease`: инвариантный разбор дат (`AssumeUniversal`), добавить `CreatedAt`.
5. `Convert-GhlAsset`: добавить `DownloadCount` и `AutoLaunchable` (false для
   `.msix/.appx`).
6. Удалить `Get-GhlErrorMessage` и его экспорт.
7. `Invoke-GhlHttp`: клиент создаётся один раз на вызов, вне цикла ретраев; добавить
   `X-GitHub-Api-Version: 2022-11-28`.

## B. Воркеры — `src/07-Workers.ps1`

1. `Get-GhlWorkerRelease` возвращает список: `Kind='Release'`, `Releases`, `Ok`,
   `Message`, `ErrKind`, `Remaining`, `User`, `Repo`.
2. `Get-GhlWorkerDownload`: сам резолвит `Checksums` (в т.ч. для одиночной загрузки);
   staging берёт из `Get-GhlAppDir`; в пакете ищет версию по `Tag`; если её нет —
   пропуск `version not available`.
3. `Get-GhlWorkerRepos`: принимает `BaseDir` и считает бейдж в воркере; бейдж =
   маркер **и** хотя бы один файл (иначе `Partial`).
4. `Get-GhlWorkerNames`: убрать `Start-GhlItem`, `Open-GhlFolder`, `Get-GhlErrorMessage`;
   добавить `Get-GhlRepoBadge`, `Select-GhlReleaseByTag`.

## C. UI — `08-Main.ps1`, `ui/MainWindow.xaml`

1. Состояние: `Releases`, `SelectedRelease`, `ReleaseRequest`, кэш
   `ReleaseCache[key] = @{ Releases; Ts }` (TTL 10 мин).
2. `Apply-GhlReleases`: заполнить `cbRelease`, отфильтровать prerelease, выбрать
   последнюю стабильную (или первую prerelease при включённой галочке; если стабильных
   нет и галочка выключена — подсказка включить её), перерисовать ассеты.
3. Новые элементы + `Get-GhlUiMap`: `cbRelease`, `btnReleaseRefresh`, `txtInstalled`.
   Блок «Latest release assets» заменить строкой Version; подписи режимов →
   «Package» / «Source code».
4. Смена версии: ассеты выбранной версии, сохранить выбранный файл по имени, обновить
   `txtAssetsCaption` (`Files | v1.2.0`) и доступность `btnDownload`.
5. После загрузки: бейдж, маркер, `txtInstalled` («Installed v1.1.0» / «Update
   available» / «Not installed»), выбранная версия не сбрасывается.
6. `chkPrerelease` фильтрует список из кэша, без HTTP.
7. Защита от устаревших ответов: инкремент `ReleaseRequest`, событие несёт номер;
   сравнение `user/repo` — case-insensitive.
8. `Update-GhlRateLimit`: использовать `ResetAt`, обновлять из `Release`/`Download`.
9. Кнопка ↻ на панели версий сбрасывает кэш и перезапрашивает.
10. Пакет: `New-GhlBatchJob` передаёт `Tag` выбранного релиза (в режиме Package); под
    кнопкой подсказка `Version v1.2.0 for all selected`; отсутствующие версии
    пропускаются, счётчик `QueueSkipped` растёт. Версия берётся из панели деталей
    (`CurrentItem`), поэтому при мультивыборе она всегда видна на экране; в тесте
    перед мультивыбором явно выбрать `demo-tool`.

## D. Обязательные багфиксы

1. Тост невидим после первого fade-out: снимать анимацию (`BeginAnimation(...,$null)`)
   перед `Opacity=1`, затем fade-in 120–160 мс.
2. `Get-GhlPublishedChecksums` не вызывать в UI-потоке — только воркер.
3. Разделить `$sync`: фоновая картинка получает `$state.SyncBg`.
4. `Write-GhlLog` пишет в `Join-Path (Get-GhlAppDir) 'logs'`, уважая `GHL_CONFIG_DIR`.
5. При старте применять `Window.Maximized`, геометрию клампить в WorkArea.
6. Фильтр на `ICollectionView.Filter`, без пересоздания коллекции.
7. `Invoke-GhlDownload`: idle-timeout 60 с без байт; `.part` не создавать до 200.
8. Ошибка Release сбрасывает `CurrentRelease`, `ReleaseFor`, `Releases`, ассеты.
9. `AutoLaunchable=false` для msix/appx: Download разрешён, автозапуск → открыть
   папку с пояснением.
10. Поиск во время работы останавливает текущее задание `Repos` и стартует новое.
11. `Save-GhlUiConfig` проверяет BaseDir через `Test-GhlWritablePath`.
12. `Expand-GhlZip`: суммировать `$entry.Length` до распаковки и сравнивать с лимитом.
13. Битый кэш фона удалять и перекачивать один раз; `ConvertTo-GhlSafeName` защищает
    зарезервированные имена (`con`, `aux`, `nul`, `com1`…).

## E. Удалить / почистить

- `Get-GhlRepoStatusText`, `Get-GhlErrorMessage`, `New-GhlSourceArchive.Revision`,
  `SuggestedName`, `$sync.Busy/LastError/RepoCache`, `$state.App/LastUser`,
  повторная установка `lstAssets.ItemsSource`.
- `PLAN.md`; `.gitignore`: добавить `dist/`, `*.part` (артефакт остаётся в git).
- README: раздел Releases (список версий) и таблица настроек.

## F. Тесты и приёмка

Mock API: `/repos/mockuser/demo-tool/releases` = `v1.3.0` (prerelease), `v1.2.0`
(windows + linux), `v1.1.0` (другой windows zip); `v1.2.0` также у `second-tool`
(windows) и `third-tool` (только linux); журнал запросов в `requests.log`.

Unit: порядок версий, нет drafts, есть prerelease; latest выбирает стабильную;
`Select-GhlReleaseByTag` возвращает `$null` для отсутствующей; msix/appx →
`AutoLaunchable=false`; пустой `published_at` не роняет разбор.

Оконный сценарий `versions`: 3 версии, выбрана `v1.2.0`; переключение на `v1.1.0`
меняет ассеты; после загрузки маркер содержит `Tag=v1.1.0`, бейдж `Downloaded`,
`txtInstalled` содержит `v1.1.0`; prerelease-фильтр не делает новых запросов;
двойной тост виден (`Opacity=1`, нет активной анимации).

Пакетный сценарий: маркеры `demo-tool` и `second-tool` содержат `Tag=v1.2.0`
(выбранная версия, не latest).

Регрессии: 26 unit-тестов и 4 оконных сценария зелёные; `Compile.ps1` без ошибок;
артефакт ASCII/no-BOM, прирост < 15 КБ; `Capture-Ui.ps1` проверен глазами.

## G. Не входит

Темы и GIF (M3), редизайн UI (M4), избранные репозитории (M5), CI/Pages (M2 —
следующий шаг). Отдельных политик «всегда latest» нет: пакет следует выбранной версии.

## H. Риски

- `/releases` тяжелее `/latest`, но это 1 запрос вместо 1–3 — обычно выгоднее.
- Кэш 10 минут может устареть — есть ↻.
- Старые маркеры без `Tag` → «Installed (unknown)».
- Любое переименование требует правки `$expectedOrder`/`Get-GhlWorkerNames`.

## I. Решения владельца

1. Два пути запуска: файл и `irm https://mssSMAKO99.github.io/gl | iex`; URL всегда
   со схемой `https://`; артефакт в git, копия `gl` — на Pages.
2. Язык UI и сообщений — английский (ASCII-safe).
3. Пакет скачивает выбранную версию; отсутствующие пропускаются.
4. Порядок: M1 → M2 CI → M3 темы+GIF → M4 UX → M5 избранные репозитории.