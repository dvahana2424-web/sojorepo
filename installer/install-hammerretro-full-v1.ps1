<#
    HammerRetro 1.0 full installer (served from CDN — do not run directly).
    Users should use:
      irm https://raw.githubusercontent.com/dvahana2424-web/hammerdeckydowngrade/HammerRetro-1.0/install.ps1 | iex
#>
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$CdnBase = 'https://hammer-cdn.monzikmonzik.workers.dev'
$GitHubRepo = 'dvahana2424-web/hammerdeckydowngrade'
$GitHubBranch = 'HammerRetro-1.0'
$InstallDir = 'C:\Program Files (x86)\HammerRetro'
$AppName = 'HammerRetro 1.0'
$Version = '1.0'
$Publisher = 'HammerRetro'
$ExeName = 'HammerRetro-1.0.0.exe'
$InstalledExeName = 'HammerRetro.exe'
$ExpectedBytes = 0

Write-Host '==============================================' -ForegroundColor Cyan
Write-Host " Installing $AppName" -ForegroundColor Cyan
Write-Host ' Source: Cloudflare CDN' -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor Cyan

$work = Join-Path $env:TEMP ('hammerretro_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$downloadPath = Join-Path $work $ExeName
$installedExePath = Join-Path $InstallDir $InstalledExeName

function Format-Span([double]$seconds) {
    if ($seconds -lt 0 -or [double]::IsInfinity($seconds) -or [double]::IsNaN($seconds)) { return '--:--' }
    $ts = [TimeSpan]::FromSeconds([math]::Round($seconds))
    if ($ts.TotalHours -ge 1) { return ('{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds) }
    return ('{0:00}:{1:00}' -f $ts.Minutes, $ts.Seconds)
}

function Get-SourceLabel([string]$url) {
    if ($url -like "$CdnBase*") { return 'Cloudflare CDN' }
    return 'mirror'
}

function Hide-Sources([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return $text }
    $out = $text -replace ([regex]::Escape($CdnBase) + '\S*'), 'Cloudflare CDN'
    $out = $out -replace '(?i)\b[\w.-]*workers\.dev\S*', 'Cloudflare CDN'
    $out = $out -replace '(?i)\b(raw\.githubusercontent\.com|cdn\.jsdelivr\.net|api\.github\.com|github\.com)\S*', 'mirror'
    $out = $out -replace 'https?://\S+', 'mirror'
    return $out
}

function Get-ExeUrls {
    $cb = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    @(
        ('{0}/v1/public/installer/{1}?cb={2}' -f $CdnBase, $ExeName, $cb),
        ('https://raw.githubusercontent.com/{0}/{1}/{2}?cb={3}' -f $GitHubRepo, [uri]::EscapeDataString($GitHubBranch), $ExeName, $cb)
    )
}

function Get-FileHttp([string]$url, [string]$dest, [string]$label) {
    $resp = $null; $rs = $null; $fs = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.UserAgent = 'HammerRetroInstaller/1.0'
        $req.Accept = 'application/octet-stream,*/*'
        $req.Timeout = 60000
        $req.ReadWriteTimeout = 600000
        $resp = $req.GetResponse()
        $total = [int64]$resp.ContentLength
        $rs = $resp.GetResponseStream()
        $fs = [System.IO.File]::Create($dest)

        $buf = New-Object byte[] (262144)
        $read = [int64]0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastMs = -1000.0

        while (($n = $rs.Read($buf, 0, $buf.Length)) -gt 0) {
            $fs.Write($buf, 0, $n)
            $read += $n
            $nowMs = $sw.Elapsed.TotalMilliseconds
            if (($nowMs - $lastMs) -ge 250 -or ($total -gt 0 -and $read -eq $total)) {
                $lastMs = $nowMs
                $secs = [math]::Max($sw.Elapsed.TotalSeconds, 0.001)
                $speed = $read / $secs
                $spd = '{0:N1} MB/s' -f ($speed / 1MB)
                if ($total -gt 0) {
                    $pct = [int][math]::Min(100, ($read / $total) * 100)
                    $eta = if ($speed -gt 0) { Format-Span (($total - $read) / $speed) } else { '--:--' }
                    $status = '{0:N1} / {1:N1} MB {2} ETA {3}' -f ($read / 1MB), ($total / 1MB), $spd, $eta
                    Write-Progress -Activity $label -Status $status -PercentComplete $pct
                } else {
                    Write-Progress -Activity $label -Status ('{0:N1} MB {1}' -f ($read / 1MB), $spd)
                }
            }
        }
        Write-Progress -Activity $label -Completed
        return $true
    } catch {
        Write-Progress -Activity $label -Completed
        throw
    } finally {
        if ($fs) { $fs.Close() }
        if ($rs) { $rs.Close() }
        if ($resp) { $resp.Close() }
    }
}

function Get-FileCurl([string]$url, [string]$dest) {
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { return $false }
    & curl.exe -fL -sS --retry 3 --retry-delay 5 --connect-timeout 30 `
        -A 'HammerRetroInstaller/1.0' -o $dest $url
    if ($LASTEXITCODE -ne 0) { return $false }
    return (Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)
}

function Get-File($urls, $dest, $label) {
    $urlList = @($urls)
    $maxTries = 4
    $lastErr = $null

    for ($try = 1; $try -le $maxTries; $try++) {
        foreach ($url in $urlList) {
            Write-Host ('  source: {0}' -f (Get-SourceLabel $url)) -ForegroundColor DarkGray
            if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }

            try {
                if (Get-FileHttp $url $dest $label) { return }
            } catch {
                $lastErr = $_
                if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
            }

            if (Get-FileCurl $url $dest) { return }

            try {
                Invoke-WebRequest -Uri $url -OutFile $dest -UserAgent 'HammerRetroInstaller/1.0' -UseBasicParsing | Out-Null
                if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) { return }
            } catch {
                $lastErr = $_
                if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
            }
        }

        if ($try -lt $maxTries) {
            Write-Host "  retry $try/$maxTries ..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds (3 * $try)
        }
    }

    if ($lastErr) { throw $lastErr }
    throw "Download failed for $label"
}

function Write-UninstallScript([string]$dir) {
    $unPath = Join-Path $dir 'Uninstall-HammerRetro.ps1'
    @"
#Requires -RunAsAdministrator
`$ErrorActionPreference = 'Stop'
`$InstallDir = '$InstallDir'
`$AppName = '$AppName'
Get-Process -Name 'HammerRetro' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
if (Test-Path `$InstallDir) { Remove-Item -LiteralPath `$InstallDir -Recurse -Force }
`$desktop = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrEmpty(`$desktop)) { `$desktop = Join-Path `$env:USERPROFILE 'Desktop' }
`$lnk = Join-Path `$desktop "`$AppName.lnk"
if (Test-Path `$lnk) { Remove-Item `$lnk -Force }
Remove-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\HammerRetro' -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'HammerRetro uninstalled.' -ForegroundColor Green
"@ | Set-Content -Path $unPath -Encoding UTF8
    return $unPath
}

