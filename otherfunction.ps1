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
$Workers         = 12
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
    Write-Host "       STEAM ONE-CLICK INSTALLER (Hammer Other Functions)" -ForegroundColor White
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

function Start-ParallelDownload {
    param([string[]]$Files, [string]$Destination, [int]$MaxWorkers)

    $completeMarker = Join-Path $Destination "cache-complete.ok"
    if (Test-Path -LiteralPath $completeMarker) {
        $missing = @($Files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Destination $_)) })
    } else {
        # A previous failed run can leave partial files. Without the marker, rebuild the cache.
        $missing = @($Files)
    }

    if ($missing.Count -eq 0) {
        Write-Ok "All package files already in cache."
        return
    }

    Write-Info "Downloading $($missing.Count) file(s) in parallel..."
    $progressDir = Join-Path $env:TEMP ("steam-dl-{0}" -f [guid]::NewGuid().ToString("N"))
    try {
        if (Test-Path -LiteralPath $completeMarker) {
            Remove-Item -LiteralPath $completeMarker -Force -ErrorAction SilentlyContinue
        }
        Ensure-Directory -Path $progressDir

        $jobs = @()
        $totalFiles = $missing.Count

        for ($i = 0; $i -lt $missing.Count; $i++) {
            $fileToDownload = $missing[$i]
            $statusPath = Join-Path $progressDir ("{0:D2}.json" -f $i)
            $jobs += Start-Job -ScriptBlock {
                param($Index, $FileName, $Dest, $BaseUrl, $StatusPath, $Ua)

                function Save-Status([string]$State, [long]$Downloaded, [long]$Total) {
                    $obj = @{
                        index      = $Index
                        file       = $FileName
                        state      = $State
                        downloaded = $Downloaded
                        total      = $Total
                    } | ConvertTo-Json -Compress
                    Set-Content -LiteralPath $StatusPath -Value $obj -Encoding UTF8
                }

                $url = "$BaseUrl/$FileName"
                $outPath = Join-Path $Dest $FileName
                $partPath = "$outPath.part"
                $downloaded = 0L
                $total = 0L

                try {
                    Save-Status "Starting" 0 0
                    $req = [System.Net.HttpWebRequest]::Create($url)
                    $req.UserAgent = $Ua
                    $req.Timeout = 300000
                    $req.ReadWriteTimeout = 300000
                    $resp = $req.GetResponse()
                    try {
                        if ($resp.ContentLength -gt 0) { $total = [long]$resp.ContentLength }
                        Save-Status "Downloading" 0 $total
                        $stream = $resp.GetResponseStream()
                        $fs = [System.IO.File]::Create($partPath)
                        try {
                            $buf = New-Object byte[] (524288)
                            $lastStatus = [DateTime]::UtcNow
                            while ($true) {
                                $read = $stream.Read($buf, 0, $buf.Length)
                                if ($read -le 0) { break }
                                $fs.Write($buf, 0, $read)
                                $downloaded += $read
                                if ((([DateTime]::UtcNow) - $lastStatus).TotalMilliseconds -ge 250) {
                                    Save-Status "Downloading" $downloaded $total
                                    $lastStatus = [DateTime]::UtcNow
                                }
                            }
                        } finally { $fs.Dispose(); $stream.Dispose() }
                    } finally { $resp.Dispose() }
                    Move-Item -LiteralPath $partPath -Destination $outPath -Force
                    Save-Status "Done" $downloaded $total
                } catch {
                    Save-Status "Failed" $downloaded $total
                    throw
                }
            } -ArgumentList $i, $fileToDownload, $Destination, $ClientBaseUrl, $statusPath, $UserAgent
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -gt 0) {
            $filesDone = 0
            $downloaded = 0L
            $statusItems = @()

            foreach ($statusFile in (Get-ChildItem -LiteralPath $progressDir -Filter "*.json" -ErrorAction SilentlyContinue | Sort-Object Name)) {
                try {
                    $o = Get-Content -LiteralPath $statusFile.FullName -Raw | ConvertFrom-Json
                    $statusItems += $o
                    if ($o.state -eq "Done") { $filesDone++ }
                    $downloaded += [long]$o.downloaded
                } catch { }
            }

            $elapsed = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
            $speed = $downloaded / $elapsed
            $fp = if ($totalFiles -gt 0) { [Math]::Min(100.0, ($filesDone * 100.0) / $totalFiles) } else { 100.0 }
            $status = "Files $filesDone/$totalFiles | Downloaded $(Format-Bytes ([long]$downloaded)) | Speed $(Format-Bytes ([long]$speed))/s"
            Write-Progress -Id 0 -Activity "Downloading Steam packages" -Status $status -PercentComplete ([int]$fp)

            foreach ($item in $statusItems) {
                $idx = [int]$item.index
                $total = [long]$item.total
                $done = [long]$item.downloaded
                $pct = if ($total -gt 0) { [Math]::Min(100, [int](($done * 100.0) / $total)) } elseif ($item.state -eq "Done") { 100 } else { 0 }
                $name = [string]$item.file
                if ($name.Length -gt 45) { $name = $name.Substring(0, 42) + "..." }
                $childStatus = "$($item.state) | $(Format-Bytes $done)"
                if ($total -gt 0) { $childStatus += " / $(Format-Bytes $total)" }
                Write-Progress -Id ($idx + 1) -ParentId 0 -Activity ("{0:D2}. {1}" -f ($idx + 1), $name) -Status $childStatus -PercentComplete $pct
            }
            Start-Sleep -Milliseconds 300
        }

        foreach ($j in $jobs) {
            Receive-Job -Job $j -Wait -ErrorAction Stop | Out-Null
            Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
        }
        for ($i = 1; $i -le $totalFiles; $i++) {
            Write-Progress -Id $i -ParentId 0 -Activity "File $i" -Completed
        }
        Write-Progress -Id 0 -Activity "Downloading Steam packages" -Completed
        Set-Content -LiteralPath $completeMarker -Value ((Get-Date).ToUniversalTime().ToString("o")) -Encoding ASCII
        Write-Ok "Download complete."
    } finally {
        Write-Progress -Id 0 -Activity "Downloading Steam packages" -Completed
        if (Test-Path -LiteralPath $progressDir) { Remove-Item -LiteralPath $progressDir -Recurse -Force -ErrorAction SilentlyContinue }
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
