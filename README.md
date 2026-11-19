# GitHub Launcher

A single-file WPF launcher for GitHub repositories, in the spirit of ChrisTitusTech's WinUtil:
search a user's repositories, pick a release asset (or the source archive), download it into a
strict folder layout, and optionally run it right away.

It ships as **one compiled `.ps1`** that can be executed without cloning anything:

```powershell
irm msssmako99.github.io/gl | iex
```

or

```powershell
powershell.exe -STA -ExecutionPolicy Bypass -File GitHubLauncher.ps1
```

---

## Features

| Area | What you get |
| --- | --- |
| Search | Username + Enter. Fetches up to 500 public repositories (`sort=updated`). |
| Auth | Optional PAT (fine-grained or classic). Stored with DPAPI (`ConvertFrom-SecureString`), never in plaintext unless DPAPI is unavailable. |
| Filter | Client-side, 250 ms debounce, matches name / description / language, token-based (`rust cli`). |
| Releases | Latest release, or the newest one incl. pre-release when the checkbox is on. Repos without releases silently fall back to source mode. |
| Assets | Full asset list, sorted: usable Windows packages first, other-OS builds and checksums greyed out. |

## Asset compatibility

`Test-GhlAssetCompatible` / `Get-GhlAssetScore` decide what is offered and what is picked:

| Rule | Effect |
| --- | --- |
| `.exe`, `.msi`, `.msix`, `.appx`, `.zip`, `.tar.gz`, `.tgz`, `.ps1`, `.bat`, `.cmd` | candidate |
| `.deb`, `.rpm`, `.dmg`, `.pkg`, `.apk`, `.snap`, `.appimage`, `linux`, `darwin`, `macos`, `freebsd`, `android` in the name | rejected (shown greyed) |
| `checksum`, `sha256`, `.sig`, `.asc`, `debug`, `symbols` | rejected / penalised |
| `windows`, `win64`, `x64`, `amd64`, `setup`, `portable` | ranked up |
| `arm64`, `ia32`, `x86` (32-bit) | ranked down |

The list is ordered by compatibility then score, and the highest-scoring usable asset is pre-selected.

| Download | HttpClient streaming, real byte progress, smoothed MB/s, ETA, cancel button, `.part` + atomic rename. |
| Extract | `.zip` (zip-slip protected) and `.tar.gz` (member-list validation). Single root folder is unwrapped automatically. |
| Launch | `.exe` / `.msi` / `.ps1` / `.bat` / `.cmd`. One candidate launches directly; several open a picker with "remember my choice". |
| Layout | `{BaseDir}\{Username}\{Repository}` with a `.ghl.json` marker so a badge can distinguish *Downloaded* from *Partial*. |
| UI | Borderless, dark, rounded, custom titlebar + edge resize, animated spinner, toast notifications, custom background image (file or URL) with dimming. |
| Settings | Base folder, background, dimming, PAT, mode, checkboxes and window geometry persisted to `%LocalAppData%\GitHubLauncher\config.json`. |

---

## Repository layout

```
GithubLauncher/
├─ Compile.ps1              # build: concatenate + embed + validate
├─ dev.ps1                  # run straight from source
├─ VERSION                  # auto-incremented by the build
├─ GitHubLauncher.ps1       # build artifact (generated)
├─ ui/
│  ├─ Styles.xaml           # palette, control templates, DataGrid + scrollbar styles
│  ├─ MainWindow.xaml       # main window
│  ├─ PickerWindow.xaml     # "multiple executables" dialog
│  └─ assets/icon.png       # generated on first build
├─ src/
│  ├─ 01-Bootstrap.ps1      # paths, logging, STA guard, formatting helpers
│  ├─ 02-Config.ps1         # config.json, merge, DPAPI
│  ├─ 03-Api.ps1            # GitHub REST wrapper, error classification, asset scoring
│  ├─ 04-Downloader.ps1     # streaming download + progress + cancel
│  ├─ 05-Archive.ps1        # safe extraction + executable discovery
│  ├─ 06-Launcher.ps1       # folder layout, markers, process start
│  ├─ 07-Workers.ps1        # runspace script text
│  └─ 08-Main.ps1           # WPF host, event pump, state machine
├─ tools/
│  ├─ Test-Xaml.ps1         # STA XAML load check used by the build
│  ├─ Ui-Integration.ps1    # live end-to-end test against github.com
│  └─ Capture-Ui.ps1        # screenshot of the real window (mock API)
└─ tests/
   ├─ Run-Tests.ps1         # unit + live API tests
   ├─ Run-MockTests.ps1     # deterministic suite (mock API + window)
   ├─ Run-MockUi.ps1        # single window scenario, driven by Run-MockTests
   └─ MockApi.ps1           # HttpListener stand-in for the GitHub API
```