try {
    Write-Host "Downloading $AppName from Cloudflare CDN..." -ForegroundColor Green
    $swDl = [System.Diagnostics.Stopwatch]::StartNew()
    Get-File (Get-ExeUrls) $downloadPath "Downloading $AppName"
    $swDl.Stop()
    $got = (Get-Item -LiteralPath $downloadPath).Length
    $avg = if ($swDl.Elapsed.TotalSeconds -gt 0) { ($got / $swDl.Elapsed.TotalSeconds) / 1MB } else { 0 }
    Write-Host ("  downloaded {0:N1} MB in {1} ({2:N1} MB/s avg)" -f ($got / 1MB), (Format-Span $swDl.Elapsed.TotalSeconds), $avg) -ForegroundColor DarkGray

    if ($ExpectedBytes -gt 0 -and $got -ne $ExpectedBytes) {
        Write-Host "  warning: size $got bytes (expected $ExpectedBytes) — continuing anyway" -ForegroundColor DarkYellow
    }

    Get-Process -Name 'HammerRetro' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    Write-Host "Installing to $InstallDir ..." -ForegroundColor Green
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    Copy-Item -LiteralPath $downloadPath -Destination $installedExePath -Force
    Set-Content -Path (Join-Path $InstallDir 'hammerretro.ver') -Value $Version -Encoding ASCII

    $unPath = Write-UninstallScript $InstallDir

    Write-Host 'Creating Desktop shortcut...' -ForegroundColor Green
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrEmpty($desktop)) { $desktop = Join-Path $env:USERPROFILE 'Desktop' }
    $lnk = Join-Path $desktop "$AppName.lnk"
    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($lnk)
    $sc.TargetPath = $installedExePath
    $sc.WorkingDirectory = $InstallDir
    $sc.IconLocation = "$installedExePath,0"
    $sc.Description = $AppName
    $sc.Save()

    Write-Host 'Registering uninstall entry...' -ForegroundColor Green
    $regKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\HammerRetro'
    if (-not (Test-Path $regKey)) { New-Item -Path $regKey -Force | Out-Null }
    $size = [math]::Round(((Get-ChildItem $InstallDir -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum / 1KB))
    $unCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$unPath`""
    New-ItemProperty -Path $regKey -Name 'DisplayName' -Value $AppName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $regKey -Name 'DisplayVersion' -Value $Version -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $regKey -Name 'Publisher' -Value $Publisher -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $regKey -Name 'DisplayIcon' -Value $installedExePath -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $regKey -Name 'InstallLocation' -Value $InstallDir -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $regKey -Name 'UninstallString' -Value $unCmd -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $regKey -Name 'EstimatedSize' -Value $size -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $regKey -Name 'NoModify' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $regKey -Name 'NoRepair' -Value 1 -PropertyType DWord -Force | Out-Null

    Write-Host ''
    Write-Host '==============================================' -ForegroundColor Green
    Write-Host " $AppName installed!" -ForegroundColor Green
    Write-Host " Location : $InstallDir" -ForegroundColor Green
    Write-Host " Shortcut : $lnk" -ForegroundColor Green
    Write-Host ' Uninstall : Settings > Apps or run Uninstall-HammerRetro.ps1' -ForegroundColor Green
    Write-Host '==============================================' -ForegroundColor Green
}
catch {
    $msg = Hide-Sources $_.Exception.Message
    Write-Host ''
    Write-Host "Installation failed: $msg" -ForegroundColor Red
    Write-Host ''
    Write-Host 'Download failed. Check your internet connection and try again.' -ForegroundColor Yellow
    $logPath = Join-Path $env:TEMP 'hammerretro-install-last.log'
    "$(Get-Date -Format o) ERROR: $msg`n$(Hide-Sources $_.ScriptStackTrace)" | Out-File -LiteralPath $logPath -Encoding UTF8
    Write-Host "Log saved to: $logPath" -ForegroundColor Yellow
    Read-Host 'Press Enter to close'
    return
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Host.Name -eq 'ConsoleHost') {
    Write-Host ''
    Write-Host 'Press Enter to close...'
    try { Read-Host | Out-Null } catch {}
}
