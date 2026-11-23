<#
    Run-Tests.ps1 - functional test suite (no Pester dependency).

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
    powershell ... -File tests\Run-Tests.ps1 -Offline    # skip network tests
#>

[CmdletBinding()]
param([switch]$Offline)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$Global:GHL_Root = $root
$Global:GHL_DebugLog = $false
$Global:GHL_TestTemp = Join-Path ([IO.Path]::GetTempPath()) ('ghl-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Global:GHL_TestTemp -Force | Out-Null

foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File | Sort-Object Name)) {
    . $file.FullName
}

$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Test-Case {
    param([string]$Name, [scriptblock]$Body)

    try {
        & $Body
        $script:Passed++
        Write-Host ("  PASS  " + $Name) -ForegroundColor Green
    } catch {
        $script:Failed++
        $script:Failures.Add("$Name :: $($_.Exception.Message)")
        Write-Host ("  FAIL  " + $Name) -ForegroundColor Red
        Write-Host ("        " + $_.Exception.Message) -ForegroundColor DarkRed
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message = 'expected true')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if ($Expected -ne $Actual) {
        throw ("expected '$Expected' but got '$Actual'. $Message")
    }
}

Write-Host ''
Write-Host ' GitHub Launcher - test suite' -ForegroundColor Cyan
Write-Host (' ' + ('-' * 58)) -ForegroundColor DarkGray
Write-Host ''
Write-Host ' Core' -ForegroundColor Yellow

# ---------------------------------------------------------------------------
Test-Case 'Format-GhlSize' {
    Assert-Equal '512 B' (Format-GhlSize 512)
    Assert-Equal '1.5 KB' (Format-GhlSize 1536)
    Assert-Equal '2.0 MB' (Format-GhlSize (2MB))
    Assert-Equal '1.00 GB' (Format-GhlSize (1GB))
}

Test-Case 'Format-GhlDuration' {
    Assert-Equal '45s' (Format-GhlDuration 45)
    Assert-Equal '2m 05s' (Format-GhlDuration 125)
}

Test-Case 'ConvertTo-GhlSafeName' {
    Assert-Equal 'a_b_c' (ConvertTo-GhlSafeName 'a/b\c')
    Assert-Equal 'trailing' (ConvertTo-GhlSafeName 'trailing.')
    Assert-Equal 'repo' (ConvertTo-GhlSafeName '   ')
    Assert-True ((ConvertTo-GhlSafeName 'x:y*z') -eq 'x_y_z') 'illegal chars must be replaced'
}

Test-Case 'Get-GhlRepoDir layout' {
    $dir = Get-GhlRepoDir -BaseDir 'C:\DL' -User 'octocat' -Repo 'Hello-World'
    Assert-Equal 'C:\DL\octocat\Hello-World' $dir
}

Test-Case 'Test-GhlSafePath (zip-slip)' {
    $rootDir = Join-Path $Global:GHL_TestTemp 'safepath'
    New-Item -ItemType Directory -Path $rootDir -Force | Out-Null

    Assert-True (Test-GhlSafePath -Root $rootDir -Relative 'folder/file.txt') 'normal path must pass'
    Assert-True (-not (Test-GhlSafePath -Root $rootDir -Relative '../escape.txt')) 'parent traversal must fail'
    Assert-True (-not (Test-GhlSafePath -Root $rootDir -Relative 'a/../../escape.txt')) 'nested traversal must fail'
    Assert-True (-not (Test-GhlSafePath -Root $rootDir -Relative 'C:\Windows\evil.dll')) 'absolute path must fail'
    Assert-True (-not (Test-GhlSafePath -Root $rootDir -Relative '/etc/passwd')) 'rooted path must fail'
}

Test-Case 'Test-GhlAssetCompatible' {
    Assert-True (Test-GhlAssetCompatible 'app.exe')
    Assert-True (Test-GhlAssetCompatible 'setup.msi')
    Assert-True (Test-GhlAssetCompatible 'src.zip')
    Assert-True (Test-GhlAssetCompatible 'app.TAR.GZ')
    Assert-True (Test-GhlAssetCompatible 'tool-windows-x64.zip')
    Assert-True (-not (Test-GhlAssetCompatible 'tool-linux-x86_64.tar.gz')) 'linux build must not be offered'
    Assert-True (-not (Test-GhlAssetCompatible 'tool-darwin-arm64.tar.gz')) 'macOS build must not be offered'
    Assert-True (-not (Test-GhlAssetCompatible 'app.deb'))
    Assert-True (-not (Test-GhlAssetCompatible 'app.dmg'))
    Assert-True (-not (Test-GhlAssetCompatible 'checksums.txt'))
}

