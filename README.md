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
| Favourites | Pin logins with the star button. The editable combo box offers them next time; managed in Settings. Stored case-insensitively, max 15. |
| Auth | Optional PAT (fine-grained or classic). Stored with DPAPI (`ConvertFrom-SecureString`), never in plaintext unless DPAPI is unavailable. |
| Filter | Client-side, 250 ms debounce, matches name / description / language, token-based (`rust cli`). |
| Releases | Latest release, or the newest one incl. pre-release when the checkbox is on. Repos without releases silently fall back to source mode. |
| Batch | Select several repositories (Ctrl/Shift-click, Ctrl+A) and download them in one go. Sequential, one at a time; a repo with no usable Windows asset is skipped and reported. |
| Assets | Full asset list, sorted: usable Windows packages first, other-OS builds and checksums greyed out. |
| Download | HttpClient streaming, real byte progress, smoothed MB/s, ETA, cancel button, `.part` + atomic rename. |
| Safety | Extracted executables get a `Zone.Identifier` mark (ZoneId=3). Published checksums are verified. Launching asks for confirmation with size, SHA-256 and Authenticode status. |
| Extract | `.zip` (zip-slip protected) and `.tar.gz` (member names *and* links validated). Single root folder is unwrapped automatically. |
| Launch | `.exe` / `.msi` / `.ps1` / `.bat` / `.cmd`. One candidate launches directly; several open a picker with "remember my choice". Off by default. |
| Layout | `{BaseDir}\{Username}\{Repository}` with a `.ghl.json` marker so a badge can distinguish *Downloaded* from *Partial*. |
| UI | Borderless, dark, the background image respects the rounded corners, custom titlebar + edge resize, animated spinner, toast notifications, settings overlay (gear). |
| Settings | Base folder, background, dimming, favourites, debug log, PAT, mode, checkboxes and window geometry persisted to `%LocalAppData%\GitHubLauncher\config.json`. |

### Launch safety

Running something pulled from GitHub is the riskiest thing this tool does:

| Guard | Behaviour |
| --- | --- |
| Opt-in | `RunAfterDownload` defaults to **false**; nothing starts unless you tick the box and press Download & run. |
| Confirmation | A dialog shows the file, size, repository, SHA-256 and signature status before anything executes. |
| Mark of the web | Downloaded executables and scripts carry `Zone.Identifier` (ZoneId=3), so SmartScreen and Defender see their origin. |
| `.ps1` policy | Scripts run under `-ExecutionPolicy RemoteSigned`, never `Bypass`. A downloaded script is therefore blocked unless it is signed. |
| Checksums | If the release ships `SHA256SUMS` / `checksums.txt`, the hash is verified and a mismatch aborts the download. |
| Links in archives | `.tar.gz` members marked as symlink or hard link are refused before extraction. |

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

---

## Repository layout

```
GithubLauncher/
├─ Compile.ps1              # build: concatenate + embed + validate
├─ dev.ps1                  # run straight from source
├─ VERSION                  # auto-incremented by the build
├─ GitHubLauncher.ps1       # build artifact (generated, not committed)
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
   ├─ Run-UiRepeat.ps1      # second-run regression
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
9. rejects any non-ASCII character in the output (only when writing BOM-less, which is the default),
10. writes `GitHubLauncher.ps1` as UTF-8 **without BOM** - required for `irm | iex`, where
    PowerShell 5.1 decodes the body as ANSI when the host sends no charset (gists and GitHub
    Pages both do that). Pass `-Bom` to opt out (then the file is only usable with `-File`),
11. prints size, encoding, line count and SHA-256.

## Develop

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\dev.ps1
```

`dev.ps1` dot-sources the modules and calls `Start-GitHubLauncher` — no build step, edits are live
after a restart. XAML is read from `ui/` instead of the embedded copy.

## Distribution: `irm | iex`

The artifact is meant to be published as a single flat file and run with:

```powershell
irm https://<you>.github.io/gl | iex
```

