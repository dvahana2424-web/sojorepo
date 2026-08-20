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

# NOTE: Strict mode is intentionally OFF here. The downloader uses runspaces and
# pipelines that occasionally return $null, which crashes Set-StrictMode -Version Latest
# with "The property 'Count' cannot be found on this object."
$ErrorActionPreference = "Stop"

try {
 [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$TargetVersion = "1784778118"
$BetaBranch = "Stable Client"
$UnlockModeLabel = "Unlock Mode 3 (Stable)"
$Workers = 16
$ServerPort = 1666
$PinnedCommitSha = "40c23f2bf70dd4412a07a84d6797b56895ee437f"

$RepoOwner = "SteamTracking"
$RepoName = "SteamTracking"
$ManifestPath = "ClientManifest/steam_client_win64"
$ClientBaseUrl = "https://client-update.fastly.steamstatic.com"
$UserAgent = "hammer-otherfunction-steam-installer/1.0"
$DepotManifestMirrorBase = "https://raw.githubusercontent.com/qwe213312/k25FCdfEOoEJ42S6/main/"

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
 Write-Host " Press any key to close..." -ForegroundColor DarkGray
 try {
 if ($Host.Name -eq 'ConsoleHost') {
 $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
 return
 }
 } catch { }
 try { cmd /c pause | Out-Null } catch { Start-Sleep -Seconds 8 }
}

function Normalize-SteamRoot([string]$Path) {
 if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
 $p = $Path.Trim().Trim('"').Replace('/', '\')
 if ($p.ToLowerInvariant().EndsWith('\steam.exe')) {
 $p = Split-Path -Parent $p
 }
 return $p.TrimEnd('\')
}

function Get-SteamPathFromRegistry {
 try {
 $key = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name 'SteamPath' -ErrorAction Stop
 return (Normalize-SteamRoot ([string]$key.SteamPath))
 } catch {
 return $null
 }
}

function Get-SteamPathFromFile([string]$FilePath) {
 if (-not (Test-Path -LiteralPath $FilePath)) { return $null }
 try {
 $raw = (Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop).Trim()
 if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
 return (Normalize-SteamRoot $raw)
 } catch {
 return $null
 }
}

function Resolve-SteamExe {
 $candidates = New-Object System.Collections.Generic.List[string]

 $reg = Get-SteamPathFromRegistry
 if ($reg) { [void]$candidates.Add((Join-Path $reg 'steam.exe')) }

 foreach ($f in @(
 (Join-Path ${env:ProgramFiles(x86)} 'Hammer\steampath.txt'),
 (Join-Path $env:ProgramFiles 'Hammer\steampath.txt'),
 (Join-Path $PSScriptRoot 'steampath.txt'),
 'C:\GFK\steampath.txt'
 )) {
 $fromFile = Get-SteamPathFromFile -FilePath $f
 if ($fromFile) { [void]$candidates.Add((Join-Path $fromFile 'steam.exe')) }
 }

 [void]$candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam\steam.exe'))
 [void]$candidates.Add((Join-Path $env:ProgramFiles 'Steam\steam.exe'))

 foreach ($exe in $candidates) {
 if (-not [string]::IsNullOrWhiteSpace($exe) -and (Test-Path -LiteralPath $exe)) {
 Write-Info "Steam found: $exe"
 return $exe
 }
 }

 Write-WarnText "Steam not found in default locations / registry / steampath.txt."
 Write-Host " Example: C:\Program Files (x86)\Steam\steam.exe" -ForegroundColor DarkGray
 Write-Host " Or folder: C:\Program Files (x86)\Steam" -ForegroundColor DarkGray
 $manual = (Read-Host " Enter full path to steam.exe (or Steam folder)").Trim().Trim('"')
 if ([string]::IsNullOrWhiteSpace($manual)) {
 throw "steam.exe not found. Install Steam or enter a valid path."
 }
 $root = Normalize-SteamRoot $manual
 $exe = if ($manual.ToLowerInvariant().EndsWith('steam.exe')) { $manual.Replace('/', '\') } else { Join-Path $root 'steam.exe' }
 if (-not (Test-Path -LiteralPath $exe)) {
 throw "steam.exe not found at: $exe`nInstall Steam first, or check the path."
 }
 Write-Info "Steam found: $exe"
 return $exe
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
 Write-Host " ================================================================" -ForegroundColor DarkCyan
 Write-Host " STEAM ONE-CLICK INSTALLER" -ForegroundColor White
 Write-Host " ================================================================" -ForegroundColor DarkCyan
 Write-Host ""
 Write-Host " Action : $action" -ForegroundColor Yellow
 Write-Host " Beta Branch : $BetaBranch" -ForegroundColor White
 Write-Host " Target Version : $TargetVersion" -ForegroundColor Green
 Write-Host " Reference Pin : $TargetVersion ($UnlockModeLabel)" -ForegroundColor Green
 Write-Host " Steam Path : $SteamExe" -ForegroundColor Gray
 Write-Host " Cache : $CacheRoot" -ForegroundColor Gray
 if ($CurrentVersion) {
 Write-Host " Installed Now : $CurrentVersion" -ForegroundColor Magenta
 } else {
 Write-Host " Installed Now : (unknown)" -ForegroundColor DarkYellow
 }
 Write-Host ""
 Write-Host " ================================================================" -ForegroundColor DarkCyan
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

 $missing = @(Get-MissingPackageFiles -Files $Files -Destination $Destination)
 $missingCount = $missing.Count
 if ($missingCount -eq 0) {
 Set-Content -LiteralPath $completeMarker -Value ((Get-Date).ToUniversalTime().ToString("o")) -Encoding ASCII
 Write-Ok "All package files already in cache."
 return
 }

 $parallelCount = [Math]::Min([Math]::Max(1, $MaxWorkers), $missingCount)
 Write-Info "Downloading $missingCount file(s) with $parallelCount parallel worker(s)..."

 $sync = [hashtable]::Synchronized(@{
 FilesDone = 0
 DownloadedBytes = [long]0
 TotalBytes = [long]0
 Lock = New-Object object
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
 PS = $ps
 Handle = $ps.BeginInvoke()
 }) | Out-Null
 }

 $sw = [System.Diagnostics.Stopwatch]::StartNew()
 $spin = 0
 $lastBytes = [long]0
 $lastProgressAt = [DateTime]::UtcNow
 $maxWaitMinutes = 60

 $runspaceCount = $runspaces.Count
 while ($true) {
 $doneCount = 0
 foreach ($entry in $runspaces) {
 if ($entry.Handle.IsCompleted) { $doneCount++ }
 }
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
 $filesPct = if ($missingCount -gt 0) { ($filesDone * 100.0) / $missingCount } else { 100.0 }
 $bytesPct = if ($knownTotal -gt 0) { ($downloaded * 100.0) / $knownTotal } else { $filesPct }
 $eta = if ($speed -gt 0 -and $knownTotal -gt $downloaded) { ($knownTotal - $downloaded) / $speed } else { [double]::PositiveInfinity }
 $barPct = [Math]::Min(100.0, $bytesPct)
 $status = "Files $filesDone/$missingCount | Size $(Format-Bytes ([long]$downloaded))/$(Format-Bytes ([long]$knownTotal)) | Speed $(Format-Bytes ([long]$speed))/s | ETA $(Format-Eta $eta)"
 Write-Progress -Id 1 -Activity "Downloading Steam packages" -Status $status -PercentComplete ([int]$barPct)
 $spin++

 if ($doneCount -ge $runspaceCount) { break }
 if ($sw.Elapsed.TotalMinutes -ge $maxWaitMinutes) {
 throw "Download timed out after $maxWaitMinutes minutes."
 }
 if ((([DateTime]::UtcNow) - $lastProgressAt).TotalSeconds -ge 180 -and $doneCount -lt $runspaceCount) {
 throw "Download stalled for 3 minutes. Check connection and run Other Functions again."
 }
 Start-Sleep -Milliseconds 200
 }

 foreach ($entry in $runspaces) {
 try { $entry.PS.EndInvoke($entry.Handle) | Out-Null } catch { }
 $entry.PS.Dispose()
 }

 $errorCount = $errors.Count
 if ($errorCount -gt 0) {
 $firstError = @($errors)[0]
 throw "Download failed on $errorCount file(s). First error: $firstError"
 }

 $stillMissing = @(Get-MissingPackageFiles -Files $Files -Destination $Destination)
 $stillCount = $stillMissing.Count
 if ($stillCount -gt 0) {
 throw "Cache incomplete ($stillCount file(s) still missing)."
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

function Start-SteamApp([string]$SteamExe) {
 $steamDir = Split-Path -Parent $SteamExe
 try {
 Start-Process -FilePath $SteamExe -WorkingDirectory $steamDir | Out-Null
 Write-Ok "Steam restarted."
 } catch {
 Write-WarnText "Could not auto-start Steam. Please open it manually."
 }
}

function Get-LuaPathsForApp {
 param([string]$SteamDir, [string]$AppId)
 @(
 (Join-Path $SteamDir "config\stplug-in\$AppId.lua"),
 (Join-Path $SteamDir "config\lua\$AppId.lua")
 )
}

function Get-ExistingLuaPathsForApp {
 param([string]$SteamDir, [string]$AppId)
 @(Get-LuaPathsForApp -SteamDir $SteamDir -AppId $AppId) | Where-Object { Test-Path -LiteralPath $_ }
}

function Get-SteamLibraryRoots {
 param([string]$SteamDir)
 $roots = New-Object System.Collections.Generic.List[string]
 [void]$roots.Add($SteamDir.TrimEnd('\'))

 $vdf = Join-Path $SteamDir "steamapps\libraryfolders.vdf"
 if (Test-Path -LiteralPath $vdf) {
 try {
 $raw = Get-Content -LiteralPath $vdf -Raw -ErrorAction Stop
 foreach ($m in [regex]::Matches($raw, '"path"\s+"(?<p>[^"]+)"')) {
 $p = Normalize-SteamRoot ($m.Groups["p"].Value -replace '\\\\', '\')
 if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p)) {
 if (-not ($roots | Where-Object { $_.Equals($p, [StringComparison]::OrdinalIgnoreCase) })) {
 [void]$roots.Add($p)
 }
 }
 }
 } catch {
 Write-WarnText "Could not parse libraryfolders.vdf: $($_.Exception.Message)"
 }
 }
 return @($roots)
}

function Find-AppManifestPath {
 param([string]$SteamDir, [string]$AppId)
 foreach ($root in (Get-SteamLibraryRoots -SteamDir $SteamDir)) {
 $acf = Join-Path $root "steamapps\appmanifest_$AppId.acf"
 if (Test-Path -LiteralPath $acf) { return $acf }
 }
 return $null
}

function Backup-SteamFile {
 param([string]$Path, [string]$Tag)
 if (-not (Test-Path -LiteralPath $Path)) { return $null }
 $dir = Split-Path -Parent $Path
 $name = [IO.Path]::GetFileName($Path)
 $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
 $tagPart = if ([string]::IsNullOrWhiteSpace($Tag)) { "" } else { "_$Tag" }
 $bak = Join-Path $dir ($name + ".bak" + $tagPart + "_" + $stamp)
 Copy-Item -LiteralPath $Path -Destination $bak -Force
 return $bak
}

function Clear-SteamAppInfoCache {
 param([string]$SteamDir, [string]$AppId)
 $ai = Join-Path $SteamDir "appcache\appinfo.vdf"
 if (-not (Test-Path -LiteralPath $ai)) {
 Write-Info "appinfo.vdf already absent (Steam will rebuild it)."
 return $false
 }
 $bak = Backup-SteamFile -Path $ai -Tag ("appid" + $AppId)
 Remove-Item -LiteralPath $ai -Force
 if ($bak) {
 Write-Ok "Cleared stale appinfo.vdf (backup: $bak)"
 } else {
 Write-Ok "Cleared stale appinfo.vdf"
 }
 return $true
}

function Invoke-ForceAppManifestUpdate {
 param([string]$SteamDir, [string]$AppId)
 # After de-pinning, Steam often keeps StateFlags=4 and buildid==TargetBuildID
 # with the old pinned depot GID in InstalledDepots. Mark update-required and
 # clear TargetBuildID so Steam re-evaluates against fresh appinfo.
 $acf = Find-AppManifestPath -SteamDir $SteamDir -AppId $AppId
 if (-not $acf) {
 Write-WarnText "appmanifest_$AppId.acf not found in any Steam library (game may not be installed)."
 return $false
 }

 Write-Info "Found appmanifest: $acf"
 $bak = Backup-SteamFile -Path $acf -Tag ("update" + $AppId)
 $text = Get-Content -LiteralPath $acf -Raw

 $stateMatch = [regex]::Match($text, '"StateFlags"\s+"(?<v>\d+)"')
 $oldState = if ($stateMatch.Success) { [int]$stateMatch.Groups["v"].Value } else { 4 }
 # Bit 2 = UpdateRequired, bit 4 = FullyInstalled
 $newState = ($oldState -bor 2)
 if (($oldState -band 4) -eq 0) { $newState = ($newState -bor 4) }

 $text2 = [regex]::Replace($text, '"StateFlags"\s+"\d+"', ('"StateFlags"' + "`t`t" + '"' + $newState + '"'), 1)
 $text2 = [regex]::Replace($text2, '"TargetBuildID"\s+"\d+"', ('"TargetBuildID"' + "`t`t" + '"0"'), 1)

 $depotManifest = $null
 $dm = [regex]::Match($text2, '"InstalledDepots"\s*\{[\s\S]*?"manifest"\s+"(?<m>\d+)"')
 if ($dm.Success) { $depotManifest = $dm.Groups["m"].Value }

 $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
 [System.IO.File]::WriteAllText($acf, $text2, $utf8NoBom)

 Write-Ok "Nudged appmanifest_$AppId.acf for update check (StateFlags $oldState -> $newState, TargetBuildID=0)."
 if ($bak) { Write-Info "appmanifest backup: $bak" }
 if ($depotManifest) {
 Write-Info "Installed depot still on manifest $depotManifest (Steam will replace it if a newer build exists)."
 }
 return $true
}

function Invoke-EnableGameUpdateFixes {
 param([string]$SteamDir, [string]$AppId)
 Write-Host ""
 Write-Host " Applying update-enable cache fixes for AppID $AppId..." -ForegroundColor Cyan
 Write-Host " (stale appinfo / pinned appmanifest can block Steam from seeing updates)" -ForegroundColor DarkGray
 [void](Clear-SteamAppInfoCache -SteamDir $SteamDir -AppId $AppId)
 [void](Invoke-ForceAppManifestUpdate -SteamDir $SteamDir -AppId $AppId)
}

function Get-ManifestLineInfo([string]$Line) {
 # Returns a state for a line: "active", "commented", or "other"
 # Match anywhere on the line (some lua files put addappid + setManifestid together).
 if ($Line -match '(?i)--\s*setManifestid\s*\(') { return "commented" }
 if ($Line -match '(?i)setManifestid\s*\(') { return "active" }
 return "other"
}

function Apply-LuaManifestToggleLines {
 param([string[]]$Lines, [bool]$PinManifest)
 $out = New-Object System.Collections.Generic.List[string]
 foreach ($l in $Lines) {
 if ($PinManifest) {
 if ((Get-ManifestLineInfo -Line $l) -eq "commented") {
 [void]$out.Add(($l -replace '(?i)--\s*setManifestid\s*\(', 'setManifestid('))
 } else {
 [void]$out.Add($l)
 }
 } else {
 if ((Get-ManifestLineInfo -Line $l) -eq "active") {
 [void]$out.Add(($l -replace '(?i)setManifestid\s*\(', '--setManifestid('))
 } else {
 [void]$out.Add($l)
 }
 }
 }
 return ,$out.ToArray()
}

function Get-LuaManifestStateSummary {
 param([string[]]$Lines)
 $active = 0
 $commented = 0
 foreach ($l in $Lines) {
 $state = Get-ManifestLineInfo -Line $l
 if ($state -eq "active") { $active++ }
 elseif ($state -eq "commented") { $commented++ }
 }
 return [pscustomobject]@{ Active = $active; Commented = $commented }
}

function Save-LuaFileLines {
 param([string]$Path, [string[]]$Lines)
 if (Test-Path -LiteralPath $Path) {
 try { attrib -R $Path 2>$null | Out-Null } catch { }
 }
 $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
 [System.IO.File]::WriteAllLines($Path, [string[]]$Lines, $utf8NoBom)
}

function Show-LuaStatus {
 param([string[]]$Lines, [string]$Title)
 $active = 0
 $commented = 0
 Write-Host ""
 Write-Host " $Title" -ForegroundColor White
 foreach ($l in $Lines) {
 $state = Get-ManifestLineInfo -Line $l
 if ($state -eq "other") { continue }
 $appMatch = [regex]::Match($l, '(?i)setManifestid\s*\(\s*(?<id>\d+)')
 $appLabel = if ($appMatch.Success) { $appMatch.Groups["id"].Value } else { "?" }
 if ($state -eq "commented") {
 $commented++
 Write-Host (" - depot {0} : UPDATING (updates enabled, manifest not pinned)" -f $appLabel) -ForegroundColor Green
 } else {
 $active++
 Write-Host (" - depot {0} : NOT updating (pinned to a fixed manifest)" -f $appLabel) -ForegroundColor Yellow
 }
 }
 if (($active + $commented) -eq 0) {
 Write-Host " (no setManifestid lines)" -ForegroundColor DarkGray
 }
 return [pscustomobject]@{ Active = $active; Commented = $commented }
}

function Invoke-UpdateToggle([string]$SteamExe) {
 $steamDir = Split-Path -Parent $SteamExe

 Write-Host ""
 Write-Host " ----------------------------------------------------------------" -ForegroundColor DarkCyan
 Write-Host " ENABLE / DISABLE STEAM GAME UPDATES" -ForegroundColor White
 Write-Host " ----------------------------------------------------------------" -ForegroundColor DarkCyan

 $appId = (Read-Host " Enter the AppID (example 413150)").Trim()
 if ($appId -notmatch '^\d+$') {
 throw "Invalid AppID. Numbers only (example 413150)."
 }

 $luaFiles = @(Get-ExistingLuaPathsForApp -SteamDir $steamDir -AppId $appId)
 if ($luaFiles.Count -eq 0) {
 throw "Lua file not found for AppID $appId.`nExpected: $(Join-Path $steamDir "config\stplug-in\$appId.lua") and/or $(Join-Path $steamDir "config\lua\$appId.lua")"
 }
 Write-Info "Found lua file(s): $($luaFiles -join '; ')"

 $totalActive = 0
 $totalCommented = 0
 foreach ($candidate in $luaFiles) {
 $probeLines = @(Get-Content -LiteralPath $candidate)
 $probeStatus = Get-LuaManifestStateSummary -Lines $probeLines
 $totalActive += $probeStatus.Active
 $totalCommented += $probeStatus.Commented
 [void](Show-LuaStatus -Lines $probeLines -Title ("Current status ({0}):" -f ([IO.Path]::GetFileName($candidate))))
 }

 if (($totalActive + $totalCommented) -eq 0) {
 throw "No setManifestid lines found in any .lua for AppID $appId.`nChecked: $($luaFiles -join ', ')"
 }

 # active setManifestid(...) => pinned => updates DISABLED
 # --setManifestid(...) => not pinned => updates ENABLED
 # If any active line exists, comment out all active lines (enable updates).
 # If only commented lines exist, uncomment them (pin / disable updates).
 $pinManifest = ($totalActive -eq 0 -and $totalCommented -gt 0)
 $resultState = if ($pinManifest) { "DISABLED" } else { "ENABLED" }

 Write-Info "Stopping Steam before editing .lua files..."
 Stop-SteamProcesses
 Start-Sleep -Seconds 2

 foreach ($luaFile in $luaFiles) {
 $lines = @(Get-Content -LiteralPath $luaFile)
 $newLines = @(Apply-LuaManifestToggleLines -Lines $lines -PinManifest $pinManifest)
 Save-LuaFileLines -Path $luaFile -Lines $newLines
 Write-Ok "Saved: $luaFile"
 [void](Show-LuaStatus -Lines $newLines -Title ("New status ({0}):" -f ([IO.Path]::GetFileName($luaFile))))
 }

 $verifyFailed = @()
 foreach ($luaFile in $luaFiles) {
 $check = Get-LuaManifestStateSummary -Lines @(Get-Content -LiteralPath $luaFile)
 if ($resultState -eq "ENABLED" -and $check.Active -gt 0) { $verifyFailed += $luaFile }
 if ($resultState -eq "DISABLED" -and $check.Commented -gt 0) { $verifyFailed += $luaFile }
 }
 if ($verifyFailed.Count -gt 0) {
 throw "Could not update setManifestid in: $($verifyFailed -join '; ')`nRun Other Functions as Administrator (Steam is under Program Files)."
 }

 if ($resultState -eq "ENABLED") {
 # De-pin alone is not enough: Steam keeps the old pinned GID in
 # appcache\appinfo.vdf and appmanifest_{AppID}.acf (StateFlags=4,
 # buildid==TargetBuildID). Clear/nudge those so Steam re-fetches.
 Invoke-EnableGameUpdateFixes -SteamDir $steamDir -AppId $appId
 } else {
 # Re-pin: refresh appinfo so Hammer can re-apply the pinned GID cleanly.
 Write-Info "Refreshing appinfo.vdf so the pin can re-apply cleanly..."
 [void](Clear-SteamAppInfoCache -SteamDir $steamDir -AppId $appId)
 }

 Write-Info "Restarting Steam to apply the change..."
 Start-SteamApp -SteamExe $SteamExe

 Write-Host ""
 if ($resultState -eq "ENABLED") {
 Write-Ok "Updates ENABLED for AppID $appId."
 Write-Host " Both stplug-in + config\lua de-pinned + appinfo.vdf cleared + appmanifest nudged." -ForegroundColor Green
 Write-Host " Steam should now detect an update if a newer build exists." -ForegroundColor Green
 Write-Host " If nothing appears, Library -> game -> Properties -> Installed Files -> Verify." -ForegroundColor DarkGray
 } else {
 Write-Ok "Updates DISABLED for AppID $appId."
 Write-Host " Both stplug-in + config\lua pinned." -ForegroundColor Green
 Write-Host " Starting now, this AppID ($appId) will NOT receive the upcoming updates (pinned)." -ForegroundColor Green
 }
}

function Invoke-DeleteLuaFiles([string]$SteamExe) {
 $steamDir = Split-Path -Parent $SteamExe

 Write-Host ""
 Write-Host " ----------------------------------------------------------------" -ForegroundColor DarkCyan
 Write-Host " DELETE .LUA FILE (by AppID)" -ForegroundColor White
 Write-Host " ----------------------------------------------------------------" -ForegroundColor DarkCyan
 Write-Host " Looks in:" -ForegroundColor Gray
 Write-Host " - $steamDir\config\lua\{AppID}.lua" -ForegroundColor DarkGray
 Write-Host " - $steamDir\config\stplug-in\{AppID}.lua" -ForegroundColor DarkGray
 Write-Host ""

 $appId = (Read-Host " Enter the AppID to delete (example 413150)").Trim()
 if ($appId -notmatch '^\d+$') {
 throw "Invalid AppID. Numbers only (example 413150)."
 }

 $targets = @(Get-LuaPathsForApp -SteamDir $steamDir -AppId $appId)
 $existing = @($targets | Where-Object { Test-Path -LiteralPath $_ })
 if ($existing.Count -eq 0) {
 throw "No .lua file found for AppID $appId in config\lua or config\stplug-in."
 }

 Write-Host ""
 Write-Host " Will delete:" -ForegroundColor Yellow
 foreach ($f in $existing) {
 Write-Host " - $f" -ForegroundColor White
 }
 Write-Host ""
 $confirm = (Read-Host " Type YES to confirm delete").Trim()
 if ($confirm -ne 'YES') {
 Write-WarnText "Cancelled. No files deleted."
 return
 }

 Write-Info "Stopping Steam before deleting lua files..."
 Stop-SteamProcesses
 Start-Sleep -Seconds 2

 $deleted = 0
 foreach ($f in $existing) {
 try {
 Remove-Item -LiteralPath $f -Force -ErrorAction Stop
 Write-Ok "Deleted: $f"
 $deleted++
 } catch {
 Write-WarnText "Failed to delete: $f ($($_.Exception.Message))"
 }
 }

 if ($deleted -eq 0) {
 throw "Could not delete any lua files for AppID $appId."
 }

 Write-Host ""
 Write-Ok "Removed $deleted lua file(s) for AppID $appId."
 Write-Info "Restarting Steam..."
 Start-SteamApp -SteamExe $SteamExe
}

function Sanitize-InstallDirName {
 param([string]$Name, [string]$FallbackId)
 $source = if ([string]::IsNullOrWhiteSpace($Name)) { $FallbackId } else { $Name.Trim() }
 $source = $source -replace ':', ' '
 $invalid = [IO.Path]::GetInvalidFileNameChars()
 $chars = $source.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { $_ } }
 $cleaned = -join $chars
 $cleaned = [regex]::Replace($cleaned, '\s+', ' ').Trim().TrimEnd('.')
 if ([string]::IsNullOrWhiteSpace($cleaned)) { return $FallbackId }
 return $cleaned
}

function Test-PlaceholderInstallDir {
 param([string]$InstallDir, [string]$Id)
 if ([string]::IsNullOrWhiteSpace($InstallDir)) { return $true }
 $d = $InstallDir.Trim()
 if ($d.Equals($Id, [StringComparison]::OrdinalIgnoreCase)) { return $true }
 if ($d -match '^\d+$') { return $true }
 return $false
}

function Test-BadInstallDir {
 param([string]$InstallDir, [string]$Id)
 if (Test-PlaceholderInstallDir -InstallDir $InstallDir -Id $Id) { return $true }
 if ($InstallDir -match '[:<>|?*"]') { return $true }
 if ($InstallDir -match '_\s') { return $true }
 return $false
}

function Get-AppTitleFromStore {
 param([string]$Id)
 try {
 $url = "https://store.steampowered.com/api/appdetails?appids=$Id&l=en&cc=us"
 $resp = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = $UserAgent } -TimeoutSec 30
 $node = $resp.$Id
 if ($null -ne $node -and $node.success -and $null -ne $node.data.name) {
 return [string]$node.data.name
 }
 } catch {
 Write-WarnText "Store title lookup failed: $($_.Exception.Message)"
 }
 return "App $Id"
}

function Get-InstallDirFromSteamCmd {
 param([string]$Id)
 try {
 $url = "https://api.steamcmd.net/v1/info/$Id"
 $resp = Invoke-RestMethod -Uri $url -Headers @{ 'User-Agent' = $UserAgent } -TimeoutSec 30
 $app = $resp.data.$Id
 if ($null -ne $app -and $null -ne $app.config -and $null -ne $app.config.installdir) {
 $inst = [string]$app.config.installdir
 if (-not [string]::IsNullOrWhiteSpace($inst)) { return $inst.Trim() }
 }
 } catch {
 Write-WarnText "steamcmd.net lookup failed: $($_.Exception.Message)"
 }
 return $null
}

function Resolve-InstallDirName {
 param([string]$SteamDir, [string]$Id, [string]$Title)
 $acfPath = Find-AppManifestPath -SteamDir $SteamDir -AppId $Id
 if ($acfPath) {
 $text = Get-Content -LiteralPath $acfPath -Raw
 $m = [regex]::Match($text, '"installdir"\s+"(?<v>[^"]+)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
 if ($m.Success) {
 $fromAcf = $m.Groups['v'].Value.Trim()
 if (-not (Test-BadInstallDir -InstallDir $fromAcf -Id $Id)) {
 return (Sanitize-InstallDirName -Name $fromAcf -FallbackId $Id)
 }
 }
 }
 $fromCmd = Get-InstallDirFromSteamCmd -Id $Id
 if (-not [string]::IsNullOrWhiteSpace($fromCmd)) {
 return (Sanitize-InstallDirName -Name $fromCmd -FallbackId $Id)
 }
 return (Sanitize-InstallDirName -Name $Title -FallbackId $Id)
}

function New-MinimalAppManifest {
 param([string]$AcfPath, [string]$Id, [string]$InstallDir)
 $unix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
 $content = @"
"AppState"
{
	"appid"		"$Id"
	"Universe"		"1"
	"StateFlags"		"4"
	"installdir"		"$InstallDir"
	"LastUpdated"		"$unix"
	"UpdateResult"		"0"
	"SizeOnDisk"		"0"
	"buildid"		"0"
	"LastOwner"		"0"
	"BytesToDownload"		"0"
	"BytesDownloaded"		"0"
	"AutoUpdateBehavior"		"0"
	"AllowOtherDownloadsWhileRunning"		"0"
}
"@
 $dir = Split-Path -Parent $AcfPath
 if (-not (Test-Path -LiteralPath $dir)) {
 New-Item -ItemType Directory -Path $dir -Force | Out-Null
 }
 $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
 [System.IO.File]::WriteAllText($AcfPath, $content, $utf8NoBom)
}

function Repair-AppManifestForSteamInstall {
 param([string]$SteamDir, [string]$Id, [string]$InstallDir)
 $preferredRoot = $SteamDir
 $existing = Find-AppManifestPath -SteamDir $SteamDir -AppId $Id
 if ($existing) {
 $preferredRoot = Split-Path (Split-Path $existing -Parent) -Parent
 }
 $acfPath = Join-Path $preferredRoot "steamapps\appmanifest_$Id.acf"
 if (-not (Test-Path -LiteralPath $acfPath)) {
 Write-Info "Creating appmanifest_$Id.acf ..."
 New-MinimalAppManifest -AcfPath $acfPath -Id $Id -InstallDir $InstallDir
 Write-Ok "Created $acfPath"
 return @{
 AcfPath = $acfPath
 LibraryRoot = $preferredRoot
 InstallDir = $InstallDir
 }
 }
 $text = Get-Content -LiteralPath $acfPath -Raw
 $m = [regex]::Match($text, '"installdir"\s+"(?<v>[^"]+)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
 $current = if ($m.Success) { $m.Groups['v'].Value.Trim() } else { '' }
 $needsFix = (Test-BadInstallDir -InstallDir $current -Id $Id) -or ($current -ne $InstallDir)
 if ($needsFix) {
 Write-Info "Fixing installdir: '$current' -> '$InstallDir'"
 $bak = Backup-SteamFile -Path $acfPath -Tag ("installdir$Id")
 if ($bak) { Write-Info "Backup: $bak" }
 if ($m.Success) {
 $text = [regex]::Replace($text, '"installdir"\s+"[^"]+"', ('"installdir"' + "`t`t" + '"' + $InstallDir + '"'), 1)
 } else {
 $text = $text -replace '(\ "AppState"\s*\{)', "`$1`r`n`t`"installdir`"`t`t`"$InstallDir`""
 }
 }
 $text = [regex]::Replace($text, '"TargetBuildID"\s+"\d+"', '"TargetBuildID"' + "`t`t" + '"0"', 1)
 if ($text -notmatch '"SizeOnDisk"') {
 $text = $text -replace '(\ "AppState"\s*\{)', "`$1`r`n`t`"SizeOnDisk`"`t`t`"0`""
 } else {
 $text = [regex]::Replace($text, '"SizeOnDisk"\s+"\d+"', '"SizeOnDisk"' + "`t`t" + '"0"', 1)
 }
 $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
 [System.IO.File]::WriteAllText($acfPath, $text, $utf8NoBom)
 if ($needsFix) {
 Write-Ok "appmanifest repaired for Steam client install."
 } else {
 Write-Ok "appmanifest refreshed for Steam client install."
 }
 return @{
 AcfPath = $acfPath
 LibraryRoot = $preferredRoot
 InstallDir = $InstallDir
 }
}

function Parse-LuaManifests {
 param([string]$LuaPath)
 $txt = Get-Content -LiteralPath $LuaPath -Raw
 $items = @()
 $rx = 'setManifestid\(\s*(?<depot>\d+)\s*,\s*["''](?<man>\d+)["''](?:\s*,\s*\d+)?\s*\)'
 foreach ($m in [regex]::Matches($txt, $rx, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
 $items += [pscustomobject]@{
 DepotId = $m.Groups['depot'].Value
 ManifestId = $m.Groups['man'].Value
 }
 }
 return $items
}

function Install-ManifestToSteam {
 param([string]$SteamDir, [string]$DepotId, [string]$ManifestId)
 $name = "${DepotId}_${ManifestId}.manifest"
 $targets = @(
 (Join-Path $SteamDir "config\depotcache\$name"),
 (Join-Path $SteamDir "depotcache\$name")
 )
 foreach ($root in (Get-SteamLibraryRoots -SteamDir $SteamDir)) {
 foreach ($sub in @('config\depotcache', 'depotcache')) {
 $candidate = Join-Path $root "$sub\$name"
 if (Test-Path -LiteralPath $candidate) {
 $candidateFull = (Resolve-Path -LiteralPath $candidate).Path
 foreach ($t in $targets) {
 $dir = Split-Path -Parent $t
 if (-not (Test-Path -LiteralPath $dir)) {
 New-Item -ItemType Directory -Path $dir -Force | Out-Null
 }
 $targetFull = [IO.Path]::GetFullPath($t)
 if ($candidateFull.Equals($targetFull, [StringComparison]::OrdinalIgnoreCase)) { continue }
 Copy-Item -LiteralPath $candidateFull -Destination $targetFull -Force
 }
 Write-Ok "Manifest ready: $name"
 return $true
 }
 }
 }
 $temp = Join-Path $env:TEMP "hammer_manifest_$name"
 $url = $DepotManifestMirrorBase + $name
 Write-Info "Downloading manifest $name ..."
 try {
 Invoke-WebRequest -Uri $url -OutFile $temp -UseBasicParsing -Headers @{ 'User-Agent' = $UserAgent } -TimeoutSec 120
 } catch {
 Write-WarnText "Could not download manifest $name : $($_.Exception.Message)"
 return $false
 }
 foreach ($t in $targets) {
 $dir = Split-Path -Parent $t
 if (-not (Test-Path -LiteralPath $dir)) {
 New-Item -ItemType Directory -Path $dir -Force | Out-Null
 }
 Copy-Item -LiteralPath $temp -Destination $t -Force
 }
 try { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } catch { }
 Write-Ok "Installed manifest: $name"
 return $true
}

function Remove-StaleInstallFolders {
 param([string]$LibraryRoot, [string]$Id, [string]$GoodInstallDir)
 $common = Join-Path $LibraryRoot 'steamapps\common'
 if (-not (Test-Path -LiteralPath $common)) { return }
 $staleNames = @($Id)
 if (-not [string]::IsNullOrWhiteSpace($GoodInstallDir)) {
 $staleNames += ($GoodInstallDir -replace ':', '_')
 }
 foreach ($name in ($staleNames | Select-Object -Unique)) {
 if ($name.Equals($GoodInstallDir, [StringComparison]::OrdinalIgnoreCase)) { continue }
 $path = Join-Path $common $name
 if (-not (Test-Path -LiteralPath $path)) { continue }
 $items = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue)
 if ($items.Count -eq 0) {
 Remove-Item -LiteralPath $path -Force -Recurse -ErrorAction SilentlyContinue
 Write-Ok "Removed empty stale folder: $path"
 } else {
 Write-WarnText "Stale folder not empty (left in place): $path"
 }
 }
}

function Start-SteamInstallDialog {
 param([string]$SteamExe, [string]$Id)
 $steamDir = Split-Path -Parent $SteamExe
 Write-Info "Opening Steam install dialog for AppID $Id ..."
 Start-Process -FilePath $SteamExe -WorkingDirectory $steamDir -ArgumentList "steam://install/$Id" | Out-Null
 Write-Ok "Steam install dialog requested."
 Write-Host ""
 Write-Host " In Steam: confirm install location, then click Install." -ForegroundColor Green
 Write-Host " Example: Resonance - A Plague Tale Legacy (AppID 2713000)." -ForegroundColor DarkGray
}

function Invoke-FixSteamClientInstall {
 param([string]$SteamExe)

 $steamDir = Split-Path -Parent $SteamExe

 Write-Host ""
 Write-Host " ----------------------------------------------------------------" -ForegroundColor DarkCyan
 Write-Host " FIX STEAM INSTALL PATH + DOWNLOAD VIA STEAM CLIENT" -ForegroundColor White
 Write-Host " ----------------------------------------------------------------" -ForegroundColor DarkCyan
 Write-Host " Fixes INVALID INSTALL PATH, repairs appmanifest ACF, syncs manifests," -ForegroundColor Gray
 Write-Host " then opens Steam install so the client downloads the game." -ForegroundColor Gray
 Write-Host " (No depot downloader — Steam handles the download.)" -ForegroundColor Gray
 Write-Host ""

 $defaultAppId = "2713000"
 $appId = (Read-Host " Enter AppID (example $defaultAppId for Resonance)").Trim()
 if ([string]::IsNullOrWhiteSpace($appId)) { $appId = $defaultAppId }
 if ($appId -notmatch '^\d+$') {
 throw "Invalid AppID. Numbers only (example $defaultAppId)."
 }

 $luaFiles = @(Get-ExistingLuaPathsForApp -SteamDir $steamDir -AppId $appId)
 if ($luaFiles.Count -eq 0) {
 throw "Lua not found for AppID $appId.`nAdd the game in Hammer first.`nExpected: $steamDir\config\stplug-in\$appId.lua"
 }
 $luaPath = $luaFiles[0]
 Write-Ok "Lua: $luaPath"

 $title = Get-AppTitleFromStore -Id $appId
 Write-Info "Game: $title"

 $installDir = Resolve-InstallDirName -SteamDir $steamDir -Id $appId -Title $title
 Write-Info "Install folder: steamapps\common\$installDir"

 $manifests = @(Parse-LuaManifests -LuaPath $luaPath)
 if ($manifests.Count -eq 0) {
 Write-WarnText "No setManifestid(...) in lua. Steam may still install if manifests are live."
 } else {
 Write-Info "Manifests in lua: $($manifests.Count)"
 }

 Write-Info "Stopping Steam..."
 Stop-SteamProcesses
 Start-Sleep -Seconds 2

 $acf = Repair-AppManifestForSteamInstall -SteamDir $steamDir -Id $appId -InstallDir $installDir
 Remove-StaleInstallFolders -LibraryRoot $acf.LibraryRoot -Id $appId -GoodInstallDir $installDir

 foreach ($mf in $manifests) {
 Install-ManifestToSteam -SteamDir $steamDir -DepotId $mf.DepotId -ManifestId $mf.ManifestId | Out-Null
 }

 Clear-SteamAppInfoCache -SteamDir $steamDir -AppId $appId

 Write-Info "Restarting Steam..."
 Start-SteamApp -SteamExe $SteamExe
 Start-Sleep -Seconds 4
 Start-SteamInstallDialog -SteamExe $SteamExe -Id $appId

 Write-Host ""
 Write-Ok "Done. Steam client will download the game."
 Write-Info "ACF: $($acf.AcfPath)"
 Write-Info "Target: $(Join-Path $acf.LibraryRoot "steamapps\common\$installDir")"
}

function Get-SafeTempDir {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Temp'),
        (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp'),
        $env:TEMP,
        $env:TMP,
        (Join-Path $env:SystemRoot 'Temp')
    )
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $dir = ([System.IO.DirectoryInfo]$candidate).FullName
            if (-not (Test-Path -LiteralPath $dir)) {
                [void][System.IO.Directory]::CreateDirectory($dir)
            }
            return $dir
        } catch { }
    }
    return $env:TEMP
}

function Remove-FileSafe([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try {
        $full = ([System.IO.FileInfo]$Path).FullName
        [System.IO.File]::Delete($full)
        return $true
    } catch { }
    try {
        cmd.exe /c "del /F /Q `"$Path`"" | Out-Null
        return -not (Test-Path -LiteralPath $Path)
    } catch { }
    return $false
}

function Stop-HammerProcesses {
    foreach ($proc in Get-Process -Name 'Hammer' -ErrorAction SilentlyContinue) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
        } catch {
            Write-WarnText "Could not stop Hammer (PID $($proc.Id)): $($_.Exception.Message)"
        }
    }
    Start-Process -FilePath 'taskkill' -ArgumentList '/F', '/IM', 'Hammer.exe' -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
}

function Clear-OtherFunctionTemp {
    $tempScript = Join-Path (Get-SafeTempDir) 'otherfunction.ps1'
    if ([string]::IsNullOrWhiteSpace($tempScript) -or -not (Test-Path -LiteralPath $tempScript)) { return }

    $selfPath = $script:SelfPath
    if (-not [string]::IsNullOrWhiteSpace($selfPath)) {
        try {
            $a = ([System.IO.FileInfo]$tempScript).FullName
            $b = ([System.IO.FileInfo]$selfPath).FullName
            if ($a.Equals($b, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Info "Skipping delete of active script (refreshes on next Other Functions launch)."
                return
            }
        } catch { }
    }

    try {
        if (Remove-FileSafe -Path $tempScript) {
            Write-Info "Cleared cached Other Functions script."
        } else {
            Write-WarnText "Could not clear cached script (upgrade will continue)."
        }
    } catch {
        Write-WarnText "Could not clear cached script: $($_.Exception.Message)"
    }
}

function Sync-WindowsDateTime {
    Write-Host ""
    Write-Host " Syncing Windows date & time (required for Hammer license/CDN)..." -ForegroundColor Cyan
    Write-Host " Before: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')" -ForegroundColor DarkGray

    $syncOk = $false
    try {
        $w32 = Get-Service -Name 'w32time' -ErrorAction Stop
        if ($w32.Status -ne 'Running') {
            Set-Service -Name 'w32time' -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name 'w32time' -ErrorAction Stop
            Write-Info "Started Windows Time service (w32time)."
        } else {
            Set-Service -Name 'w32time' -StartupType Automatic -ErrorAction SilentlyContinue
        }

        $paramPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
        $ntpClientPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient'
        if (-not (Test-Path -LiteralPath $paramPath)) {
            New-Item -Path $paramPath -Force | Out-Null
        }
        Set-ItemProperty -LiteralPath $paramPath -Name 'Type' -Value 'NTP' -Type String -Force
        Set-ItemProperty -LiteralPath $paramPath -Name 'NtpServer' -Value 'time.windows.com,0x9' -Type String -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $ntpClientPath) {
            Set-ItemProperty -LiteralPath $ntpClientPath -Name 'Enabled' -Value 1 -Type DWord -Force
        }

        $configPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config'
        if (Test-Path -LiteralPath $configPath) {
            Set-ItemProperty -LiteralPath $configPath -Name 'AnnounceFlags' -Value 5 -Type DWord -Force -ErrorAction SilentlyContinue
        }

        # Windows 10/11 - enable "Set time automatically" (NTP client)
        $autoTimePath = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient'
        if (Test-Path -LiteralPath $autoTimePath) {
            Set-ItemProperty -LiteralPath $autoTimePath -Name 'Enabled' -Value 1 -Type DWord -Force
        }

        $null = Start-Process -FilePath "$env:SystemRoot\System32\w32tm.exe" `
            -ArgumentList '/config', '/manualpeerlist:time.windows.com', '/syncfromflags:manual', '/reliable:yes', '/update' `
            -Wait -PassThru -WindowStyle Hidden

        $resync = Start-Process -FilePath "$env:SystemRoot\System32\w32tm.exe" `
            -ArgumentList '/resync', '/force' `
            -Wait -PassThru -WindowStyle Hidden
        if ($resync.ExitCode -eq 0) {
            $syncOk = $true
            Write-Ok "Time synchronized with time.windows.com."
        } else {
            Write-WarnText "w32tm resync exit code $($resync.ExitCode) - trying fallback sync..."
        }
    } catch {
        Write-WarnText "Could not configure Windows Time service: $($_.Exception.Message)"
    }

    if (-not $syncOk) {
        try {
            $retry = Start-Process -FilePath "$env:SystemRoot\System32\w32tm.exe" `
                -ArgumentList '/resync', '/rediscover' `
                -Wait -PassThru -WindowStyle Hidden
            if ($retry.ExitCode -eq 0) {
                $syncOk = $true
                Write-Ok "Time synchronized (rediscover)."
            }
        } catch { }
    }

    if (-not $syncOk) {
        Write-WarnText "Automatic time sync could not be confirmed - upgrade will continue."
    }

    Write-Host " After:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')" -ForegroundColor DarkGray
    Write-Host " UTC:    $(([DateTimeOffset]::UtcNow).ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor DarkGray
    Write-Host " Tip: Settings - Time and language - turn ON Set time automatically if clock is still wrong." -ForegroundColor DarkYellow
    Write-Host ""
}

function Invoke-UpgradeHammer {
    $installUrl = 'https://raw.githubusercontent.com/dvahana2424-web/hammerdeckydowngrade/Hammer-3.8-obfuscated/install.ps1'

    Write-Host ""
    Write-Host " ----------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host " UPGRADE HAMMER TO LATEST" -ForegroundColor White
    Write-Host " ----------------------------------------------------------------" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host " Downloads and installs the latest Hammer build." -ForegroundColor Gray
    Write-Host " Syncs Windows date/time (Set time automatically)." -ForegroundColor Gray
    Write-Host " Steam and Hammer will close during the upgrade (~100 MB download)." -ForegroundColor Gray
    Write-Host ""
    $confirm = (Read-Host " Type YES to start upgrade").Trim()
    if ($confirm.ToUpperInvariant() -ne 'YES') {
        Write-WarnText "Cancelled."
        return
    }

    Sync-WindowsDateTime

    Write-Info "Closing Steam and Hammer before upgrade..."
    Stop-SteamProcesses
    Stop-HammerProcesses
    Clear-OtherFunctionTemp
    Start-Sleep -Seconds 2

    Write-Info "Starting Hammer upgrade installer..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-RestMethod -Uri $installUrl -Headers @{'Cache-Control' = 'no-cache'} | Invoke-Expression
    } catch {
        throw "Hammer upgrade failed: $($_.Exception.Message)"
    }
}

function Show-MainMenu {
 Write-Host ""
 Write-Host " ================================================================" -ForegroundColor DarkCyan
 Write-Host " HAMMER APP - OTHER FUNCTION" -ForegroundColor White
 Write-Host " ================================================================" -ForegroundColor DarkCyan
 Write-Host ""
 Write-Host " [1] Downgrade Steam" -ForegroundColor Yellow
 Write-Host " Run the one-click Steam downgrade installer." -ForegroundColor Gray
 Write-Host ""
 Write-Host " [2] Enable / Disable Steam game updates" -ForegroundColor Yellow
 Write-Host " Toggle setManifestid pin by AppID." -ForegroundColor Gray
 Write-Host " When enabling: also clears appinfo.vdf + nudges appmanifest.acf" -ForegroundColor Gray
 Write-Host " so Steam actually sees the update (de-pin alone is not enough)." -ForegroundColor Gray
 Write-Host ""
 Write-Host " [3] Delete .lua file (by AppID)" -ForegroundColor Yellow
 Write-Host " Delete {AppID}.lua from config\lua and config\stplug-in." -ForegroundColor Gray
 Write-Host ""
 Write-Host " [4] Upgrade Hammer" -ForegroundColor Yellow
 Write-Host " Install latest build, sync Windows time, close Steam/Hammer." -ForegroundColor Gray
 Write-Host ""
 Write-Host " [5] Fix Resonance / Steam install path" -ForegroundColor Yellow
 Write-Host " Fix INVALID INSTALL PATH, repair ACF, sync manifests, then Steam downloads." -ForegroundColor Gray
 Write-Host " Works for Resonance: A Plague Tale Legacy (2713000) and other AppIDs." -ForegroundColor Gray
 Write-Host ""
 Write-Host " ================================================================" -ForegroundColor DarkCyan
 while ($true) {
 $sel = (Read-Host " Press 1, 2, 3, 4, or 5 then Enter").Trim()
 if ($sel -eq '1' -or $sel -eq '2' -or $sel -eq '3' -or $sel -eq '4' -or $sel -eq '5') { return $sel }
 Write-WarnText "Please type 1, 2, 3, 4, or 5."
 }
}

# --- Main ---
$WorkDir = Join-Path $env:LOCALAPPDATA "SteamStableInstaller\steam-cache"
$SteamPath = $null
$CacheRoot = Join-Path $WorkDir $TargetVersion

try {
 if (-not (Test-IsAdministrator)) {
 throw "Administrator required. Click Other Functions again and press Yes on the Windows UAC prompt."
 }

 $choice = Show-MainMenu
 if ($choice -eq '4') {
 Invoke-UpgradeHammer
 Wait-ForKey
 exit 0
 }

 $SteamPath = Resolve-SteamExe
 if (-not (Test-Path -LiteralPath $SteamPath)) {
 throw "steam.exe not found at: $SteamPath`nInstall Steam first."
 }

 if ($choice -eq '2') {
 Invoke-UpdateToggle -SteamExe $SteamPath
 Wait-ForKey
 exit 0
 }
 if ($choice -eq '3') {
 Invoke-DeleteLuaFiles -SteamExe $SteamPath
 Wait-ForKey
 exit 0
 }
 if ($choice -eq '5') {
 Invoke-FixSteamClientInstall -SteamExe $SteamPath
 Wait-ForKey
 exit 0
 }

 # choice 1 -> Downgrade Steam (one-click installer below)
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
 Write-Info "Steam after: $after"
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