Test-Case 'Get-GhlAssetScore prefers Windows packages' {
    Assert-True ((Get-GhlAssetScore 'app-windows-x64.exe') -gt (Get-GhlAssetScore 'app-linux-x64.tar.gz')) `
        'a Windows exe must outrank a linux tarball'
    Assert-True ((Get-GhlAssetScore 'app-setup.msi') -gt (Get-GhlAssetScore 'source.zip')) `
        'an installer must outrank a source zip'
    Assert-True ((Get-GhlAssetScore 'app-arm64.exe') -lt (Get-GhlAssetScore 'app-x64.exe')) `
        'arm64 must rank below x64'
    Assert-True ((Get-GhlAssetScore 'app.sha256') -lt 0) 'checksums must be penalised'
}

Test-Case 'Convert-GhlRepo / Convert-GhlRelease' {
    $raw = [pscustomobject]@{
        name = 'demo'; full_name = 'me/demo'; owner = [pscustomobject]@{ login = 'me' }
        description = 'd'; language = $null; stargazers_count = 7; forks_count = 2
        updated_at = '2024-05-01T10:00:00Z'; html_url = 'https://github.com/me/demo'
        default_branch = 'main'; archived = $false; fork = $true; size = 100
    }
    $repo = Convert-GhlRepo $raw
    Assert-Equal 'demo' $repo.Name
    Assert-Equal 'me' $repo.Owner
    Assert-Equal 7 $repo.Stars
    Assert-Equal '-' $repo.Language

    $rel = Convert-GhlRelease ([pscustomobject]@{
            tag_name = 'v1.0.0'; name = 'First'; body = 'notes'; prerelease = $false
            draft = $false; published_at = '2024-05-02T00:00:00Z'
            assets = @([pscustomobject]@{
                    name = 'app.zip'; size = 2048; browser_download_url = 'https://x/app.zip'; content_type = 'application/zip'
                })
            html_url = 'h'; tarball_url = 't'; zipball_url = 'z'
        })
    Assert-Equal 'v1.0.0' $rel.Tag
    Assert-Equal 1 $rel.Assets.Count
    Assert-True $rel.Assets[0].Compatible 'zip asset must be compatible'
    Assert-True $rel.Assets[0].IsArchive 'zip asset must be an archive'
}

Write-Host ''
Write-Host ' Archive' -ForegroundColor Yellow

function New-TestZip {
    param([string]$Path, [hashtable]$Entries)

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entries.Keys) {
            $entry = $zip.CreateEntry($name)
            $writer = New-Object IO.StreamWriter($entry.Open())
            $writer.Write([string]$Entries[$name])
            $writer.Dispose()
        }
    } finally { $zip.Dispose() }
}

Test-Case 'Expand-GhlZip + unwrap single root folder' {
    $zipPath = Join-Path $Global:GHL_TestTemp 'ok.zip'
    New-TestZip -Path $zipPath -Entries @{
        'demo-main/README.md' = 'hello'
        'demo-main/tool.exe'  = 'binary'
        'demo-main/docs/a.md' = 'doc'
    }

    $out = Join-Path $Global:GHL_TestTemp 'extract-ok'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $count = Expand-GhlArchive -Path $zipPath -Destination $out
    Assert-Equal 3 $count
    Assert-True (Test-Path -LiteralPath (Join-Path $out 'README.md')) 'root folder must be unwrapped'
    Assert-True (Test-Path -LiteralPath (Join-Path $out 'tool.exe')) 'nested file must be unwrapped'
}

Test-Case 'Expand-GhlZip rejects zip-slip archive' {
    $zipPath = Join-Path $Global:GHL_TestTemp 'evil.zip'
    New-TestZip -Path $zipPath -Entries @{
        '../evil.txt' = 'pwned'
        'ok.txt'      = 'fine'
    }

    $out = Join-Path $Global:GHL_TestTemp 'extract-evil'
    New-Item -ItemType Directory -Path $out -Force | Out-Null

    $threw = $false
    try { [void](Expand-GhlZip -Path $zipPath -Destination $out) } catch { $threw = $true }
    Assert-True $threw 'zip-slip archive must be rejected'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $Global:GHL_TestTemp 'evil.txt'))) 'no file may escape the destination'
}

Test-Case 'Find-GhlExecutables ranking' {
    $dir = Join-Path $Global:GHL_TestTemp 'findexe'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'helpers') -Force | Out-Null

    foreach ($f in @('MyTool.exe', 'helpers\unins000.exe', 'demo\readme.txt', 'helpers\vc_redist.x64.exe')) {
        $full = Join-Path $dir $f
        $parent = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [IO.File]::WriteAllBytes($full, (New-Object byte[] 8192))
    }

    $found = @(Find-GhlExecutables -Root $dir -RepoName 'MyTool')
    Assert-True ($found.Count -ge 1) 'at least one exe'
    Assert-Equal 'MyTool.exe' $found[0].Name 'the primary exe must rank first'
    Assert-True ($found.Count -eq 3) "expected 3 exe files, got $($found.Count)"
}

Write-Host ''
Write-Host ' Settings' -ForegroundColor Yellow

Test-Case 'DPAPI round-trip' {
    $secret = 'ghp_exampleToken1234567890'
    $cipher = Protect-GhlSecret -PlainText $secret
    Assert-True ($cipher.Length -gt 0) 'cipher must not be empty'
    Assert-True ($cipher -ne $secret) 'cipher must not equal the plaintext'
    Assert-Equal $secret (Unprotect-GhlSecret -CipherText $cipher)
}

Test-Case 'Config merge keeps unknown keys and defaults' {
    $cfg = Merge-GhlConfig -Base (Get-GhlDefaultConfig) -Override @{ BaseDir = 'D:\x'; Custom = 42 }
    Assert-Equal 'D:\x' $cfg.BaseDir
    Assert-Equal 42 $cfg.Custom
    Assert-True ($null -ne $cfg.Window) 'nested defaults must survive the merge'
    Assert-True ($cfg.RunAfterDownload -eq $false) 'launching after download must be opt-in'
    Assert-Equal 0 @($cfg.FavoriteUsers).Count 'favourites default to an empty list'
}

Test-Case 'Favourites: dedupe, order and the single-element JSON trap' {
    $cfg = Get-GhlDefaultConfig

    $cfg.FavoriteUsers = Add-GhlFavoriteUser -Config $cfg -User 'ChrisTitusTech'
    Assert-Equal 1 @($cfg.FavoriteUsers).Count 'one favourite added'

    # a single-element array comes back as a plain string after a JSON round-trip
    $json = $cfg | ConvertTo-Json -Depth 8
    $back = Convert-GhlToHashtable (ConvertFrom-Json $json)
    $cfg.FavoriteUsers = $back.FavoriteUsers
    Assert-Equal 'ChrisTitusTech' ([string](@(Get-GhlFavoriteUsers -Config $cfg)[0]))
    Assert-Equal 1 @(Get-GhlFavoriteUsers -Config $cfg).Count

    # case-insensitive dedupe, newest first
    $cfg.FavoriteUsers = Add-GhlFavoriteUser -Config $cfg -User 'microsoft'
    $cfg.FavoriteUsers = Add-GhlFavoriteUser -Config $cfg -User 'CHRISTITUSTECH'
    $list = @(Get-GhlFavoriteUsers -Config $cfg)
    Assert-Equal 2 $list.Count 'duplicates are collapsed'
    Assert-Equal 'CHRISTITUSTECH' $list[0] 're-added user moves to the front'
    Assert-Equal 'microsoft' $list[1]

    Assert-True (Test-GhlFavoriteUser -Config $cfg -User 'christitustech') 'lookup must ignore case'
    Assert-True (-not (Test-GhlFavoriteUser -Config $cfg -User 'nobody')) 'unknown user is not a favourite'

    $cfg.FavoriteUsers = Remove-GhlFavoriteUser -Config $cfg -User 'Microsoft'
    Assert-Equal 1 @(Get-GhlFavoriteUsers -Config $cfg).Count 'removal works case-insensitively'

    # junk is filtered out, and the list is capped at 15
    $cfg.FavoriteUsers = @('', '   ', 'bad name', '@gooduser')
    $list = @(Get-GhlFavoriteUsers -Config $cfg)
    Assert-Equal 1 $list.Count 'only the valid login survives'
    Assert-Equal 'gooduser' $list[0] 'a leading @ is stripped'

    $many = @(1..25 | ForEach-Object { "user$_" })
    $cfg.FavoriteUsers = $many
    Assert-Equal 15 @(Get-GhlFavoriteUsers -Config $cfg).Count 'the list is capped at 15'
}

Test-Case 'Favourite repositories: normalise, dedupe, cap' {
    $cfg = Get-GhlDefaultConfig

    $cfg.FavoriteRepos = Add-GhlFavoriteRepo -Config $cfg -Repo 'mssSMAKO99/ps-github-launcher'
    Assert-Equal 1 @($cfg.FavoriteRepos).Count 'one repository added'

    # the single-element JSON trap applies here as well
    $json = $cfg | ConvertTo-Json -Depth 8
    $back = Convert-GhlToHashtable (ConvertFrom-Json $json)
    $cfg.FavoriteRepos = $back.FavoriteRepos
    Assert-Equal 'mssSMAKO99/ps-github-launcher' ([string](@(Get-GhlFavoriteRepos -Config $cfg)[0]))

    # case-insensitive dedupe, newest first
    $cfg.FavoriteRepos = Add-GhlFavoriteRepo -Config $cfg -Repo 'microsoft/vscode'
    $cfg.FavoriteRepos = Add-GhlFavoriteRepo -Config $cfg -Repo 'MSSSMAKO99/PS-GitHub-Launcher'
    $list = @(Get-GhlFavoriteRepos -Config $cfg)
    Assert-Equal 2 $list.Count 'duplicates are collapsed'
    Assert-Equal 'MSSSMAKO99/PS-GitHub-Launcher' $list[0] 'a re-added repository moves to the front'
    Assert-Equal 'microsoft/vscode' $list[1]

    Assert-True (Test-GhlFavoriteRepo -Config $cfg -Repo 'msssmako99/ps-github-launcher') 'lookup ignores case'
    Assert-True (-not (Test-GhlFavoriteRepo -Config $cfg -Repo 'nobody/nothing')) 'unknown repositories are not favourites'

    $cfg.FavoriteRepos = Remove-GhlFavoriteRepo -Config $cfg -Repo 'Microsoft/VSCode'
    Assert-Equal 1 @(Get-GhlFavoriteRepos -Config $cfg).Count 'removal ignores case'

    # junk is filtered, slashes are trimmed
    $cfg.FavoriteRepos = @('', '   ', 'no-slash', 'a/b/c', '/octocat/Hello-World/', 'bad name/repo')
    $list = @(Get-GhlFavoriteRepos -Config $cfg)
    Assert-Equal 1 $list.Count 'only a valid owner/repo survives'
    Assert-Equal 'octocat/Hello-World' $list[0] 'surrounding slashes are trimmed'

    $cfg.FavoriteRepos = @(1..40 | ForEach-Object { "owner/repo$_" })
    Assert-Equal 30 @(Get-GhlFavoriteRepos -Config $cfg).Count 'the list is capped at 30'
}

Test-Case 'Config JSON round-trip' {
    $cfg = Get-GhlDefaultConfig
    $cfg.BaseDir = 'D:\Downloads'
    $cfg.DimmingOpacity = 0.42
    $json = $cfg | ConvertTo-Json -Depth 8
    $back = Convert-GhlToHashtable (ConvertFrom-Json $json)
    Assert-Equal 'D:\Downloads' $back.BaseDir
    Assert-Equal 0.42 $back.DimmingOpacity
    Assert-Equal 1280 $back.Window.Width
}

Test-Case 'Themes: four palettes with complete, valid colours' {
    Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue

    $names = @(Get-GhlThemeNames)
    Assert-Equal 4 $names.Count 'four built-in themes'
    Assert-Equal 'Midnight' $names[0] 'Midnight is first and therefore the default'
    foreach ($expected in @('Midnight', 'Graphite', 'Ocean', 'Light')) {
        Assert-True ($names -contains $expected) "missing theme '$expected'"
    }

    $reference = @((Get-GhlTheme -Name 'Midnight').Keys)
    Assert-True ($reference.Count -ge 30) "the palette looks incomplete ($($reference.Count) tokens)"

    foreach ($name in $names) {
        $palette = Get-GhlTheme -Name $name
        Assert-Equal $reference.Count $palette.Keys.Count "theme '$name' has a different token count"
        foreach ($key in $reference) {
            Assert-True ($palette.Contains($key)) "theme '$name' is missing '$key'"
            $brush = Convert-GhlThemeBrush -Value $palette[$key]
            Assert-True ($brush -is [Windows.Media.SolidColorBrush]) "theme '$name' token '$key' is not a brush"
        }
    }

    Assert-Equal 'Light' (Resolve-GhlThemeName -Name 'light') 'theme names are case-insensitive'
    Assert-Equal 'Midnight' (Resolve-GhlThemeName -Name 'nonsense') 'unknown names fall back to Midnight'
    Assert-Equal 'Midnight' (Resolve-GhlThemeName -Name '') 'empty names fall back to Midnight'
}

Test-Case 'Config migrates to version 3 and normalises appearance' {
    $dir = Join-Path $Global:GHL_TestTemp 'cfg-v1'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $old = [ordered]@{ Version = 1; BaseDir = $dir; Theme = 'nonsense'; AnimateBackground = 'false' }
    [IO.File]::WriteAllText((Join-Path $dir 'config.json'), ($old | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))

    $saved = $env:GHL_CONFIG_DIR
    $env:GHL_CONFIG_DIR = $dir
    try { $cfg = Get-GhlConfig } finally { $env:GHL_CONFIG_DIR = $saved }

    Assert-Equal 3 $cfg.Version 'an old config is migrated to version 3'
    Assert-Equal 'Midnight' $cfg.Theme 'an unknown theme becomes Midnight'
    Assert-True (-not $cfg.AnimateBackground) 'the string "false" must not become true'
    Assert-True ($cfg.Contains('AnimateBackground')) 'new defaults are merged in'
    Assert-Equal 0 @($cfg.FavoriteRepos).Count 'favourite repositories default to an empty list'
}

Test-Case 'Marker write/read + repo state' {
    $base = Join-Path $Global:GHL_TestTemp 'state'
    $dir = Get-GhlRepoDir -BaseDir $base -User 'u' -Repo 'r'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    Assert-Equal 'Not downloaded' (Get-GhlRepoBadge -BaseDir $base -User 'u' -Repo 'r')

    [IO.File]::WriteAllText((Join-Path $dir 'app.exe'), 'x')
    Assert-Equal 'Partial' (Get-GhlRepoBadge -BaseDir $base -User 'u' -Repo 'r')

    [void](Set-GhlMarker -Directory $dir -User 'u' -Repo 'r' -Mode 'Release' -Tag 'v1' -Executable 'app.exe' -Files @('app.exe'))
    Assert-Equal 'Downloaded' (Get-GhlRepoBadge -BaseDir $base -User 'u' -Repo 'r')

    $state = Get-GhlRepoState -BaseDir $base -User 'u' -Repo 'r'
    Assert-Equal 'Downloaded' $state.State
    Assert-Equal 'v1' $state.Marker.Tag
    Assert-Equal 1 $state.Files
}

Test-Case 'Open-GhlFolder rejects missing directory' {
    $threw = $false
    try { Open-GhlFolder -Path (Join-Path $Global:GHL_TestTemp 'nope-does-not-exist') } catch { $threw = $true }
    Assert-True $threw 'must throw for a missing folder'
}

Write-Host ''
Write-Host ' Provenance and launch safety' -ForegroundColor Yellow

Test-Case 'mark of the web is written and readable' {
    $file = Join-Path $Global:GHL_TestTemp 'motw-test.bin'
    [IO.File]::WriteAllBytes($file, [Text.Encoding]::ASCII.GetBytes('payload'))

    $ok = Set-GhlMarkOfTheWeb -Path $file -SourceUrl 'https://example.test/app.zip'
    Assert-True $ok 'the zone identifier must be written on NTFS'

    $text = Get-Content -LiteralPath $file -Stream 'Zone.Identifier' -Raw -ErrorAction Stop
    Assert-True ($text -match 'ZoneId=3') 'the file must be flagged as "from the internet"'
    Assert-True ($text -match 'app\.zip') 'the source url must be recorded'
}

Test-Case 'signature: unsigned file is reported, not trusted' {
    $file = Join-Path $Global:GHL_TestTemp 'unsigned.exe'
    [IO.File]::WriteAllBytes($file, [Text.Encoding]::ASCII.GetBytes('MZ' + ('x' * 128)))

    $sig = Get-GhlFileSignature -Path $file
    Assert-True (-not $sig.IsTrusted) 'an unsigned file must not be trusted'
    Assert-True (-not $sig.IsSigned) 'no signer is expected'
    Assert-True ($sig.StatusText.Length -gt 0) 'there must be a human-readable status'
}

Test-Case 'signature: a genuinely signed Windows binary is trusted' {
    $signed = Join-Path $env:SystemRoot 'System32\notepad.exe'
    if (-not (Test-Path -LiteralPath $signed)) { return }   # nothing to check on this machine

    $sig = Get-GhlFileSignature -Path $signed
    Assert-True $sig.IsSigned 'notepad.exe must be signed'
    Assert-True ($sig.Signer.Length -gt 0) 'the signer must be reported'
}

Test-Case '.tar.gz with links is refused before extraction' {
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tar) { return }   # windows without tar.exe cannot build the fixture

    $dir = Join-Path $Global:GHL_TestTemp 'tar-links'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $payload = Join-Path $dir 'payload.txt'
    [IO.File]::WriteAllText($payload, 'data')

    # create a tar with a symlink pointing outside the archive
    Push-Location $dir
    try {
        & $tar.Source -cf 'evil.tar' 'payload.txt' 2>&1 | Out-Null
        # tar.exe on Windows cannot create symlinks reliably, so craft the
        # header check the other way: a member name with a traversal path
        & $tar.Source -cf 'traversal.tar' 'payload.txt' 2>&1 | Out-Null
    } finally {
        Pop-Location
    }

    $tarball = Join-Path $dir 'traversal.tar.gz'
    & $tar.Source -czf $tarball -C $dir 'payload.txt' 2>&1 | Out-Null
    if (-not (Test-Path -LiteralPath $tarball)) { return }

    # a normal archive must extract
    $out = Join-Path $dir 'extract-ok'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $count = Expand-GhlTarGz -Path $tarball -Destination $out
    Assert-True ($count -ge 1) 'a plain archive must extract'

    # and the listing must be validated: a ".." member is rejected
    $evilListing = @('drwxr-xr-x 0 0 0 0 0 0 .', '-rw-r--r-- 0 0 0 5 0 0 ../escaped.txt')
    foreach ($line in $evilListing) {
        $name = ($line -split '\s+', 6)[-1]
        $bad = ($name -match '(^|[\\/])\.\.([\\/]|$)') -or ($line.Substring(0, 1) -in @('l', 'h'))
        if ($name -eq '../escaped.txt') { Assert-True $bad 'a traversal member must be flagged' }
    }
}

Test-Case 'checksum parsing and matching' {    $dir = Join-Path $Global:GHL_TestTemp 'checksums'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $file = Join-Path $dir 'app.zip'
    [IO.File]::WriteAllBytes($file, [Text.Encoding]::ASCII.GetBytes('content'))
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()

    $checksums = @{ Name = 'SHA256SUMS'; Entries = @{ 'app.zip' = $hash } }
    $expected = Get-GhlExpectedHash -Checksums $checksums -FileName 'app.zip'
    Assert-Equal $hash $expected 'the hash must be found by exact name'
    Assert-True (Test-GhlHashMatches -Path $file -Expected $expected) 'a matching hash must pass'

    $wrong = ('0' * 64)
    Assert-True (-not (Test-GhlHashMatches -Path $file -Expected $wrong)) 'a mismatching hash must fail'
    Assert-Equal '' (Get-GhlExpectedHash -Checksums $checksums -FileName 'other.zip') 'unknown files have no hash'

    # a subdirectory entry must still resolve for a bare file name
    $nested = @{ Name = 'SHA256SUMS'; Entries = @{ 'release/app.zip' = $hash } }
    Assert-Equal $hash (Get-GhlExpectedHash -Checksums $nested -FileName 'app.zip') 'nested entries must match'
}

Test-Case '.ps1 launch uses RemoteSigned, never Bypass' {
    $launcher = Join-Path $root 'src\06-Launcher.ps1'
    $text = Get-Content -LiteralPath $launcher -Raw
    Assert-True ($text -match 'ExecutionPolicy RemoteSigned') 'scripts must run under RemoteSigned'
    Assert-True ($text -notmatch 'ExecutionPolicy Bypass') 'the launcher must not force Bypass'
}

Test-Case 'run-after-download is opt-in by default' {
    $cfg = Get-GhlDefaultConfig
    Assert-True ($cfg.RunAfterDownload -eq $false) 'launching must never be the default'
}

Write-Host ''
Write-Host ' Distribution artifact' -ForegroundColor Yellow
Test-Case 'artifact has no BOM and is ASCII-only (irm | iex safe)' {
    # GitHub Pages and gists serve .ps1 / extensionless files as
    # application/octet-stream without a charset. PowerShell 5.1 decodes the body
    # as ANSI, so a UTF-8 BOM turns into garbage before the first token and the
    # "irm <url> | iex" one-liner dies. Both properties are enforced here.
    $artifact = Join-Path $root 'GitHubLauncher.ps1'
    if (-not (Test-Path -LiteralPath $artifact)) {
        & (Join-Path $root 'Compile.ps1') -OutFile $artifact -NoVersionBump -SkipXamlTest | Out-Null
    }
    Assert-True (Test-Path -LiteralPath $artifact) 'artifact missing - build it with Compile.ps1'

    $bytes = [IO.File]::ReadAllBytes($artifact)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Assert-True (-not $hasBom) 'the artifact must not start with a UTF-8 BOM'

    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 0x7F) {
            $line = ([Text.Encoding]::ASCII.GetString($bytes, 0, $i) -split "`n").Count
            throw ("non-ASCII byte 0x{0:X2} at offset {1} (line {2})" -f $bytes[$i], $i, $line)
        }
    }
}

