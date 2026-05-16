param(
    [string]$Version,
    [datetime]$Date,
    [string]$SteamPath = "$env:ProgramFiles(x86)\Steam\steam.exe",
    [string]$WorkDir = "$PSScriptRoot\steam-cache",
    [switch]$ListOnly,
    [switch]$Apply,
    [switch]$KeepServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoOwner = "SteamTracking"
$RepoName = "SteamTracking"
$ManifestPath = "ClientManifest/steam_client_win64"
$ClientBaseUrl = "https://client-update.fastly.steamstatic.com"
$ApiBase = "https://api.github.com/repos/$RepoOwner/$RepoName"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-WarnText {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Invoke-GitHubJson {
    param([string]$Url)
    Invoke-RestMethod -Uri $Url -Headers @{ "User-Agent" = "steam-downgrader-script" }
}

function Get-VersionFromManifest {
    param([string]$ManifestText)
    $match = [regex]::Match($ManifestText, '"version"\s+"(?<v>\d+)"')
    if (-not $match.Success) {
        throw "Hindi mahanap ang version field sa manifest."
    }
    $match.Groups["v"].Value
}

function Get-FilesFromManifest {
    param([string]$ManifestText)
    $fileMatches = [regex]::Matches($ManifestText, '"file"\s+"(?<f>[^"]+)"')
    $zipVzMatches = [regex]::Matches($ManifestText, '"zipvz"\s+"(?<z>[^"]+)"')

    $list = New-Object System.Collections.Generic.List[string]
    foreach ($m in $fileMatches) { [void]$list.Add($m.Groups["f"].Value) }
    foreach ($m in $zipVzMatches) { [void]$list.Add($m.Groups["z"].Value) }

    $list | Sort-Object -Unique
}

function Get-ManifestAtRef {
    param([string]$Ref)
    $rawUrl = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Ref/$ManifestPath"
    Invoke-RestMethod -Uri $rawUrl -Headers @{ "User-Agent" = "steam-downgrader-script" }
}

function Get-ManifestHistory {
    param([int]$Pages = 20, [int]$PerPage = 100)

    $results = @()
    for ($page = 1; $page -le $Pages; $page++) {
        $url = "$ApiBase/commits?path=$([uri]::EscapeDataString($ManifestPath))&per_page=$PerPage&page=$page"
        $commits = Invoke-GitHubJson -Url $url
        if (-not $commits -or $commits.Count -eq 0) {
            break
        }

        foreach ($c in $commits) {
            try {
                $manifest = Get-ManifestAtRef -Ref $c.sha
                $version = Get-VersionFromManifest -ManifestText $manifest
                $results += [pscustomobject]@{
                    Version = $version
                    CommitDate = [datetime]$c.commit.author.date
                    CommitSha = $c.sha
                    CommitUrl = $c.html_url
                }
            } catch {
                Write-WarnText "Skip commit $($c.sha): $($_.Exception.Message)"
            }
        }
    }

    $results |
        Sort-Object CommitDate -Descending |
        Group-Object Version |
        ForEach-Object { $_.Group | Sort-Object CommitDate -Descending | Select-Object -First 1 } |
        Sort-Object CommitDate -Descending
}

function Select-TargetVersion {
    param(
        [array]$History,
        [string]$WantedVersion,
        [datetime]$WantedDate
    )

    if ($WantedVersion) {
        $hit = $History | Where-Object { $_.Version -eq $WantedVersion } | Select-Object -First 1
        if (-not $hit) {
            throw "Version $WantedVersion not found sa history."
        }
        return $hit
    }

    if ($PSBoundParameters.ContainsKey("WantedDate")) {
        $hit = $History |
            Where-Object { $_.CommitDate -le $WantedDate } |
            Sort-Object CommitDate -Descending |
            Select-Object -First 1

        if (-not $hit) {
            throw "Walang version na mas luma o equal sa date $WantedDate."
        }
        return $hit
    }

    throw "Kailangan magbigay ng -Version o -Date."
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        [void](New-Item -ItemType Directory -Path $Path -Force)
    }
}

function Download-PackageFiles {
    param(
        [string[]]$Files,
        [string]$Destination
    )
    Ensure-Directory -Path $Destination
    foreach ($f in $Files) {
        $target = Join-Path $Destination $f
        if (Test-Path -LiteralPath $target) {
            continue
        }
        $url = "$ClientBaseUrl/$f"
        Write-Info "Downloading $f"
        Invoke-WebRequest -Uri $url -OutFile $target
    }
}

function New-LocalFileServer {
    param(
        [string]$RootDir,
        [int]$Port = 1666
    )

    $job = Start-Job -ScriptBlock {
        param($ServeRoot, $ServePort)
        Add-Type -AssemblyName System.Web
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:$ServePort/")
        $listener.Start()
        try {
            while ($listener.IsListening) {
                $ctx = $listener.GetContext()
                $path = $ctx.Request.Url.AbsolutePath.TrimStart("/")
                if ([string]::IsNullOrWhiteSpace($path)) {
                    $ctx.Response.StatusCode = 404
                    $ctx.Response.Close()
                    continue
                }

                $fullPath = Join-Path $ServeRoot $path
                if (-not (Test-Path -LiteralPath $fullPath)) {
                    $ctx.Response.StatusCode = 404
                    $ctx.Response.Close()
                    continue
                }

                $bytes = [System.IO.File]::ReadAllBytes($fullPath)
                $ctx.Response.StatusCode = 200
                $ctx.Response.ContentLength64 = $bytes.Length
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $ctx.Response.OutputStream.Close()
                $ctx.Response.Close()
            }
        } finally {
            $listener.Stop()
            $listener.Close()
        }
    } -ArgumentList $RootDir, $Port

    $job
}

function Set-SteamCfg {
    param([string]$InstallDir)
    $cfgPath = Join-Path $InstallDir "steam.cfg"
    @(
        "BootStrapperInhibitAll=enable"
        "BootStrapperForceSelfUpdate=disable"
    ) | Set-Content -Path $cfgPath -Encoding ascii
    Write-Info "Updated steam.cfg at $cfgPath"
}

function Invoke-SteamDowngrade {
    param(
        [string]$SteamExe,
        [int]$Port = 1666
    )

    $args = @(
        "-clearbeta"
        "-textmode"
        "-forcesteamupdate"
        "-forcepackagedownload"
        "-overridepackageurl"
        "http://localhost:$Port/"
        "-exitsteam"
    )
    Write-Info "Running Steam downgrade command..."
    & $SteamExe @args
}

if (-not (Test-Path -LiteralPath $SteamPath) -and $Apply) {
    throw "Hindi makita ang steam.exe sa path: $SteamPath"
}

Write-Info "Fetching SteamTracking history..."
$history = Get-ManifestHistory
if (-not $history -or $history.Count -eq 0) {
    throw "Walang nakuha na history entries."
}

if ($ListOnly) {
    $history |
        Select-Object Version, CommitDate, CommitSha |
        Format-Table -AutoSize
    exit 0
}

$selected = Select-TargetVersion -History $history -WantedVersion $Version -WantedDate $Date
Write-Info "Selected Version: $($selected.Version)"
Write-Info "Manifest Commit Date (UTC): $($selected.CommitDate.ToString("u"))"
Write-Info "Commit: $($selected.CommitUrl)"

$manifest = Get-ManifestAtRef -Ref $selected.CommitSha
$files = Get-FilesFromManifest -ManifestText $manifest

$cacheRoot = Join-Path $WorkDir $selected.Version
Ensure-Directory -Path $cacheRoot

$sourcesPath = Join-Path $cacheRoot "sources.txt"
$files | ForEach-Object { "$ClientBaseUrl/$_" } | Set-Content -Path $sourcesPath -Encoding ascii
Write-Info "Wrote sources list: $sourcesPath"

Download-PackageFiles -Files $files -Destination $cacheRoot

if (-not $Apply) {
    Write-Info "Download complete. Hindi pa nag-aapply sa Steam."
    Write-Info "Run again with -Apply para i-force update to this version."
    exit 0
}

$steamDir = Split-Path -Path $SteamPath -Parent
Set-SteamCfg -InstallDir $steamDir
$server = New-LocalFileServer -RootDir $cacheRoot -Port 1666
Start-Sleep -Seconds 1

try {
    Invoke-SteamDowngrade -SteamExe $SteamPath -Port 1666
    Write-Info "Done. Check mo Steam client version pagkatapos mag-start."
} finally {
    if (-not $KeepServer) {
        Stop-Job -Id $server.Id -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Id $server.Id -Force -ErrorAction SilentlyContinue | Out-Null
    } else {
        Write-WarnText "Server kept alive (job id: $($server.Id))."
    }
}
