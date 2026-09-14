<#
.SYNOPSIS
    Adds the English launcher to an FGO ARCADE install that already has the Chinese version.

.DESCRIPTION
    Checks the machine can actually run the game, downloads the English patch, verifies it, then builds a
    second launcher folder beside the install. Nothing the install already has is modified or deleted: the
    English launcher reaches the game through directory junctions, and its own extra files sit beside the
    originals under their own names. -Remove undoes exactly what was added.

    ASCII with no byte-order mark on purpose: this file is fetched and run with iex, and a leading
    byte-order mark makes PowerShell fail to parse it.

.EXAMPLE
    iex (irm https://raw.githubusercontent.com/reiness/fgo-arcade-en-launcher/main/install.ps1)

.EXAMPLE
    &([scriptblock]::Create((irm https://raw.githubusercontent.com/reiness/fgo-arcade-en-launcher/main/install.ps1))) -Install 'D:\FGO ARCADE'

.EXAMPLE
    &([scriptblock]::Create((irm https://raw.githubusercontent.com/reiness/fgo-arcade-en-launcher/main/install.ps1))) -Remove
#>
[CmdletBinding()]
param(
    [string]$Install,
    [string]$PayloadPath,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoOwner        = 'reiness'
$RepoName         = 'fgo-arcade-en-launcher'
$Branch           = 'main'
$ReleaseTag       = 'v1.0.0'
$PayloadName      = 'fgo-en-launcher-v1.0.0.zip'
$PayloadSha256    = '1ABDDCB8BB6620FA0B28997662161D8E3C600AA2FBC94A063C7DB197C69820B2'
$EngineName       = 'New-EnglishLauncher.ps1'
$MinimumFreeBytes = 1GB
$RawRoot          = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
$PayloadUrl       = "https://github.com/$RepoOwner/$RepoName/releases/download/$ReleaseTag/$PayloadName"
$LikelyInstalls   = @('XGames\FGO ARCADE', 'FGO ARCADE', 'Games\FGO ARCADE', 'FGOA', 'Games\FGOA')

function Stop-WithMessage([string]$Message) {
    Write-Host ''
    Write-Host "STOPPED: $Message" -ForegroundColor Red
    exit 1
}

function Test-NvidiaPresent([object[]]$Adapters) {
    # CN release note, issue 2: the game uses NVIDIA-only OpenGL extensions, so Intel and AMD cannot enter it.
    # A hybrid machine with both an NVIDIA card and Intel or AMD graphics passes: any NVIDIA adapter is enough.
    if (-not $Adapters) { $Adapters = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue) }
    return @($Adapters | Where-Object { $_.AdapterCompatibility -match 'NVIDIA' -or $_.Name -match 'NVIDIA' }).Count -gt 0
}

function Get-PrimaryIPv4Address {
    # The same rule FGO_Launcher.ps1 uses, so this check and the launcher can never disagree.
    $address = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address } |
        ForEach-Object {
            $_.IPv4Address |
                Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1
        } |
        Select-Object -First 1
    if ($address) { return [string]$address.IPAddress }
    return $null
}

function Test-SupportedLanAddress([string]$Address) {
    # CN release note, issue 3: the game only deploys on a 192.168.x.x network.
    return $Address -like '192.168.*'
}

function Test-InstallFolder([string]$Path) {
    if (-not $Path) { return $false }
    foreach ($needed in @('App\ago.exe', 'App', 'Server', 'logs')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $needed))) { return $false }
    }
    return $true
}

function Find-InstallFolder {
    foreach ($disk in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction SilentlyContinue)) {
        foreach ($name in $LikelyInstalls) {
            $candidate = Join-Path ($disk.DeviceID + '\') $name
            if (Test-InstallFolder $candidate) { return $candidate }
        }
    }
    return $null
}

function Get-DiskForPath([string]$Path) {
    $root = [System.IO.Path]::GetPathRoot($Path).TrimEnd('\')
    return Get-CimInstance Win32_LogicalDisk -Filter "DeviceID = '$root'" -ErrorAction SilentlyContinue
}

function Get-BlockingProcesses([string[]]$Folders) {
    # Only a process running FROM one of these folders counts - the same rule New-EnglishLauncher.ps1 uses,
    # so another copy of the game elsewhere on the machine is not a reason to refuse. A process whose path
    # cannot be read is counted anyway, because it cannot be ruled out.
    $found = @()
    $filter = "Name='FGOLocalPlatform.exe' OR Name='ago.exe' OR Name='amdaemon.exe'"
    foreach ($process in @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction SilentlyContinue)) {
        $running = $process.ExecutablePath
        if (-not $running) {
            # Started as administrator: a normal-rights session cannot read its folder, so it cannot be
            # ruled out. Say that plainly rather than claiming it belongs to this install.
            $found += "$($process.Name) (pid $($process.ProcessId), started as administrator so its folder cannot be read)"
            continue
        }
        foreach ($folder in $Folders) {
            if (-not $folder) { continue }
            $prefix = $folder.TrimEnd('\') + '\'
            if ($running.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $found += "$($process.Name) (pid $($process.ProcessId))"
            }
        }
    }
    return $found
}

function Get-RemoteFile([string]$Url, [string]$Destination) {
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    }
    catch {
        $status = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $status = $_.Exception.Response.StatusCode.value__
        }
        if ($status -eq 404) {
            Stop-WithMessage ("Not found (404): $Url" + [Environment]::NewLine +
                '         If the repository is still private, it has to be made public before this command can work.')
        }
        Stop-WithMessage "Could not download $Url - $($_.Exception.Message)"
    }
}

function Get-Engine([string]$Workspace, [string]$Payload) {
    # Beside the payload (the manual route), then beside this script (a clone of the repository), then from
    # the repository itself. Looking locally first is what lets the manual route work with no network at all.
    $enginePath = Join-Path $Workspace $EngineName
    $candidates = @()
    if ($Payload) { $candidates += Join-Path (Split-Path -Parent $Payload) $EngineName }
    if ($PSScriptRoot) {
        $candidates += Join-Path $PSScriptRoot "tools\$EngineName"
        $candidates += Join-Path $PSScriptRoot $EngineName
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            Copy-Item -LiteralPath $candidate -Destination $enginePath
            return $enginePath
        }
    }
    Get-RemoteFile "$RawRoot/tools/$EngineName" $enginePath
    return $enginePath
}

Write-Host ''
Write-Host 'FGO ARCADE - English launcher' -ForegroundColor Cyan
Write-Host 'Adds a second, English launcher beside your existing one. Nothing you already have is changed.'
Write-Host ''

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Stop-WithMessage "This needs Windows PowerShell 5.1 or newer - this one is $($PSVersionTable.PSVersion)."
}

