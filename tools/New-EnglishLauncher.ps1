<#
.SYNOPSIS
    Creates a second launcher folder that runs a translated FGOLocalPlatform.exe against the SAME install - same
    accounts, same database, same game files - without modifying anything the install already has.

.DESCRIPTION
    The platform derives every path from the folder its own executable sits in (GameRoot = <exeDir>\App, with
    Server and logs beside it), so a folder holding the translated exe plus directory junctions named App, Server
    and logs IS a complete second launcher. Junctions need no administrator rights on NTFS.
    The five files that carry translated text but live in the shared folders (the two control guides, the launcher
    script, the account tool, the server-config tool and the summon notes) are ADDED next to the originals under
    their own names; the translated exe looks for those names. Nothing that already exists is modified or deleted.
    Every change is written to a manifest BEFORE it is made, so -Remove undoes exactly what was done, and a create
    that fails part-way rolls itself back through the same routine.
    A junction is always deleted as a link, never recursively: deleting THROUGH one would destroy the real install.
    This file is ASCII-only on purpose: Windows PowerShell 5.1 reads BOM-less scripts in the system code page.

.EXAMPLE
    .\tools\New-EnglishLauncher.ps1 -Install 'X:\XGames\FGO ARCADE' -Build .\out\en-side

.EXAMPLE
    .\tools\New-EnglishLauncher.ps1 -Install 'X:\XGames\FGO ARCADE' -Remove

.OUTPUTS
    <Target>\FGOLocalPlatform.exe        the translated launcher
    <Target>\App | Server | DEVICE | ...  junctions to every folder of the install
    <Target>\english-launcher.json       the junctions, the folders and the files it created, with hashes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Install,
    [string]$Build,
    [string]$Target,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$PlatformExeName = 'FGOLocalPlatform.exe'
$ManifestName = 'english-launcher.json'
$RequiredFolders = @('App', 'Server', 'logs')
$BlockingProcesses = @('FGOLocalPlatform', 'ago')

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-ReparsePoint([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    $null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Remove-Junction([string]$Path) {
    # Delete the link itself. A recursive delete would follow it and empty the real folder.
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if (-not (Test-ReparsePoint $Path)) { throw "$Path is a real folder, not a junction - refusing to delete it." }
    [System.IO.Directory]::Delete($Path, $false)
}

function Get-SharedFolders([string]$InstallPath) {
    # Every folder of the install, because the platform reaches siblings of App by relative path: deck.json's
    # CardsPath is "..\DEVICE\print\...", resolved from the folder the exe sits in. Hidden folders (.claude and
    # friends) are tooling, not the game.
    Get-ChildItem -LiteralPath $InstallPath -Directory |
        Where-Object { -not $_.Name.StartsWith('.') } |
        ForEach-Object { $_.Name }
}

function Assert-Install([string]$Path) {
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'App\ago.exe'))) {
        throw "$Path does not look like an FGO ARCADE install (App\ago.exe is missing)."
    }
    foreach ($folder in $RequiredFolders) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $folder))) { throw "$Path has no $folder folder to share." }
    }
}

function Assert-NothingRunning([string[]]$Folders) {
    foreach ($name in $BlockingProcesses) {
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $running = try { $process.Path } catch { $null }
            foreach ($folder in $Folders) {
                $prefix = $folder.TrimEnd('\') + '\'
                if ($running -and $running.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "$name is running from $folder (pid $($process.Id)). Close it first."
                }
            }
        }
    }
}

