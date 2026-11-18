# GitHub Releases Launcher

> **A universal PowerShell downloader for GitHub Releases.**
> Enter a username, pick repositories, pick releases, pick files — done.

A single-file, GUI-driven PowerShell script that downloads **release assets**
(`.exe`, `.msi`, `.zip`, `.dmg`, `.AppImage`, `.deb`, `.apk`, …) from any GitHub
user's repositories. No `git`, no cloning, no source tarballs — just the files
the maintainer actually attached to a release.

Works on **Windows PowerShell 5.1** and **PowerShell 7+** on Windows, Linux,
and macOS.

---

## Why

Downloading a handful of tools from GitHub by hand is tedious: open repo → Releases →
expand "Assets" → click the right file → repeat. This launcher collapses that into
three `Out-GridView` windows:

```
User  →  Repositories  →  Releases  →  Files  →  Download
```

It also:

- auto-detects the file for **your** OS (Windows / Linux / macOS / Android / iOS)
  and sorts it to the top of the list;
- skips files you already have (same name + same size);
- works with **private repositories** if you provide a token;
- stores downloads in a tidy per-user, per-repo, per-version tree.

---

## Requirements

| | |
|---|---|
| PowerShell | 5.1 (Windows built-in) or 7+ (`pwsh`) |
| OS | Windows, Linux, macOS |
| Network | access to `api.github.com` and `github.com` |
| `curl.exe` | optional — only needed for private repos on PS 5.1 |
| `Out-GridView` | ships with Windows PowerShell; on `pwsh` (Linux/macOS) the script falls back to a text menu |

Nothing to install. No modules, no `git`, no package manager.

---

## Quick start

```powershell
# 1. Download the script (or clone the repo)
# 2. Run it
.\Github-Releases-Launcher.ps1 -DefaultUser notepad-plus-plus
```

You'll see:

1. **Repositories** grid — every public repo of that user.
2. **Releases** grid — the latest release of each repo you picked
   (use `-AllVersions` to see them all).
3. **Files** grid — every asset across the selected releases,
   with your OS's binaries pinned to the top.

Pick with **Ctrl+Click**, hit **OK**, wait for `[OK] Done. Succeeded: N, failed: M`.

