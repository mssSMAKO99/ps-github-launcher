<#
    04-Downloader.ps1
    Streaming HttpClient download with progress, speed and cooperative cancel.
#>

function New-GhlError {
    <#
        Builds an ErrorRecord whose Kind travels with the exception, so workers
        can classify failures without parsing message strings.
    #>
    param(
        [string]$Kind = 'exception',
        [int]$Status = 0,
        [Parameter(Mandatory)][string]$Message
    )

    $ex = New-Object System.Exception($Message)
    $ex.Data['Kind'] = $Kind
    $ex.Data['Status'] = $Status
    return (New-Object System.Management.Automation.ErrorRecord(
            $ex, "Ghl.$Kind",
            [System.Management.Automation.ErrorCategory]::OperationStopped, $null))
}

function Stop-GhlPartialFile {
    param([string]$Path)

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { }
    }
}

function Invoke-GhlDownload {
    <#
        Downloads $Url to $OutFile (atomically, via a .part file).
        Writes progress into $Sync when supplied:
            ProgressPercent, BytesReceived, BytesTotal, SpeedBps, StatusText
        Throws 'CANCELLED' when $Sync.CancelRequested is set.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Token,
        [object]$Sync,
        [int]$TimeoutSec = 300
    )

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $part = "$OutFile.part"
    Stop-GhlPartialFile -Path $part

    $client = $null
    $req = $null
    $resp = $null
    $inStream = $null
    $outStream = $null

    try {
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.AllowAutoRedirect = $true
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None

        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
        [void]$req.Headers.TryAddWithoutValidation('User-Agent', $Global:GHL_UserAgent)
        [void]$req.Headers.TryAddWithoutValidation('Accept', '*/*')
        if ($Token) { [void]$req.Headers.TryAddWithoutValidation('Authorization', "Bearer $Token") }

        $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $status = [int]$resp.StatusCode

        if ($status -lt 200 -or $status -ge 300) {
            $bodyText = ''
            try { $bodyText = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { }
            $detail = ''
            try {
                $j = ConvertFrom-Json $bodyText
                if ($j.message) { $detail = [string]$j.message }
            } catch { }
            if (-not $detail) { $detail = $bodyText }
            if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }

            $kind = switch ($status) {
                401 { 'auth' }
                403 { 'ratelimit' }
                404 { 'notfound' }
                default { 'http' }
            }
            throw (New-GhlError -Kind $kind -Status $status `
                    -Message ("Download failed (HTTP $status). $detail").Trim())
        }

        $total = -1L
        if ($resp.Content.Headers.ContentLength) {
            $total = [long]$resp.Content.Headers.ContentLength
        }

        $suggested = ''
        try {
            if ($resp.Content.Headers.ContentDisposition -and $resp.Content.Headers.ContentDisposition.FileName) {
                $suggested = $resp.Content.Headers.ContentDisposition.FileName.Trim('"')
            }
        } catch { }

        if ($Sync) {
            $Sync.BytesTotal = $total
            $Sync.BytesReceived = 0L
            $Sync.SpeedBps = 0.0
            $Sync.ProgressPercent = if ($total -gt 0) { 0.0 } else { -1.0 }
            $Sync.StatusText = 'Starting download...'
        }

        $inStream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outStream = [IO.File]::Open($part, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)

        $buffer = New-Object byte[] 131072
        $received = 0L
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $lastReport = 0L
        $lastBytes = 0L
        $speed = 0.0

        while ($true) {
            if ($Sync -and $Sync.CancelRequested) { throw 'CANCELLED' }

            $read = $inStream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }

            $outStream.Write($buffer, 0, $read)
            $received += $read

            $elapsedMs = $sw.ElapsedMilliseconds
            if ($elapsedMs - $lastReport -ge 220) {
                $deltaBytes = $received - $lastBytes
                $deltaSec = [Math]::Max(0.001, ($elapsedMs - $lastReport) / 1000.0)
                $instant = $deltaBytes / $deltaSec
                $speed = if ($speed -le 0) { $instant } else { ($speed * 0.65) + ($instant * 0.35) }

                if ($Sync) {
                    $Sync.BytesReceived = $received
                    $Sync.SpeedBps = $speed
                    if ($total -gt 0) {
                        $Sync.ProgressPercent = [Math]::Min(100.0, ($received / $total) * 100.0)
                        if ($speed -gt 0) {
                            $left = ($total - $received) / $speed
                            $Sync.StatusText = 'Downloading {0} of {1} ({2}/s, {3} left)' -f `
                                (Format-GhlSize $received), (Format-GhlSize $total), (Format-GhlSize $speed), (Format-GhlDuration $left)
                        } else {
                            $Sync.StatusText = 'Downloading {0} of {1}' -f (Format-GhlSize $received), (Format-GhlSize $total)
                        }
                    } else {
                        $Sync.ProgressPercent = -1.0
                        $Sync.StatusText = 'Downloading {0} ({1}/s)' -f (Format-GhlSize $received), (Format-GhlSize $speed)
                    }
                }

                $lastReport = $elapsedMs
                $lastBytes = $received
            }
        }

        $outStream.Flush()
        $outStream.Dispose()
        $outStream = $null

        if ($Sync -and $Sync.CancelRequested) { throw 'CANCELLED' }

        # a truncated transfer must never be mistaken for a finished download
        if ($total -gt 0 -and $received -ne $total) {
            throw (New-GhlError -Kind 'incomplete' -Message ('Connection closed before the transfer finished ({0} of {1}).' -f (Format-GhlSize $received), (Format-GhlSize $total)))
        }

        Move-Item -LiteralPath $part -Destination $OutFile -Force

        if ($Sync) {
            $Sync.BytesReceived = $received
            if ($total -le 0) { $Sync.BytesTotal = $received }
            $Sync.ProgressPercent = 100.0
            $Sync.SpeedBps = 0.0
        }

        return [pscustomobject]@{
            Path          = $OutFile
            Bytes         = $received
            Total         = $total
            SuggestedName = $suggested
            FinalUrl      = $(if ($resp.RequestMessage -and $resp.RequestMessage.RequestUri) { [string]$resp.RequestMessage.RequestUri } else { $Url })
        }
    } finally {
        if ($outStream) { try { $outStream.Dispose() } catch { } }
        if ($inStream) { try { $inStream.Dispose() } catch { } }
        if ($resp) { try { $resp.Dispose() } catch { } }
        if ($req) { try { $req.Dispose() } catch { } }
        if ($client) { try { $client.Dispose() } catch { } }

        # never leave a fragment behind
        if (Test-Path -LiteralPath $part) { Stop-GhlPartialFile -Path $part }
    }
}

function Get-GhlFreeSpace {
    param([string]$Path)

    try {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
        $drive = New-Object IO.DriveInfo($root)
        return [long]$drive.AvailableFreeSpace
    } catch {
        return -1L
    }
}
