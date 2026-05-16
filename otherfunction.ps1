#Requires -Version 5.1
# Standalone Steam one-click installer script.
# No external project files or Python required.

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$Ignored
)

$script:HammerLaunch = $true
$script:SelfPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($script:SelfPath)) {
    $script:SelfPath = $MyInvocation.MyCommand.Path
}

# Re-run once with -NoProfile (Hammer does not pass it; profiles can break the installer)
if ($env:STEAM_INSTALLER_NOPROFILE -ne '1' -and -not [string]::IsNullOrWhiteSpace($script:SelfPath) -and (Test-Path -LiteralPath $script:SelfPath)) {
    $env:STEAM_INSTALLER_NOPROFILE = '1'
    $childArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$($script:SelfPath)`""
    try {
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $childArgs -Wait -PassThru -WindowStyle Normal
        $code = 0
        if ($null -ne $proc -and $null -ne $proc.ExitCode) { $code = $proc.ExitCode }
        exit $code
    } catch {
        Write-Host "[WARN] NoProfile relaunch failed, continuing in current session..." -ForegroundColor Yellow
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$TargetVersion   = "1778281814"
$BetaBranch      = "Stable Client"
$UnlockModeLabel = "Unlock Mode 3 (Stable)"
$Workers         = 16
$ServerPort      = 1666
$PinnedCommitSha = "e13adfc596d92cea6ff41f26a69d925c35848428"

$RepoOwner     = "SteamTracking"
$RepoName      = "SteamTracking"
$ManifestPath  = "ClientManifest/steam_client_win64"
$ClientBaseUrl = "https://client-update.fastly.steamstatic.com"
$UserAgent     = "hammer-otherfunction-steam-installer/1.0"

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Info([string]$Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-WarnText([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Ok([string]$Message) { Write-Host "[ OK ] $Message" -ForegroundColor Green }

function Wait-ForKey {
    Write-Host ""
    Write-Host "  Press any key to close..." -ForegroundColor DarkGray
    try {
        if ($Host.Name -eq 'ConsoleHost') {
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            return
        }
    } catch { }
    try { cmd /c pause | Out-Null } catch { Start-Sleep -Seconds 8 }
}

function Resolve-DefaultSteamPath {
    foreach ($p in @(
            (Join-Path ${env:ProgramFiles(x86)} "Steam\steam.exe"),
            (Join-Path $env:ProgramFiles "Steam\steam.exe")
        )) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return (Join-Path ${env:ProgramFiles(x86)} "Steam\steam.exe")
}

function Format-Bytes([long]$Bytes) {
    $units = @("B", "KB", "MB", "GB", "TB")
    $size = [double]$Bytes
    $idx = 0
    while ($size -ge 1024 -and $idx -lt ($units.Length - 1)) { $size /= 1024.0; $idx++ }
    return "{0:N1}{1}" -f $size, $units[$idx]
}

function Format-Eta([double]$Seconds) {
    if ($Seconds -lt 0 -or [double]::IsInfinity($Seconds) -or [double]::IsNaN($Seconds)) { return "--:--" }
    $total = [int][Math]::Floor($Seconds)
    $h = [int]([Math]::Floor($total / 3600))
    $rem = $total % 3600
    $m = [int]([Math]::Floor($rem / 60))
    $s = [int]($rem % 60)
    if ($h -gt 0) { return ('{0:D2}:{1:D2}:{2:D2}' -f $h, $m, $s) }
    return ('{0:D2}:{1:D2}' -f $m, $s)
}

function Get-ShortFileName([string]$Name, [int]$MaxLength = 44) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    if ($Name.Length -le $MaxLength) { return $Name }
    return ($Name.Substring(0, $MaxLength - 3) + "...")
}

function New-ProgressBar([double]$Percent, [int]$Width = 28) {
    $pct = [Math]::Max(0.0, [Math]::Min(100.0, $Percent))
    $filled = [int](($pct / 100.0) * $Width)
    return "[" + ("#" * $filled) + ("-" * ($Width - $filled)) + "]"
}

function Show-InstallBanner {
    param([string]$CurrentVersion, [string]$SteamExe)
    $action = "INSTALL"
    if ($CurrentVersion) {
        if ($CurrentVersion -eq $TargetVersion) { $action = "REINSTALL (refresh same build)" }
        elseif ([long]$CurrentVersion -lt [long]$TargetVersion) { $action = "UPGRADE" }
        else { $action = "DOWNGRADE" }
    }
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor DarkCyan
    Write-Host "       STEAM ONE-CLICK INSTALLER" -ForegroundColor White
    Write-Host "  ================================================================" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  Action          : $action" -ForegroundColor Yellow
    Write-Host "  Beta Branch     : $BetaBranch" -ForegroundColor White
    Write-Host "  Target Version  : $TargetVersion" -ForegroundColor Green
    Write-Host "  Reference Pin   : $TargetVersion ($UnlockModeLabel)" -ForegroundColor Green
    Write-Host "  Steam Path      : $SteamExe" -ForegroundColor Gray
    Write-Host "  Cache           : $CacheRoot" -ForegroundColor Gray
    if ($CurrentVersion) {
        Write-Host "  Installed Now   : $CurrentVersion" -ForegroundColor Magenta
    } else {
        Write-Host "  Installed Now   : (unknown)" -ForegroundColor DarkYellow
    }
    Write-Host ""
    Write-Host "  ================================================================" -ForegroundColor DarkCyan
    Write-Host ""
}

function Invoke-HttpText {
    param([string]$Url, [int]$TimeoutSec = 120)
    try {
        $resp = Invoke-WebRequest -Uri $Url -Headers @{ "User-Agent" = $UserAgent } `
            -UseBasicParsing -TimeoutSec $TimeoutSec
        return [string]$resp.Content
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            if ($code -eq 403) { throw "Manifest host rate limit (HTTP 403). Wait and try Other Functions again." }
            throw "HTTP $code : $msg"
        }
        throw "Network error: $msg"
    }
}