If PowerShell refuses to run the script, see [Execution policy](#execution-policy).

---

## Usage examples

```powershell
# Interactive: prompt for a username, show latest releases only
.\Github-Releases-Launcher.ps1

# Default user, latest releases
.\Github-Releases-Launcher.ps1 -DefaultUser vlc

# All release versions of every repo of that user
.\Github-Releases-Launcher.ps1 -DefaultUser notepad-plus-plus -AllVersions

# Include beta / rc releases
.\Github-Releases-Launcher.ps1 -DefaultUser neovim -IncludePrerelease

# Skip the file picker: download every asset of every selected release
.\Github-Releases-Launcher.ps1 -DefaultUser jgraph -AllAssets

# Private repo: token via parameter
.\Github-Releases-Launcher.ps1 -DefaultUser myuser -Token ghp_xxxxxxxxxxxx

# Private repo: token via environment variable (recommended)
$env:GITHUB_TOKEN = "ghp_xxxxxxxxxxxx"
.\Github-Releases-Launcher.ps1 -DefaultUser myuser

# Custom download directory
.\Github-Releases-Launcher.ps1 -DefaultUser vlc -BaseDir D:\Downloads\GitHub
```

---

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-DefaultUser` | string | `YOUR_GITHUB_USERNAME` | Username pre-filled in the prompt. Press Enter to accept. |
| `-BaseDir` | string | `~/GitHubReleases` | Root download directory. |
| `-Token` | string | — | GitHub PAT. See [Tokens](#tokens). |
| `-AllVersions` | switch | off | Show every release of the selected repos, not just the latest. |
| `-IncludePrerelease` | switch | off | Include pre-release / draft releases. |
| `-AllAssets` | switch | off | Skip the file picker and download every asset. |

---

## Tokens

A token is **only** needed for **private repositories** (yours, or ones you
collaborate on). Public repos need nothing.

Three ways to supply it, in priority order:

1. **Parameter:** `-Token ghp_xxx`
2. **Environment variable:** `$env:GITHUB_TOKEN = "ghp_xxx"`
3. **Sidecar file:** create `token.txt` next to the script, one line, the token only.

> **Why the sidecar file?** So you can publish the script as-is without ever
> editing it, while still having private access locally. The script never writes
> the token anywhere else — it is not stored in downloaded files, not in
> PowerShell history (when using env/file), and is removed from `curl` arguments
> once the process exits.

**Scopes needed:**

- Public repos only → no token at all.
- Private repos you own → fine-grained PAT with `Contents: Read`, or classic PAT with `repo`.
- Just raising the API rate limit (60 → 5000 req/h) → any token with `public_repo`.

Generate a token: <https://github.com/settings/tokens>

---

## Where files land

```
~/GitHubReleases/
└── <username>/
    └── <repo-name>/
        └── <tag>/
            ├── setup.exe
            ├── setup.exe.sha256
            └── ...
```

Example:

```
~/GitHubReleases/notepad-plus-plus/notepad-plus-plus/v8.6.9/npp.8.6.9.Installer.x64.exe
```

- Re-runs are **idempotent**: an existing file with a matching size is skipped.
- A **partial** download (size mismatch) is re-fetched.
- A **failed** download leaves the partial file behind — delete it and re-run.

---

## How it works (short version)

1. `GET /users/{user}/repos?per_page=100&sort=updated` → list of repos.
2. `GET /repos/{owner}/{repo}/releases?per_page=50` → releases (drafts filtered out,
   pre-releases filtered unless `-IncludePrerelease`).
3. For each selected release, iterate over `assets[]`.
4. Download:
   - **Public:** `browser_download_url` via `Invoke-WebRequest` — no auth, no redirect games.
   - **Private:** `assets[].url` + `Accept: application/octet-stream` via
     `curl.exe -L`, so the `Authorization` header is **not** forwarded to
     `objects.githubusercontent.com` during the redirect.
5. Save into `<BaseDir>/<user>/<repo>/<tag>/<file>`.

API usage per run (rough):

| Step | Calls |
|---|---|
| Repos | 1 |
| Releases | 1 per selected repo |
| Assets | 0 (already in the release payload) |

Well within the 60 req/h anonymous limit for typical use; 5000 req/h with a token.

---

## Execution policy

Windows PowerShell blocks `.ps1` files by default. Three options:

**A. Per-invocation (recommended, no system changes):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Github-Releases-Launcher.ps1
```

**B. Right-click the file → "Run with PowerShell"** (works for scripts from the internet
only if you've unblocked them — see below).

**C. Unblock a downloaded copy once:**

```powershell
Unblock-File .\Github-Releases-Launcher.ps1
```

> ⚠️ **Do not** run `Set-ExecutionPolicy Unrestricted` globally to make this work.
> The per-invocation `-ExecutionPolicy Bypass` in option **A** is scoped to that one
> process and changes nothing on your system.

**D. Optional `Run.cmd`** — if you want double-click convenience, put this next to the
`.ps1`:

```bat
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Github-Releases-Launcher.ps1"
pause
```

---

## OS detection

The file picker tags every asset by OS and pins yours to the top. The mapping is
heuristic, based on filename patterns:

| Tag | Matched patterns (case-insensitive) |
|---|---|
| `Windows` | `.exe .msi .msix .appx`, or `win32 / win64 / windows` in the name |
| `Linux` | `.deb .rpm .appimage .snap .flatpak`, or `linux` in the name |
| `macOS` | `.dmg .pkg`, or `macos / osx / darwin` in the name |
| `Android` | `.apk .aab` |
| `iOS` | `.ipa` |
| `Any` | everything else (source tarballs, checksums, universal zips) |

Detection is **not** used to filter — everything is still visible. It only affects
sort order, so you can't accidentally download the wrong platform and wonder why
it doesn't run.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `The file ... is not digitally signed` / `cannot be loaded` | Execution policy — see [Execution policy](#execution-policy). |
| `Failed to fetch repositories: (403) rate limit exceeded` | You're over 60 req/h anonymous. Provide a token, or wait an hour. |
| `Failed to fetch repositories: (404) Not Found` | Typo in username, or the repo/user is private and you have no token. |
| `Failed to fetch releases: (404) Not Found` | Repo has no releases at all. If you wanted **source**, use a different tool. |
| `'$TargetUser' has no accessible repositories.` | User exists but has zero public repos (and no token was provided). |
| `Nothing selected.` | You clicked Cancel / OK with nothing picked. Re-run. |
| `Out-GridView is not recognized` | You're on `pwsh` Linux/macOS. Fall back to `-AllAssets`, or run the Windows version. |
| `curl returned exit code 22` | `curl --fail` saw an HTTP 4xx/5xx for that asset. Usually a stale URL or a private repo without a valid token. |
| Cyrillic / emoji render as `?` | Console codepage isn't UTF-8. Run `chcp 65001`, or use the all-ASCII version of the script. |
| `The term 'Invoke-RestMethod' is not recognized` | You're on PowerShell < 3.0. Install PowerShell 5.1 or 7+. |

---

## Limitations

- **Releases only.** This downloads files attached to releases. If a project publishes
  only tags or only source archives, there's nothing to download here — use `git clone`
  or the source-zip download instead.
- **First page of results.** `/users/{u}/repos` returns up to 100 repos (GitHub's max
  per page); `/repos/.../releases` returns up to 50 releases. If you need deeper
  pagination, open an issue — it's a small change.
- **No resume.** A failed download restarts from zero. `curl --retry` handles transient
  errors; a `Range`-based resume is not implemented.
- **No signature verification.** Checksums published as separate assets are downloaded
  alongside the binary, but nothing is verified automatically — do that yourself if
  you care.
- **`Out-GridView` is Windows-only.** On `pwsh` Linux/macOS, use `-AllAssets` or accept
  the text fallback for the file selection step.
- **Collaborator repos** are not listed by `/users/{owner}/repos`. Only repos the
  owner publicly exposes show up. If you need to list repos where *you* are a
  collaborator, tell me and I'll add a `-MyRepos` mode backed by `/user/repos?affiliation=collaborator`.

---

## Security notes

- The script does **not** phone home. The only outbound traffic is to
  `api.github.com` and `github.com` / `objects.githubusercontent.com`.
- The token is **never written to disk** by the script (except that you can choose
  to store it yourself in `token.txt` or `$env:GITHUB_TOKEN`).
- Private-asset downloads use `curl -L` specifically because `Invoke-WebRequest` on
  PowerShell 5.1 drops the `Authorization` header during the
  `api.github.com → objects.githubusercontent.com` redirect, which would 403. Using
  `curl` also means the token never appears in the PowerShell transcript.
- Downloaded files are **not** executed, **not** unpacked, and **not** verified.
  Treat them like any other file you pull from the internet.
- `token.txt` **must be added to `.gitignore`** if you fork this repo. If you accidentally
  commit a token, revoke it immediately at <https://github.com/settings/tokens>.

---

## License

MIT — do whatever you want, no warranty.

---

## See also

- [GitHub REST API — Repositories](https://docs.github.com/en/rest/repos/repos)
- [GitHub REST API — Releases](https://docs.github.com/en/rest/releases/releases)
- [Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
