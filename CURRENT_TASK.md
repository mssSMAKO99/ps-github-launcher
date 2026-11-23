# CURRENT_TASK — M2: GitHub Actions

Детальное ТЗ текущего шага. Основа — `AGENTS.md`.

## Цель

Собирать и публиковать лаунчер автоматически: тег `vX.Y.Z` даёт GitHub Release,
push в `main` — nightly-prerelease, оба пути обновляют `gl` на Pages. Ветки и PR
проходят сборку и тесты, но ничего не публикуют.

## Сценарии

1. PR/ветка → CI собирает артефакт и гоняет тесты; публикации нет.
2. `git tag v1.2.3 && git push origin v1.2.3` → артефакт штампуется `1.2.3`,
   создаётся релиз с `GitHubLauncher.ps1`, `gl`, `SHA256SUMS.txt`.
3. Push в `main` → тот же артефакт, обновляется prerelease `nightly`.
4. В обоих случаях корневой `gl` в `mssSMAKO99/msssmako99.github.io` обновляется;
   без секрета `PAGES_DEPLOY_TOKEN` job пишет warning и пропускается.
5. Битая версия (не `x.y.z`) валит сборку до записи файлов.

## A. Сборка — `Compile.ps1`

1. Новый параметр `-Version`: принимает `x.y.z` с необязательным `-suffix`,
   снимает ведущую `v`, перезаписывает `VERSION`, приоритетнее `-NoVersionBump`.
2. Невалидная версия — ошибка до создания артефакта.
3. Инкремент работает только для чистого `x.y.z`; suffixed-версия не инкрементится.
4. Важно: `$Version` и `$version` в PowerShell — одна переменная; запрос версии
   сохраняется в `$RequestedVersion` до чтения `VERSION`, иначе параметр затирается.
5. Заголовок артефакта содержит реальный URL репозитория.

## B. Workflows — `.github/workflows/`

1. `build.yml` — переиспользуемый (`workflow_call`), `windows-latest`,
   `shell: powershell` (PS 5.1): резолв версии → `Run-Tests.ps1 -Offline` →
   `Run-MockTests.ps1 -NoUi` → `Compile.ps1 -NoVersionBump -Version <v>` →
   проверка (размер, отсутствие BOM, ASCII, встроенная версия, `VERSION`) →
   `dist/GitHubLauncher.ps1` + `dist/gl` (побайтово равны) + `SHA256SUMS.txt` →
   `actions/upload-artifact@v4` (`ghl-dist`) → summary.
2. `ci.yml` — PR, push в ветки (кроме `main`, без тегов), `workflow_dispatch`;
   `contents: read`, concurrency с `cancel-in-progress: true`, только вызов build.
3. `release.yml` — push тегов `v*`, push в `main`, `workflow_dispatch`:
   - `prepare` (ubuntu): версия из тега (снять `v`) или из `VERSION`, канал;
   - `build` (reusable) с этой версией;
   - `publish` (ubuntu, `contents: write`, `gh` CLI): тег → релиз с
     `--generate-notes` (или повторная загрузка с `--clobber`); `main` → prerelease
     `nightly` с `--clobber`;
   - `pages` (ubuntu): проверка секрета, скачивание артефакта, `git clone --depth 1`
     Pages-репозитория, замена `gl`, коммит от `github-actions[bot]`, `git push`;
     concurrency `ghl-pages-deploy`, `cancel-in-progress: false`.
4. Никаких сторонних actions кроме `checkout`, `upload-artifact`,
   `download-artifact`.

## C. Документация

1. README: `-Version`, раздел Continuous delivery (таблица workflow, тег-релиз,
   nightly, настройка `PAGES_DEPLOY_TOKEN`, concurrency), раскладка `.github/`,
   что CI гоняет suites 1–2 без окон.
2. README: бейджи ci/release.

## D. Приёмка

1. `actionlint` 1.7.12: 0 ошибок для трёх файлов.
2. Inline PowerShell-шаги `build.yml` выполнены в песочнице (резолв, сборка,
   verify, dist, summary) — зелёные.
3. Bash-шаги `release.yml`: `bash -n` чисто; резолв версии проверен для тега
   (`v1.2.3`→`1.2.3`, канал `tag`), ветки (`VERSION`, канал `nightly`), битого
   тега (отказ).
4. `Compile.ps1 -NoVersionBump -Version v2.5.1` штампует `2.5.1` и пишет VERSION;
   `-Version 1.2` отклоняется.
5. `Run-Tests.ps1 -Offline` — 26/26; `Run-MockTests.ps1` — 17/17; артефакт ASCII
   без BOM, XAML грузится.
6. Ветка `feature/m2-ci`; коммиты M1 и M2 раздельные, в `main` не пушится.

## E. Решения и ограничения

1. Оконные сценарии в CI не запускаются (`-NoUi`): у hosted-runner нет стабильного
   десктопа; окно и скриншот остаются локальной приёмкой.
2. `GITHUB_TOKEN` не может писать в другой репозиторий → `PAGES_DEPLOY_TOKEN`
   (fine-grained PAT, Contents: read+write только на Pages-репозиторий).
3. Теги только `vX.Y.Z` (`-suffix` допускается); иначе job `prepare` падает.
4. Публикация идемпотентна: повторный запуск перезаписывает ассеты (`--clobber`).
5. На Pages кладётся только `gl`; остальные файлы репозитория не трогаются.
6. Изменения в `main` публикуют nightly, а не стабильный релиз.

## F. Не входит

Темы и GIF (M3), редизайн UI (M4), избранные репозитории (M5).