Everything (`Styles.xaml`, `MainWindow.xaml`, `PickerWindow.xaml`, the icon) is embedded, so there is
nothing else to host — one file, no folders.

Two constraints make or break that path, and both are enforced by `Compile.ps1`:

| Constraint | Why |
| --- | --- |
| **No UTF-8 BOM** | gists and GitHub Pages serve `.ps1` and extensionless files as `application/octet-stream` with no charset; PowerShell 5.1 then decodes the body as ANSI and the BOM becomes garbage (`EF BB BF`) before the first token, so `iex` fails to parse |
| **ASCII only** | same reason: a non-ASCII byte would be mangled by that ANSI decode |

`Invoke-RestMethod` turns such a response into a **String**, which is why `irm ... | iex` works while
`iwr ... | iex` does not (it returns `Byte[]`). `tests\Run-Tests.ps1` asserts both properties on the
built artifact.

---

## Test

Four suites, none of them require Pester:

```powershell
# 1) functional unit tests (add -Offline to skip the live GitHub calls)
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -Offline

# 2) deterministic suite: local mock GitHub API, no quota, includes the real window
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Run-MockTests.ps1

# 3) the "second run in the same session" regression
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-UiRepeat.ps1

# 4) live end-to-end against github.com (needs a repository that really exists)
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tools\Ui-Integration.ps1 -User octocat -Repo Hello-World
```

What they cover:

| Suite | Coverage |
| --- | --- |
| `Run-Tests.ps1` | formatting, path sanitising, zip-slip, archive unwrapping, executable ranking, DPAPI, config merge, favourites (incl. the single-element JSON trap), mark of the web, signature reporting, checksum matching, `RemoteSigned` policy, the no-BOM/ASCII guard, plus live API + worker tests when online |
| `Run-MockTests.ps1` | normalisation, 404/403 classification with reset time, asset compatibility/ranking, atomic + truncated + cancelled downloads, and four window scenarios: release asset -> exe -> marker (+ MOTW), no releases -> source, downloaded script blocked by RemoteSigned, multi-select batch |
| `Run-UiRepeat.ps1` | the window opens twice in one PowerShell session, runs via `-File`, and refuses to start in an MTA host |
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
  "FavoriteUsers": ["ChrisTitusTech", "microsoft"],
  "DownloadMode": "Release",
  "RunAfterDownload": false,
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
* `FavoriteUsers` is normalised on every read: trimmed, `@` stripped, de-duplicated
  case-insensitively, capped at 15. A one-element array comes back from JSON as a plain string, so
  readers always wrap it in `@()`.
* Set `GHL_CONFIG_DIR` to point the whole app at a different settings folder (used by the tests so
  they never touch your real config).

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
* Sources are deliberately **ASCII-only** and are written **without BOM** - see "Distribution" above.
* `.tar.gz` extraction needs `tar.exe` (Windows 10 1803+).
* `@()` around a `List<T>` throws `ArgumentException` on current Windows 11 PowerShell builds -
  materialise lists with `.ToArray()` instead.
* `New-Object Windows.Thickness 14, 8` (the 2-argument form) fails on this build; pass four values.
* The UI never creates a `System.Windows.Application`. `Application.Shutdown()` kills the dispatcher
  of its thread for good, and only one `Application` may exist per AppDomain, so the second start in
  the same session used to fail with a misleading "interface failed to load". Windows now carry their
  own styles (`<!-- GHL_STYLES_INJECT -->`) and run under `ShowDialog()`.
* Root-element attributes on a `Window` are evaluated *before* `Window.Resources`, so the window's own
  `Foreground` uses `DynamicResource`; everything below uses `StaticResource`.
* `AllowsTransparency="True"` means the window is layered: no hardware acceleration, but a true
  12 px rounded border on every Windows version. A `Border` does not clip its children, so the
  background layer gets an explicit `RectangleGeometry` clip to keep the corners rounded.
* Non-Windows release assets are listed but disabled.
* `irm | iex` is blocked by some AV/AMSI configurations; the script is deliberately not obfuscated.