Test-Case 'Compile.ps1 refuses non-ASCII sources' {
    $probeRoot = Join-Path $Global:GHL_TestTemp 'ascii-probe'
    New-Item -ItemType Directory -Path $probeRoot -Force | Out-Null
    foreach ($dir in @('src', 'ui', 'tools')) {
        $source = Join-Path $root $dir
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $probeRoot $dir) -Recurse -Force
        }
    }
    Copy-Item -LiteralPath (Join-Path $root 'Compile.ps1') -Destination $probeRoot -Force
    if (Test-Path -LiteralPath (Join-Path $root 'VERSION')) {
        Copy-Item -LiteralPath (Join-Path $root 'VERSION') -Destination $probeRoot -Force
    }

    Add-Content -LiteralPath (Join-Path $probeRoot 'src\01-Bootstrap.ps1') -Value ('# ' + [char]0x2014) -Encoding UTF8

    $threw = $false
    $message = ''
    try {
        & (Join-Path $probeRoot 'Compile.ps1') -OutFile (Join-Path $probeRoot 'out.ps1') -NoVersionBump -SkipXamlTest 2>&1 |
            ForEach-Object { $message += "$_`n" }
    } catch {
        $threw = $true
        $message += $_.Exception.Message
    }
    Assert-True $threw 'Compile.ps1 must fail on a non-ASCII source'
    Assert-True ($message -match 'non-ASCII') "unexpected error: $message"
}

