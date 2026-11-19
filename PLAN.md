Role: Senior PowerShell \& WPF Developer.

Goal: Architect and build a standalone WPF GUI GitHub Repository Launcher inspired by ChrisTitusTech WinUtil (single compiled `.ps1` executable via `irm <url> | iex`).



\### 1. Architecture \& Build Pipeline

\- \*\*Modular Dev -> Single File Prod:\*\*

&#x20; - `ui/MainWindow.xaml`: Borderless WPF UI, styles, Storyboard animations.

&#x20; - `src/Api.ps1`: GitHub REST API wrapper (repos, releases, rate-limit handling).

&#x20; - `src/Downloader.ps1`: Async download, extraction, executable discovery, launch logic.

&#x20; - `src/Main.ps1`: UI initialization, event bindings, `RunspacePool` + synchronized hashtable `$sync` state management.

&#x20; - `Compile.ps1`: Build script merging `.ps1` modules, embedding XAML, and Base64-encoding local assets into a single `GitHubLauncher.ps1`.

\- \*\*Concurrency:\*\* All network I/O and archive extractions MUST run in `RunspacePool` background threads. UI updates MUST marshal via `$window.Dispatcher.Invoke()`. Never block the STA UI thread.



\### 2. Core Features

1\. \*\*User Search \& Auth:\*\*

&#x20;  - Input for GitHub `username` + Enter/Button trigger (`GET https://github.com{username}/repos?per\_page=100`).

&#x20;  - Optional GitHub PAT (Personal Access Token) saved locally to bypass 60 req/hr limit.

&#x20;  - Real-time client-side search/filter bar across fetched repos (displaying Name, Description, Language, Stars, Updated Date).

2\. \*\*Repo Actions \& Download Modes:\*\*

&#x20;  - On repo select, fetch `GET https://github.com{username}/{repo}/releases/latest`.

&#x20;  - Mode selector: \*\*Source Code\*\* (`.zip` or `.tar.gz`) vs \*\*Latest Release\*\* (dropdown of release assets like `.exe`, `.msi`, `.zip`).

&#x20;  - \*\*"Run immediately after download"\*\* checkbox:

&#x20;    - Direct `.exe`/`.msi`: execute via `Start-Process`.

&#x20;    - Archives: extract (`Expand-Archive`), scan for executables (`.exe`, `.ps1`, `.bat`, `.cmd`), launch (prompt user selection if multiple found).

3\. \*\*Strict Directory Structure:\*\*

&#x20;  - Base path configurable in UI (default: `$env:USERPROFILE\\GitHub Downloads`).

&#x20;  - Nested structure: `{BaseDir}\\{Username}\\{RepositoryName}\\`.

&#x20;  - Per-repo \*\*"Open Folder"\*\* button (`explorer.exe`), enabled only if folder exists and is non-empty.

&#x20;  - Visual status badge per repo: `Downloaded` vs `Not Downloaded`.



\### 3. UI/UX \& Customization (WPF)

\- \*\*Window:\*\* Custom borderless (`WindowStyle="None"`, `AllowsTransparency="True"`, `CornerRadius="12"`), draggable titlebar, custom min/max/close buttons, dark theme default.

\- \*\*Customization:\*\* User-selectable custom background image (local file path or URL) + overlay opacity/dimming slider for text readability.

\- \*\*Persistence:\*\* Save settings (BaseDir, BackgroundPath, DimmingOpacity, PAT) to `%LocalAppData%\\GitHubLauncher\\config.json`.

\- \*\*Animations:\*\* XAML `Storyboard` transitions for hover states, loading spinner during API calls, and smooth bottom progress bar (MB downloaded, %, extraction status).



\### 4. Execution Protocol (Plan Phase)

Do NOT write application code yet. Output a structured `PLAN.md` covering:

1\. Exact folder tree and build concatenation order for `Compile.ps1`.

2\. Threading/Runspace architecture and `$sync` hashtable schema.

3\. `config.json` schema and error-handling strategy (404 user, 403 rate limit, no releases, network failure).

4\. Step-by-step implementation milestones.