function Get-BuildAssets([string]$BuildPath) {
    # Everything except the launcher executable itself: each one is added to the install beside its original.
    $prefix = (Resolve-Path -LiteralPath $BuildPath).Path.TrimEnd('\') + '\'
    Get-ChildItem -LiteralPath $BuildPath -Recurse -File |
        Where-Object { $_.FullName -ne (Join-Path $prefix $PlatformExeName) } |
        ForEach-Object { $_.FullName.Substring($prefix.Length) }
}

function Save-Manifest($Manifest, [string]$Path) {
    $Manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-RecordedFolder($Manifest, [string]$Path, [string]$ManifestPath) {
    # Records each level BEFORE creating it, so removal knows exactly which folders are ours to take away again.
    $missing = @()
    $folder = $Path
    while ($folder -and -not (Test-Path -LiteralPath $folder)) {
        $missing = @($folder) + $missing
        $folder = Split-Path -Parent $folder
    }
    foreach ($item in $missing) {
        $Manifest.folders += $item
        Save-Manifest $Manifest $ManifestPath
        New-Item -ItemType Directory -Path $item | Out-Null
    }
}

function Undo-Manifest($Manifest, [string]$TargetPath) {
    foreach ($file in @($Manifest.files)) {
        if (Test-Path -LiteralPath $file.path) { Remove-Item -LiteralPath $file.path -Force }
    }
    # Only folders this script created, deepest first, and only while empty. A folder that was already there stays,
    # even once it is empty - it was never ours.
    foreach ($folder in @($Manifest.folders) | Sort-Object -Property Length -Descending) {
        if ((Test-Path -LiteralPath $folder) -and -not (Test-ReparsePoint $folder) -and
            -not (Get-ChildItem -LiteralPath $folder -Force)) {
            Remove-Item -LiteralPath $folder -Force
        }
    }
    foreach ($junction in @($Manifest.junctions)) { Remove-Junction (Join-Path $TargetPath $junction) }
    if ($Manifest.launcherExe -and (Test-Path -LiteralPath $Manifest.launcherExe)) {
        Remove-Item -LiteralPath $Manifest.launcherExe -Force
    }
    $manifestPath = Join-Path $TargetPath $ManifestName
    if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
    if ((Test-Path -LiteralPath $TargetPath) -and -not (Get-ChildItem -LiteralPath $TargetPath -Force)) {
        Remove-Item -LiteralPath $TargetPath -Force
    }
}

function Assert-AddOnly([string]$InstallPath, [string[]]$Assets) {
    $existing = @($Assets | Where-Object { Test-Path -LiteralPath (Join-Path $InstallPath $_) })
    if ($existing.Count -gt 0) {
        throw ("Refusing to overwrite files the install already has: " + ($existing -join ', '))
    }
}

function New-Launcher([string]$InstallPath, [string]$BuildPath, [string]$TargetPath) {
    $assets = @(Get-BuildAssets $BuildPath)
    Assert-AddOnly $InstallPath $assets
    New-Item -ItemType Directory -Path $TargetPath | Out-Null
    $manifestPath = Join-Path $TargetPath $ManifestName
    $manifest = [pscustomobject]@{
        createdAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
        install         = $InstallPath
        target          = $TargetPath
        build           = (Resolve-Path -LiteralPath $BuildPath).Path
        installExeSha256 = if (Test-Path -LiteralPath (Join-Path $InstallPath $PlatformExeName)) {
            Get-Sha256 (Join-Path $InstallPath $PlatformExeName) } else { $null }
        launcherExe     = $null
        junctions       = @()
        folders         = @()
        files           = @()
    }
    Save-Manifest $manifest $manifestPath
    try {
        foreach ($folder in Get-SharedFolders $InstallPath) {
            $manifest.junctions += $folder
            Save-Manifest $manifest $manifestPath
            New-Item -ItemType Junction -Path (Join-Path $TargetPath $folder) -Target (Join-Path $InstallPath $folder) | Out-Null
            Write-Host ("shared   {0} -> {1}" -f $folder, (Join-Path $InstallPath $folder))
        }
        foreach ($asset in $assets) {
            $destination = Join-Path $InstallPath $asset
            $manifest.files += [pscustomobject]@{ path = $destination; sha256 = Get-Sha256 (Join-Path $BuildPath $asset) }
            Save-Manifest $manifest $manifestPath
            New-RecordedFolder $manifest (Split-Path -Parent $destination) $manifestPath
            Copy-Item -LiteralPath (Join-Path $BuildPath $asset) -Destination $destination
            Write-Host ("added    {0}" -f $asset)
        }
        $launcherExe = Join-Path $TargetPath $PlatformExeName
        $manifest.launcherExe = $launcherExe
        Save-Manifest $manifest $manifestPath
        Copy-Item -LiteralPath (Join-Path $BuildPath $PlatformExeName) -Destination $launcherExe
        Write-Host ("launcher {0}" -f $launcherExe)
    }
    catch {
        Write-Warning "Creation failed - undoing what was done so far."
        Undo-Manifest $manifest $TargetPath
        throw
    }
    $manifest
}

$Install = (Resolve-Path -LiteralPath $Install).Path.TrimEnd('\')
if (-not $Target) { $Target = $Install + ' EN' }
Assert-Install $Install

if ($Remove) {
    $manifestPath = Join-Path $Target $ManifestName
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw "$Target holds no $ManifestName - nothing to remove." }
    Assert-NothingRunning @($Install, $Target)
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $removed = @($manifest.files).Count
    Undo-Manifest $manifest $Target
    Write-Host ''
    Write-Host ("Removed the launcher at $Target and the $removed file(s) it added to $Install")
    if (Test-Path -LiteralPath $Target) {
        $left = @(Get-ChildItem -LiteralPath $Target -Force | ForEach-Object { $_.Name })
        Write-Host ("Kept the folder: it still holds " + ($left -join ', ') + " - not ours to delete.")
    }
    return
}

if (-not $Build) { throw 'Give -Build (the side-by-side build folder, e.g. .\out\en-side) or -Remove.' }
if (-not (Test-Path -LiteralPath (Join-Path $Build $PlatformExeName))) {
    throw "$Build does not look like a side-by-side build ($PlatformExeName is missing)."
}
if (Test-Path -LiteralPath $Target) { throw "$Target already exists. Remove it first (-Remove) or pass another -Target." }
Assert-NothingRunning @($Install)
$manifest = New-Launcher $Install $Build $Target
Write-Host ''
Write-Host ("Launcher ready: " + (Join-Path $Target $PlatformExeName))
Write-Host ("It shares every folder of $Install - one set of accounts, one database, one game, one card library.")
Write-Host 'Run ONE launcher at a time: both of them manage the same local server and the same accounts.'
Write-Host ("Undo with: .\tools\New-EnglishLauncher.ps1 -Install '$Install' -Remove")