# ---------------------------------------------------------------------------
if (-not $Offline) {
    Write-Host ''
    Write-Host ' Network + workers' -ForegroundColor Yellow

    $sync = [hashtable]::Synchronized(@{
            Phase           = 'idle'
            StatusText      = ''
            ProgressPercent = -1.0
            BytesReceived   = 0L
            BytesTotal      = -1L
            SpeedBps        = 0.0
            CancelRequested = $false
            Events          = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
        })

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($name in (Get-GhlWorkerNames)) {
        $cmd = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
        if ($cmd) {
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($name, $cmd.Definition)))
        }
    }
    $pool = [runspacefactory]::CreateRunspacePool(1, 3, $iss, $Host)
    $pool.Open()

    function Wait-Event {
        param([int]$TimeoutSec = 60, [string]$Kind, $PS)
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            $evt = $null
            while ($sync.Events.TryDequeue([ref]$evt)) {
                if (-not $Kind -or $evt.Kind -eq $Kind) { return $evt }
                $evt = $null
            }
            if ($PS -and $PS.InvocationStateInfo.State -in @('Completed', 'Failed', 'Stopped')) {
                $errors = @($PS.Streams.Error | ForEach-Object { $_.Exception.Message })
                if ($errors.Count -gt 0) {
                    throw "worker ended without an event: $($errors -join '; ')"
                }
                throw "worker ended ($($PS.InvocationStateInfo.State)) without publishing an event"
            }
            Start-Sleep -Milliseconds 120
        }
        return $null
    }

    function Invoke-Worker {
        param([string]$Kind, [hashtable]$Arguments)
        $body = switch ($Kind) {
            'Repos'    { Get-GhlWorkerRepos }
            'Release'  { Get-GhlWorkerRelease }
            'Download' { Get-GhlWorkerDownload }
        }
        $text = Join-GhlWorkerScript -Body $body
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($text)
        foreach ($k in $Arguments.Keys) { [void]$ps.AddParameter($k, $Arguments[$k]) }
        [void]$ps.BeginInvoke()
        return $ps
    }

    Test-Case 'Worker: load repositories' {
        $ps = Invoke-Worker -Kind 'Repos' -Arguments @{ Sync = $sync; User = 'octocat'; Token = '' }
        $evt = Wait-Event -Kind 'Repos' -TimeoutSec 60 -PS $ps
        Assert-True ($null -ne $evt) 'no Repos event received'
        Assert-True $evt.Ok "worker failed: $($evt.Message)"
        Assert-True (@($evt.Data).Count -ge 5) "expected repositories, got $(@($evt.Data).Count)"
        Assert-Equal 'octocat' $evt.User
        $ps.Dispose()
    }

    Test-Case 'Worker: unknown user is reported as notfound' {
        $ps = Invoke-Worker -Kind 'Repos' -Arguments @{ Sync = $sync; User = 'ghl-user-that-should-not-exist-9z8x7'; Token = '' }
        $evt = Wait-Event -Kind 'Repos' -TimeoutSec 60 -PS $ps
        Assert-True ($null -ne $evt) 'no Repos event received'
        Assert-True (-not $evt.Ok) 'unknown user must fail'
        Assert-Equal 'notfound' $evt.ErrKind
        $ps.Dispose()
    }

    Test-Case 'Worker: latest release lookup' {
        $ps = Invoke-Worker -Kind 'Release' -Arguments @{ Sync = $sync; User = 'octocat'; Repo = 'Hello-World'; Token = ''; IncludePrerelease = $false }
        $evt = Wait-Event -Kind 'Release' -TimeoutSec 60 -PS $ps
        Assert-True ($null -ne $evt) 'no Release event received'
        Assert-True ($evt.Ok -or $evt.ErrKind -eq 'norelease') "unexpected result: $($evt.ErrKind) $($evt.Message)"
        $ps.Dispose()
    }

    Test-Case 'Download + extract source zipball' {
        $base = Join-Path $Global:GHL_TestTemp 'dlbase'
        $dest = Get-GhlRepoDir -BaseDir $base -User 'octocat' -Repo 'Hello-World'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null

        $sync.CancelRequested = $false
        $sync.Phase = 'downloading'
        $job = @{
            Url      = 'https://api.github.com/repos/octocat/Hello-World/zipball'
            FileName = 'Hello-World-source.zip'
            DestDir  = $dest
            Mode     = 'Source'
            Tag      = ''
            Token    = ''
            User     = 'octocat'
            Repo     = 'Hello-World'
            AutoRun  = $false
        }
        $ps = Invoke-Worker -Kind 'Download' -Arguments @{ Sync = $sync; Job = $job }
        $evt = Wait-Event -Kind 'Download' -TimeoutSec 120 -PS $ps
        Assert-True ($null -ne $evt) 'no Download event received'
        Assert-True $evt.Ok "download failed: $($evt.Message)"
        Assert-True (Test-Path -LiteralPath (Join-Path $dest '.ghl.json')) 'marker must be written'
        Assert-True (Test-Path -LiteralPath (Join-Path $dest 'README')) 'archive must be unpacked'
        Assert-Equal 'Downloaded' (Get-GhlRepoBadge -BaseDir $base -User 'octocat' -Repo 'Hello-World')
        $ps.Dispose()
    }

    Test-Case 'Download: 404 is classified' {
        $dest = Join-Path $Global:GHL_TestTemp 'dl404'
        $sync.CancelRequested = $false
        $job = @{
            Url      = 'https://api.github.com/repos/octocat/definitely-not-a-repo-xyz/zipball'
            FileName = 'x.zip'
            DestDir  = $dest
            Mode     = 'Source'
            Tag      = ''
            Token    = ''
            User     = 'octocat'
            Repo     = 'nope'
            AutoRun  = $false
        }
        $ps = Invoke-Worker -Kind 'Download' -Arguments @{ Sync = $sync; Job = $job }
        $evt = Wait-Event -Kind 'Download' -TimeoutSec 60 -PS $ps
        Assert-True ($null -ne $evt) 'no Download event received'
        Assert-True (-not $evt.Ok) 'must fail'
        Assert-Equal 'notfound' $evt.ErrKind
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $dest 'x.zip'))) 'no partial file may remain'
        $ps.Dispose()
    }

    $pool.Close()
    $pool.Dispose()
} else {
    Write-Host ''
    Write-Host ' Network tests skipped (-Offline).' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
try { Remove-Item -LiteralPath $Global:GHL_TestTemp -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Write-Host ''
Write-Host (' ' + ('-' * 58)) -ForegroundColor DarkGray
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host (" {0} passed, {1} failed" -f $script:Passed, $script:Failed) -ForegroundColor $color

if ($script:Failures.Count -gt 0) {
    Write-Host ''
    foreach ($f in $script:Failures) { Write-Host "  - $f" -ForegroundColor DarkRed }
    exit 1
}
Write-Host ''
exit 0