function Get-ManifestAtRef([string]$Ref) {
    $rawUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Ref/$ManifestPath"
    Invoke-HttpText -Url $rawUrl
}

function Get-VersionFromManifest([string]$ManifestText) {
    $m = [regex]::Match($ManifestText, '"version"\s+"(?<v>\d+)"')
    if (-not $m.Success) { throw "Version not found in manifest." }
    $m.Groups["v"].Value
}

function Get-FilesFromManifest([string]$ManifestText) {
    $seen = @{}
    foreach ($m in [regex]::Matches($ManifestText, '"file"\s+"(?<f>[^"]+)"')) { $seen[$m.Groups["f"].Value] = $true }
    foreach ($m in [regex]::Matches($ManifestText, '"zipvz"\s+"(?<z>[^"]+)"')) { $seen[$m.Groups["z"].Value] = $true }
    return @($seen.Keys | Sort-Object)
}

function Resolve-Manifest {
    $cached = Join-Path $CacheRoot "steam_client_win64"
    if (Test-Path -LiteralPath $cached) {
        $text = Get-Content -LiteralPath $cached -Raw
        if ((Get-VersionFromManifest -ManifestText $text) -eq $TargetVersion) {
            Write-Info "Using cached manifest."
            return [pscustomobject]@{ Text = $text; CommitSha = "cache" }
        }
    }
    Write-Info "Downloading manifest for build $TargetVersion (1 request)..."
    $text = Get-ManifestAtRef -Ref $PinnedCommitSha
    if ((Get-VersionFromManifest -ManifestText $text) -ne $TargetVersion) {
        throw "Manifest version mismatch for build $TargetVersion."
    }
    Write-Ok "Manifest loaded."
    return [pscustomobject]@{ Text = $text; CommitSha = $PinnedCommitSha }
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -ItemType Directory -Path $Path -Force) }
}

function Test-CacheComplete([string]$Root, [string[]]$Files) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root "cache-complete.ok"))) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Root "steam_client_win64"))) { return $false }
    foreach ($f in $Files) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $f))) { return $false }
    }
    return $true
}

function Write-CacheArtifacts([string]$Root, [string]$ManifestText, [string[]]$Files) {
    Ensure-Directory -Path $Root
    Set-Content -LiteralPath (Join-Path $Root "steam_client_win64") -Value $ManifestText -Encoding UTF8 -NoNewline
    Set-Content -LiteralPath (Join-Path $Root "steam_client_publicbeta_win64") -Value $ManifestText -Encoding UTF8 -NoNewline
    $Files | ForEach-Object { "$ClientBaseUrl/$_" } | Set-Content -LiteralPath (Join-Path $Root "sources.txt") -Encoding ASCII
}

function Get-LocalClientVersion([string]$SteamDir) {
    foreach ($rel in @("package\steam_client_win64.manifest", "package\steam_client_publicbeta_win64.manifest")) {
        $file = Join-Path $SteamDir $rel
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $m = [regex]::Match((Get-Content -LiteralPath $file -Raw), '"version"\s+"(?<v>\d+)"')
        if ($m.Success) { return $m.Groups["v"].Value }
    }
    return $null
}