if (-not $Install) { $Install = Find-InstallFolder }
if (-not $Install) {
    Write-Host 'I could not find your FGO ARCADE folder automatically.'
    $Install = (Read-Host 'Type the full path to it (the folder that contains App, Server and logs)').Trim('"', ' ')
}
if (-not (Test-InstallFolder $Install)) {
    Stop-WithMessage "$Install does not look like an FGO ARCADE install - it has no App\ago.exe, or no Server or logs folder."
}
$Install = (Resolve-Path -LiteralPath $Install).Path.TrimEnd('\')
Write-Host "Install: $Install"

$blocking = @(Get-BlockingProcesses @($Install, "$Install EN"))
if ($blocking.Count -gt 0) {
    Stop-WithMessage ('Close the game and the launcher first - still running: ' + (($blocking | Sort-Object -Unique) -join ', '))
}

$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('fgo-en-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $workspace -Force | Out-Null
try {
    if ($Remove) {
        Write-Host 'Removing the English launcher...'
        & (Get-Engine $workspace $PayloadPath) -Install $Install -Remove
        Write-Host ''
        Write-Host 'Done. Your install is back exactly as it was.' -ForegroundColor Green
        return
    }

    if (-not (Test-NvidiaPresent)) {
        Stop-WithMessage ('No NVIDIA graphics card found. This port of the game only runs on NVIDIA cards -' + [Environment]::NewLine +
            '         on Intel or AMD graphics it cannot enter the game at all. That is a known limit of the' + [Environment]::NewLine +
            '         Chinese release, not of this English patch, so installing would not help.')
    }

    $ip = Get-PrimaryIPv4Address
    if (-not $ip) { Stop-WithMessage 'No active network adapter with a default gateway was found. Connect to your network and try again.' }
    if (-not (Test-SupportedLanAddress $ip)) {
        Stop-WithMessage ("Your network address is $ip, and the game only deploys on a 192.168.x.x network." + [Environment]::NewLine +
            '         That is a known limit of the Chinese release. The launcher would refuse to start the game.')
    }
    Write-Host "Network: $ip"

    $disk = Get-DiskForPath $Install
    if ($disk -and $disk.FileSystem -and $disk.FileSystem -ne 'NTFS') {
        Stop-WithMessage "The install is on a $($disk.FileSystem) drive. The English launcher needs NTFS, because it links to your game folders."
    }
    if ($disk -and $disk.FreeSpace -lt $MinimumFreeBytes) {
        Stop-WithMessage ('Not enough free space on ' + $disk.DeviceID + ' - about 1 GB is needed.')
    }
    if ($Install -like "$env:ProgramFiles*" -or $Install -like "${env:ProgramFiles(x86)}*") {
        Write-Host 'Note: your game is under Program Files, so Windows may ask for administrator rights while adding files.' -ForegroundColor Yellow
    }

    $target = "$Install EN"
    if (Test-Path -LiteralPath $target) {
        Stop-WithMessage ("The English launcher is already there: $target" + [Environment]::NewLine +
            '         To reinstall it, remove it first with the -Remove form of this command (see the README).')
    }

    $enginePath = Get-Engine $workspace $PayloadPath

    if ($PayloadPath) {
        $zipPath = (Resolve-Path -LiteralPath $PayloadPath).Path
        Write-Host "Payload: $zipPath (already downloaded)"
    }
    else {
        $zipPath = Join-Path $workspace $PayloadName
        Write-Host 'Downloading the English patch (about 65 MB)...'
        Get-RemoteFile $PayloadUrl $zipPath
    }

    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    if ($actual -ne $PayloadSha256) {
        Stop-WithMessage ('The download did not arrive intact, so nothing was changed.' + [Environment]::NewLine +
            "         expected $PayloadSha256" + [Environment]::NewLine +
            "         got      $actual" + [Environment]::NewLine +
            '         Run the command again.')
    }
    Write-Host 'Checked: the download matches its published fingerprint.'

    $build = Join-Path $workspace 'payload'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $build)

    Write-Host ''
    & $enginePath -Install $Install -Build $build
    Write-Host ''
    Write-Host "Done. Your English launcher is at: $target" -ForegroundColor Green
    Write-Host 'Start it by right-clicking FGOLocalPlatform.exe in that folder and choosing Run as administrator.'
    Write-Host 'Run as administrator is required - without it the game stops at ERROR 4102.'
}
finally {
    if (Test-Path -LiteralPath $workspace) {
        try { [System.IO.Directory]::Delete($workspace, $true) } catch { }
    }
}