The numeric prefixes are the concatenation order used by `Compile.ps1`; the build fails if the
order does not match.

---

## Build

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\Compile.ps1
```

The build:

1. increments `VERSION`,
2. generates `ui/assets/icon.png` if missing,
3. embeds all three XAML documents and the icon as base64,
4. concatenates `src/*.ps1` in order,
5. rejects forbidden constructs (`Import-Module`, `#requires -Modules`, `Invoke-WebRequest`),
6. parses the result and fails on any error token,
7. loads the XAML through `XamlReader` in a separate STA process,
8. verifies the runspace worker closure (every `*-Ghl*` function a worker calls must be exported
   into the pool, otherwise the job dies at runtime with "not recognized"),
9. writes `GitHubLauncher.ps1` as UTF-8 **with BOM** (required by Windows PowerShell 5.1),
10. prints size, line count and SHA-256.

## Develop

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\dev.ps1
```

`dev.ps1` dot-sources the modules and calls `Start-GitHubLauncher` — no build step, edits are live
after a restart. XAML is read from `ui/` instead of the embedded copy.

## Test

Three suites, none of them require Pester:

```powershell
# 1) functional unit tests (add -Offline to skip the live GitHub calls)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -Offline

# 2) deterministic suite: local mock GitHub API, no quota, includes the real window
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Run-MockTests.ps1

# 3) live end-to-end against github.com (needs a repository that really exists)
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tools\Ui-Integration.ps1 -User octocat -Repo Hello-World
```

What they cover:

| Suite | Coverage |
| --- | --- |
| `Run-Tests.ps1` | formatting, path sanitising, zip-slip, archive unwrapping, executable ranking, DPAPI, config merge, marker/badge, plus live API + worker tests when online |
| `Run-MockTests.ps1` | normalisation, 404/403 classification with reset time, asset compatibility/ranking, atomic + truncated + cancelled downloads, and three window scenarios: release asset -> exe -> marker, no releases -> source archive, run-after-download |
| `Ui-Integration.ps1` | the same flow against api.github.com |

The mock server lives in `tests/MockApi.ps1` and is served by an `HttpListener` on `127.0.0.1`.
Point the app at any other endpoint with `GHL_API_BASE` (used by the tests; harmless in production):

```powershell
$env:GHL_API_BASE = 'http://127.0.0.1:18500'
```

Visual checks:

```powershell
# renders the window against the mock API and saves a PNG
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tools\Capture-Ui.ps1 -Out shot.png `
    -AfterDownload -Background C:\path\to\wallpaper.jpg
```

Smoke test that the real window boots and shuts down cleanly:

```powershell
$env:GHL_SMOKE_TEST = '1'
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\GitHubLauncher.ps1
```

`Start-GitHubLauncher -AutomationScript { param($window) ... }` exists so tests can drive the real UI
(the automation hooks into `Loaded`); it is not used in normal runs.

---

## Threading model

```
UI thread (STA)                         RunspacePool (1..4 threads)
────────────────                        ───────────────────────────
Window / DataGrid / ProgressBar         Invoke-GhlUserRepos
  ▲                                     Invoke-GhlLatestRelease
  │ DispatcherTimer, 120 ms             Invoke-GhlDownload
  │                                     Expand-GhlArchive
  └── reads $sync fields                Find-GhlExecutables
      dequeues $sync.Events  ◄────────── Events.Enqueue(@{ Kind = ... })
```

* Workers **never** touch WPF objects. They publish plain data into
  `$sync.Events` (`ConcurrentQueue[object]`) and counters into `$sync`.
* The UI drains the queue on a timer and re-renders. No `Dispatcher.Invoke` from a worker, so no
  deadlocks on close and no per-chunk message-pump flooding.
* `$sync` is a `[hashtable]::Synchronized` holding only primitives and the queue.
* One live job per kind; starting a new search stops the previous pipeline.
* Closing the window cancels the transfer, stops every pipeline, closes the pool — the host process
  exits instead of lingering.

`$sync` fields: `Phase`, `StatusText`, `ProgressPercent` (`-1` = unknown), `BytesReceived`,
`BytesTotal`, `SpeedBps`, `CancelRequested`, `Events`.

---

## Folder layout on disk

```
%USERPROFILE%\GitHub Downloads\          ← configurable
└─ ChrisTitusTech\
   └─ winutil\
      ├─ .ghl.json                       ← marker: mode, tag, date, files, launch target
      ├─ winutil.exe
      └─ ...
```

Badge logic:

| Marker | Files present | Badge |
| --- | --- | --- |
| yes | yes | `Downloaded` (green) |
| no | yes | `Partial` (amber) — interrupted or hand-placed |
| yes | no | `Partial` — everything was deleted manually |
| — | — | `Not downloaded` |

The marker is written **after** the archive was extracted and the file list collected, so a failed
or cancelled download can never be mistaken for a complete one.

---

## Configuration

`%LocalAppData%\GitHubLauncher\config.json`

```json
{
  "Version": 1,
  "BaseDir": "C:\\Users\\you\\GitHub Downloads",
  "BackgroundPath": "",
  "BackgroundKind": "file",
  "DimmingOpacity": 0.55,
  "PatCipher": "<DPAPI base64>",
  "PatPlain": "",
  "LastUser": "ChrisTitusTech",
  "DownloadMode": "Release",
  "RunAfterDownload": true,
  "IncludePrerelease": false,
  "Window": { "Width": 1280, "Height": 820, "Left": 100, "Top": 80, "Maximized": false },
  "DebugLog": false
}
```

* A corrupt file is renamed to `config.bad.json` and defaults are used — the app never fails to start
  because of settings.
* Saves are atomic (`File.Replace`).
* The token is encrypted with the current Windows user's DPAPI key. If encryption is unavailable it
  is written to `PatPlain` only because the user ticked "Remember token".

Logs: `%LocalAppData%\GitHubLauncher\logs\launcher.log` (rotated at 1 MB).

---

## Error handling

| Situation | Detection | What the user sees |
| --- | --- | --- |
| Unknown user | `404` on `/users/{u}/repos` | "GitHub user 'x' was not found." |
| No public repos | `200` + `[]` | empty state + warning toast |
| IP rate limit | `403` + `X-RateLimit-Remaining: 0` | message with reset time, token field focused |
| Bad PAT | `401` | "GitHub rejected the token", token field focused |
| No releases | `404` on `/releases/latest` | falls back to source mode, Release radio disabled |
| Truncated transfer | bytes < `Content-Length` | error, `.part` deleted |
| Broken archive | extract exception | error, marker not written, badge stays `Partial` |
| Zip-slip entry | path outside destination | archive rejected before anything is written |
| Not enough space | free < 115 % of asset | refuses to start the download |
| Network down | transport exception | "Network error: …", UI stays usable |
| Cancelled | `CancelRequested` | `.part` removed, buttons re-enabled |

Every failure path ends in a toast plus a status line — nothing is thrown into the WPF dispatcher.

---

## Known constraints

* **Windows PowerShell 5.1** is the target. PowerShell 7 runs MTA by default; the bootstrap detects
  that, relaunches itself with `-STA` when it has a script path, and otherwise explains the problem.
* Sources are deliberately **ASCII-only** and saved as UTF-8 **with BOM**. Windows PowerShell 5.1
  reads BOM-less UTF-8 as ANSI, which turns `·` or `—` into mojibake; keep new files ASCII to stay
  safe regardless of the editor.
* `.tar.gz` extraction needs `tar.exe` (Windows 10 1803+).
* `@()` around a `List<T>` throws `ArgumentException` on current Windows 11 PowerShell builds -
  materialise lists with `.ToArray()` instead.
* `AllowsTransparency="True"` means the window is layered: no hardware acceleration, but a true
  12 px rounded border on every Windows version. Edge resizing is implemented with Thumbs, and
  "maximize" fills the work area manually so the taskbar is never covered.
* Non-Windows release assets are listed but disabled.
* `irm | iex` is blocked by some AV/AMSI configurations; the script is deliberately not obfuscated.