function Get-MissingPackageFiles {
    param([string[]]$Files, [string]$Destination)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($f in $Files) {
        $path = Join-Path $Destination $f
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Length -gt 0)) {
            continue
        }
        $part = "$path.part"
        if (Test-Path -LiteralPath $part) {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        }
        $list.Add($f)
    }
    return @($list)
}

function Start-ParallelDownload {
    param([string[]]$Files, [string]$Destination, [int]$MaxWorkers)

    $completeMarker = Join-Path $Destination "cache-complete.ok"
    if (Test-Path -LiteralPath $completeMarker) {
        Remove-Item -LiteralPath $completeMarker -Force -ErrorAction SilentlyContinue
    }

    $missing = Get-MissingPackageFiles -Files $Files -Destination $Destination
    if ($missing.Count -eq 0) {
        Set-Content -LiteralPath $completeMarker -Value ((Get-Date).ToUniversalTime().ToString("o")) -Encoding ASCII
        Write-Ok "All package files already in cache."
        return
    }

    $parallelCount = [Math]::Min([Math]::Max(1, $MaxWorkers), $missing.Count)
    Write-Info "Downloading $($missing.Count) file(s) with $parallelCount parallel worker(s)..."

    $sync = [hashtable]::Synchronized(@{
            FilesDone        = 0
            DownloadedBytes  = [long]0
            TotalBytes       = [long]0
            Lock             = New-Object object
        })
    $errors = [System.Collections.Concurrent.ConcurrentBag[string]]::new()

    $pool = [runspacefactory]::CreateRunspacePool(1, $parallelCount)
    $pool.Open()
    $runspaces = New-Object System.Collections.Generic.List[object]

    try {
        foreach ($fileName in $missing) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript({
                    param($FileName, $Dest, $BaseUrl, $Ua, $Shared, $ErrBag)
                    $outPath = Join-Path $Dest $FileName
                    if ((Test-Path -LiteralPath $outPath) -and ((Get-Item -LiteralPath $outPath).Length -gt 0)) {
                        [System.Threading.Monitor]::Enter($Shared.Lock)
                        try { $Shared.FilesDone++ } finally { [System.Threading.Monitor]::Exit($Shared.Lock) }
                        return
                    }

                    $partPath = "$outPath.part"
                    if (Test-Path -LiteralPath $partPath) {
                        Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
                    }

                    $url = "$BaseUrl/$FileName"
                    $req = [System.Net.HttpWebRequest]::Create($url)
                    $req.UserAgent = $Ua
                    $req.Timeout = 120000
                    $req.ReadWriteTimeout = 120000
                    $resp = $null
                    $stream = $null
                    $fs = $null

                    try {
                        $resp = $req.GetResponse()
                        $total = 0L
                        if ($resp.ContentLength -gt 0) {
                            $total = [long]$resp.ContentLength
                            [System.Threading.Monitor]::Enter($Shared.Lock)
                            try { $Shared.TotalBytes += $total } finally { [System.Threading.Monitor]::Exit($Shared.Lock) }
                        }

                        $stream = $resp.GetResponseStream()
                        $fs = [System.IO.File]::Create($partPath)
                        $buf = New-Object byte[] (512 * 1024)
                        while ($true) {
                            $read = $stream.Read($buf, 0, $buf.Length)
                            if ($read -le 0) { break }
                            $fs.Write($buf, 0, $read)
                            [System.Threading.Monitor]::Enter($Shared.Lock)
                            try { $Shared.DownloadedBytes += $read } finally { [System.Threading.Monitor]::Exit($Shared.Lock) }
                        }
                        $fs.Dispose()
                        $fs = $null
                        $stream.Dispose()
                        $stream = $null
                        $resp.Dispose()
                        $resp = $null

                        $finalLen = (Get-Item -LiteralPath $partPath).Length
                        if ($total -gt 0 -and $finalLen -lt $total) {
                            throw "Incomplete file ($finalLen / $total bytes)."
                        }

                        Move-Item -LiteralPath $partPath -Destination $outPath -Force
                        [System.Threading.Monitor]::Enter($Shared.Lock)
                        try { $Shared.FilesDone++ } finally { [System.Threading.Monitor]::Exit($Shared.Lock) }
                    } catch {
                        if ($fs) { $fs.Dispose() }
                        if ($stream) { $stream.Dispose() }
                        if ($resp) { $resp.Dispose() }
                        if (Test-Path -LiteralPath $partPath) {
                            Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
                        }
                        $ErrBag.Add("$FileName : $($_.Exception.Message)")
                    }
                }).AddArgument($fileName).
                AddArgument($Destination).
                AddArgument($ClientBaseUrl).
                AddArgument($UserAgent).
                AddArgument($sync).
                AddArgument($errors)
            $runspaces.Add([pscustomobject]@{
                    PS     = $ps
                    Handle = $ps.BeginInvoke()
                }) | Out-Null
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $spin = 0
        $lastBytes = [long]0
        $lastProgressAt = [DateTime]::UtcNow
        $maxWaitMinutes = 60

        while ($true) {
            $doneCount = @($runspaces | Where-Object { $_.Handle.IsCompleted }).Count
            [System.Threading.Monitor]::Enter($sync.Lock)
            try {
                $filesDone = [int]$sync.FilesDone
                $downloaded = [long]$sync.DownloadedBytes
                $knownTotal = [long]$sync.TotalBytes
            } finally {
                [System.Threading.Monitor]::Exit($sync.Lock)
            }

            if ($downloaded -gt $lastBytes) {
                $lastBytes = $downloaded
                $lastProgressAt = [DateTime]::UtcNow
            }

            $elapsed = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
            $speed = $downloaded / $elapsed
            $filesPct = if ($missing.Count -gt 0) { ($filesDone * 100.0) / $missing.Count } else { 100.0 }
            $bytesPct = if ($knownTotal -gt 0) { ($downloaded * 100.0) / $knownTotal } else { $filesPct }
            $eta = if ($speed -gt 0 -and $knownTotal -gt $downloaded) { ($knownTotal - $downloaded) / $speed } else { [double]::PositiveInfinity }
            $barPct = [Math]::Min(100.0, $bytesPct)
            $status = "{0} Files {1}/{2} {3} {4:N1}% | Bytes {5} {6:N1}% | {7}/s | ETA {8}" -f `
                @('|', '/', '-', '\')[$spin % 4],
                $filesDone,
                $missing.Count,
                (New-ProgressBar $filesPct 12),
                $filesPct,
                (New-ProgressBar $barPct 12),
                $barPct,
                (Format-Bytes ([long]$speed)),
                (Format-Eta $eta)
            Write-Progress -Id 1 -Activity "Downloading Steam packages" -Status $status -PercentComplete ([int]$barPct)
            $spin++

            if ($doneCount -ge $runspaces.Count) { break }
            if ($sw.Elapsed.TotalMinutes -ge $maxWaitMinutes) {
                throw "Download timed out after $maxWaitMinutes minutes."
            }
            if ((([DateTime]::UtcNow) - $lastProgressAt).TotalSeconds -ge 180 -and $doneCount -lt $runspaces.Count) {
                throw "Download stalled for 3 minutes. Check connection and run Other Functions again."
            }
            Start-Sleep -Milliseconds 120
        }

        foreach ($entry in $runspaces) {
            try { $entry.PS.EndInvoke($entry.Handle) | Out-Null } catch { }
            $entry.PS.Dispose()
        }

        if ($errors.Count -gt 0) {
            throw "Download failed on $($errors.Count) file(s). First error: $($errors | Select-Object -First 1)"
        }

        $stillMissing = Get-MissingPackageFiles -Files $Files -Destination $Destination
        if ($stillMissing.Count -gt 0) {
            throw "Cache incomplete ($($stillMissing.Count) file(s) still missing)."
        }

        Set-Content -LiteralPath $completeMarker -Value ((Get-Date).ToUniversalTime().ToString("o")) -Encoding ASCII
        Write-Progress -Id 1 -Activity "Downloading Steam packages" -Completed
        Write-Ok "Download complete."
    } finally {
        Write-Progress -Id 1 -Activity "Downloading Steam packages" -Completed
        $pool.Close()
        $pool.Dispose()
    }
}

function Stop-SteamProcesses {
    foreach ($proc in @("steam.exe", "steamwebhelper.exe", "steamservice.exe")) {
        Start-Process -FilePath "taskkill" -ArgumentList "/F", "/IM", $proc -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
    }
}

function Set-SteamCfg([string]$InstallDir) {
    $cfg = Join-Path $InstallDir "steam.cfg"
    @("BootStrapperInhibitAll=enable", "BootStrapperForceSelfUpdate=disable") | Set-Content -LiteralPath $cfg -Encoding ASCII
    Write-Ok "Updates locked: $cfg"
}

function Start-LocalPackageServer([string]$RootDir, [int]$Port) {
    $job = Start-Job -ScriptBlock {
        param($ServeRoot, $ServePort)
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:$ServePort/")
        $listener.Start()
        try {
            while ($listener.IsListening) {
                $ctx = $listener.GetContext()
                $path = $ctx.Request.Url.AbsolutePath.TrimStart('/')
                if ([string]::IsNullOrWhiteSpace($path)) { $ctx.Response.StatusCode = 404; $ctx.Response.Close(); continue }
                $fullPath = Join-Path $ServeRoot ($path -replace '/', [IO.Path]::DirectorySeparatorChar)
                if (-not (Test-Path -LiteralPath $fullPath)) { $ctx.Response.StatusCode = 404; $ctx.Response.Close(); continue }
                $bytes = [System.IO.File]::ReadAllBytes($fullPath)
                $ctx.Response.StatusCode = 200
                $ctx.Response.ContentLength64 = $bytes.Length
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $ctx.Response.OutputStream.Close()
                $ctx.Response.Close()
            }
        } finally { $listener.Stop(); $listener.Close() }
    } -ArgumentList $RootDir, $Port
    Start-Sleep -Milliseconds 800
    return $job
}

function Invoke-SteamApply([string]$SteamExe, [int]$Port) {
    $steamDir = Split-Path -Parent $SteamExe
    Write-Info "Applying Steam packages to build $TargetVersion..."
    $p = Start-Process -FilePath $SteamExe -WorkingDirectory $steamDir -PassThru -Wait -ArgumentList @(
        "-clearbeta", "-textmode", "-forcesteamupdate", "-forcepackagedownload",
        "-overridepackageurl", "http://localhost:$Port/", "-exitsteam"
    )
    if ($null -ne $p.ExitCode -and $p.ExitCode -ne 0) {
        Write-WarnText "steam.exe exit code $($p.ExitCode) (install may still have succeeded)."
    }
}

# --- Main ---
$WorkDir   = Join-Path $env:LOCALAPPDATA "SteamStableInstaller\steam-cache"
$SteamPath = Resolve-DefaultSteamPath
$CacheRoot = Join-Path $WorkDir $TargetVersion

try {
    if (-not (Test-IsAdministrator)) {
        throw "Administrator required. Click Other Functions again and press Yes on the Windows UAC prompt."
    }

    if (-not (Test-Path -LiteralPath $SteamPath)) {
        throw "steam.exe not found at: $SteamPath`nInstall Steam first."
    }

    $steamDir = Split-Path -Parent $SteamPath
    $currentVer = Get-LocalClientVersion -SteamDir $steamDir
    Show-InstallBanner -CurrentVersion $currentVer -SteamExe $SteamPath

    $resolved = Resolve-Manifest
    $files = Get-FilesFromManifest -ManifestText $resolved.Text
    Ensure-Directory -Path $CacheRoot
    Write-CacheArtifacts -Root $CacheRoot -ManifestText $resolved.Text -Files $files

    if (Test-CacheComplete -Root $CacheRoot -Files $files) {
        Write-Ok "Cache ready for $TargetVersion."
    } else {
        Start-ParallelDownload -Files $files -Destination $CacheRoot -MaxWorkers $Workers
        if (-not (Test-CacheComplete -Root $CacheRoot -Files $files)) {
            throw "Download incomplete. Check internet and run Other Functions again."
        }
    }

    $before = Get-LocalClientVersion -SteamDir $steamDir
    if ($before) { Write-Info "Steam before: $before" }

    Stop-SteamProcesses
    Start-Sleep -Seconds 1
    Set-SteamCfg -InstallDir $steamDir

    $server = Start-LocalPackageServer -RootDir $CacheRoot -Port $ServerPort
    try {
        Invoke-SteamApply -SteamExe $SteamPath -Port $ServerPort
        Start-Sleep -Seconds 3
        $after = Get-LocalClientVersion -SteamDir $steamDir
        if ($after) {
            Write-Info "Steam after:  $after"
            if ($after -eq $TargetVersion) {
                Write-Ok "Done. Steam is on $TargetVersion ($BetaBranch)."
            } else {
                Write-WarnText "Expected $TargetVersion but read $after. Run Other Functions again."
            }
        } else {
            Write-WarnText "Install finished. Start Steam once to verify version."
        }
    } finally {
        Stop-Job -Job $server -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $server -Force -ErrorAction SilentlyContinue | Out-Null
    }

    Wait-ForKey
    exit 0
}
catch {
    Write-Host ""
    Write-Host "[ERR ] $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    Wait-ForKey
    exit 1
}
