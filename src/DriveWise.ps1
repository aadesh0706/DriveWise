#requires -Version 5.1
<#
  DriveWise - Smart Disk Cleanup
  ------------------------------
  Author  : Aadesh Gulumbe (github.com/aadesh0706)
  Website : https://github.com/aadesh0706/DriveWise
  License : MIT

.SYNOPSIS
  Scans your drives for space hogs and lets you remove them with one click,
  through a local web dashboard.

.DESCRIPTION
  Starts a small local web server on this PC and opens a browser dashboard
  that:
    1. Lists every connected drive with its usage.
    2. Scans for common junk/cache locations on the system drive (Windows
       Update cache, temp files, browser cache, Recycle Bin, old Windows
       install, etc).
    3. Scans for the largest folders and largest individual files on
       whichever drive you select.
    4. Lists installed programs with their reported disk usage.
  Every item found has a Remove button. Junk/cache items are permanently
  deleted (they regenerate automatically). Large folders/files are sent to
  the Recycle Bin so they can be restored. Programs are removed via their
  official uninstaller.

  A built-in blocklist refuses to delete core Windows/Program Files/Users
  folders (or the root of any drive) no matter what, and the delete API only
  ever acts on a path this tool itself just discovered during a scan.

.NOTES
  Runs on the PowerShell that ships with every Windows PC (Windows
  PowerShell 5.1) - no extra installs needed. Launch as Administrator for
  the most complete scan results; it still works without elevation, just
  with some protected folders skipped.
#>

param(
    [int]$Port = 8791
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName Microsoft.VisualBasic

try { $Host.UI.RawUI.WindowTitle = "DriveWise" } catch {}

$AppName    = "DriveWise"
$AppVersion = "1.0.0"
$AppAuthor  = "Aadesh Gulumbe"
$AppRepo    = "https://github.com/aadesh0706/DriveWise"

$SystemDrive        = $env:SystemDrive          # e.g. C:
$UsersRoot          = "$SystemDrive\Users"
$CurrentUserProfile = $env:USERPROFILE

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    elseif ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else { return "$Bytes B" }
}

function Get-FolderSizeBytes {
    param([string]$Path)
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if (-not $sum) { return 0 }
        return [int64]$sum
    } catch {
        return 0
    }
}

# Locations that must never be offered for deletion, no matter what a scan finds.
# Computed per-drive, based on the drive root of whatever path is being checked.
function Get-ProtectedPathsForDrive {
    param([string]$DriveLetter)
    $list = @(
        "$DriveLetter\",
        "$DriveLetter",
        "$DriveLetter\System Volume Information"
    )
    if ($DriveLetter -ieq $SystemDrive) {
        $list += @(
            "$DriveLetter\Windows",
            "$DriveLetter\Windows\System32",
            "$DriveLetter\Windows\SysWOW64",
            "$DriveLetter\Windows\WinSxS",
            "$DriveLetter\Windows\Boot",
            "$DriveLetter\Program Files",
            "$DriveLetter\Program Files (x86)",
            "$DriveLetter\Users",
            "$DriveLetter\ProgramData",
            "$DriveLetter\pagefile.sys",
            "$DriveLetter\hiberfil.sys",
            "$DriveLetter\swapfile.sys"
        )
    }
    return $list | ForEach-Object { $_.TrimEnd('\') }
}

function Test-IsProtected {
    param([string]$Path)
    $root = [System.IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($root)) { return $true }
    $driveLetter = $root.TrimEnd('\')
    $protectedList = Get-ProtectedPathsForDrive -DriveLetter $driveLetter
    $norm = $Path.TrimEnd('\')
    foreach ($p in $protectedList) {
        if ($norm -ieq $p) { return $true }
    }
    return $false
}

# Only paths we ourselves discovered during a scan can be deleted through the
# API - this stops the delete endpoint from ever being used on an arbitrary
# path that wasn't shown to the user first.
$script:KnownPaths    = @{}
$script:KnownPrograms = @{}

function Register-KnownPath {
    param([string]$Path, [string]$Kind)
    $script:KnownPaths[$Path.TrimEnd('\')] = $Kind
}

function Get-QueryParam {
    param($Request, [string]$Name, [string]$Default = '')
    $q = $Request.Url.Query
    if ([string]::IsNullOrEmpty($q)) { return $Default }
    $q = $q.TrimStart('?')
    foreach ($pairText in ($q -split '&')) {
        $kv = $pairText -split '=', 2
        if ($kv[0] -eq $Name) {
            if ($kv.Length -gt 1) { return [System.Uri]::UnescapeDataString($kv[1]) }
            else { return '' }
        }
    }
    return $Default
}

function Get-AllDrives {
    Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveType -in @(2, 3, 4) -and $_.Size -gt 0 } |
        ForEach-Object {
            $typeLabel = switch ($_.DriveType) {
                2 { "Removable" }
                3 { "Fixed" }
                4 { "Network" }
                default { "Other" }
            }
            $total = [int64]$_.Size
            $free  = [int64]$_.FreeSpace
            $used  = $total - $free
            [PSCustomObject]@{
                drive         = $_.DeviceID
                label         = if ($_.VolumeName) { $_.VolumeName } else { "$typeLabel Drive" }
                type          = $typeLabel
                isSystem      = [bool]($_.DeviceID -ieq $SystemDrive)
                totalBytes    = $total
                usedBytes     = $used
                freeBytes     = $free
                totalReadable = Format-Bytes $total
                usedReadable  = Format-Bytes $used
                freeReadable  = Format-Bytes $free
                percentUsed   = if ($total -gt 0) { [math]::Round((($used / $total) * 100), 1) } else { 0 }
            }
        } | Sort-Object -Property @{Expression = { $_.isSystem }; Descending = $true }, drive
}

function Get-JunkCandidates {
    $candidates = @(
        @{ Path = "$SystemDrive\Windows\SoftwareDistribution\Download"; Name = "Windows Update Cache"; Desc = "Leftover update installers. Safe to delete - Windows re-downloads what it needs."; Safe = $true }
        @{ Path = "$SystemDrive\Windows\Temp"; Name = "Windows Temp Files"; Desc = "System temporary files. Safe to delete."; Safe = $true }
        @{ Path = "$env:LOCALAPPDATA\Temp"; Name = "User Temp Files"; Desc = "Your account's temporary files. Safe to delete."; Safe = $true }
        @{ Path = "$SystemDrive\`$Recycle.Bin"; Name = "Recycle Bin"; Desc = "Deleted files waiting for permanent removal."; Safe = $true }
        @{ Path = "$SystemDrive\Windows.old"; Name = "Previous Windows Installation"; Desc = "Backup of your prior Windows install after an upgrade. Safe once the new install is stable."; Safe = $true }
        @{ Path = "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"; Name = "Edge/IE Browser Cache"; Desc = "Browser cache files. Safe to delete."; Safe = $true }
        @{ Path = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache"; Name = "Chrome Cache"; Desc = "Browser cache files. Safe to delete."; Safe = $true }
        @{ Path = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"; Name = "Thumbnail Cache"; Desc = "Cached thumbnail images. Safe to delete, it regenerates."; Safe = $true }
        @{ Path = "$env:APPDATA\npm-cache"; Name = "npm Cache"; Desc = "Node.js package cache. Safe to delete."; Safe = $true }
        @{ Path = "$env:LOCALAPPDATA\pip\Cache"; Name = "pip Cache"; Desc = "Python package cache. Safe to delete."; Safe = $true }
        @{ Path = "$env:LOCALAPPDATA\CrashDumps"; Name = "Crash Dumps"; Desc = "Diagnostic crash data. Safe to delete."; Safe = $true }
        @{ Path = "$env:ProgramData\Microsoft\Windows\WER"; Name = "Windows Error Reports"; Desc = "Error reporting data. Safe to delete."; Safe = $true }
        @{ Path = "$SystemDrive\Windows\Logs"; Name = "Windows Log Files"; Desc = "System log files. Generally safe to delete."; Safe = $true }
        @{ Path = "$SystemDrive\Windows\Installer"; Name = "Windows Installer Cache"; Desc = "Used to repair/uninstall programs later. Deleting can break future uninstalls - not recommended."; Safe = $false }
        @{ Path = "$SystemDrive\System Volume Information"; Name = "System Restore Points"; Desc = "System protection data. Manage this via System Restore settings, not direct deletion."; Safe = $false }
    )

    $results = @()
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c.Path) {
            $size = Get-FolderSizeBytes -Path $c.Path
            if ($size -gt 0) {
                Register-KnownPath -Path $c.Path -Kind 'junk'
                $results += [PSCustomObject]@{
                    name         = $c.Name
                    path         = $c.Path
                    sizeBytes    = $size
                    sizeReadable = Format-Bytes $size
                    description  = $c.Desc
                    safe         = $c.Safe
                }
            }
        }
    }
    return $results | Sort-Object -Property sizeBytes -Descending
}

function Get-BigFolders {
    param([string]$DriveLetter)
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { $DriveLetter = $SystemDrive }

    $roots = New-Object System.Collections.Generic.List[string]

    if ($DriveLetter -ieq $SystemDrive) {
        if (Test-Path -LiteralPath $UsersRoot) {
            Get-ChildItem -LiteralPath $UsersRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    $roots.Add($_.FullName)
                }
            }
        }
        foreach ($p in @("$DriveLetter\Program Files", "$DriveLetter\Program Files (x86)", "$env:ProgramData")) {
            if (Test-Path -LiteralPath $p) {
                Get-ChildItem -LiteralPath $p -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    $roots.Add($_.FullName)
                }
            }
        }
    } else {
        $root = "$DriveLetter\"
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $roots.Add($_.FullName)
                Get-ChildItem -LiteralPath $_.FullName -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    $roots.Add($_.FullName)
                }
            }
        }
    }

    $results = @()
    foreach ($path in ($roots | Select-Object -Unique)) {
        if (Test-IsProtected -Path $path) { continue }
        $size = Get-FolderSizeBytes -Path $path
        if ($size -gt 100MB) {
            Register-KnownPath -Path $path -Kind 'folder'
            $results += [PSCustomObject]@{
                path         = $path
                sizeBytes    = $size
                sizeReadable = Format-Bytes $size
            }
        }
    }
    return $results | Sort-Object -Property sizeBytes -Descending | Select-Object -First 50
}

function Get-BigFiles {
    param([string]$DriveLetter)
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { $DriveLetter = $SystemDrive }

    if ($DriveLetter -ieq $SystemDrive) {
        $roots = @($CurrentUserProfile, "$env:ProgramData")
    } else {
        $roots = @("$DriveLetter\")
    }

    $results = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 200MB } |
            ForEach-Object {
                if (-not (Test-IsProtected -Path $_.FullName)) {
                    Register-KnownPath -Path $_.FullName -Kind 'file'
                    $results += [PSCustomObject]@{
                        path         = $_.FullName
                        sizeBytes    = [int64]$_.Length
                        sizeReadable = Format-Bytes $_.Length
                        modified     = $_.LastWriteTime.ToString('yyyy-MM-dd')
                    }
                }
            }
    }
    return $results | Sort-Object -Property sizeBytes -Descending | Select-Object -First 60
}

function Get-InstalledPrograms {
    param([string]$DriveLetter)
    if ([string]::IsNullOrWhiteSpace($DriveLetter)) { $DriveLetter = $SystemDrive }

    $keys = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $seen = @{}
    $all = @()
    Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.DisplayName
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        if ($seen.ContainsKey($name)) { return }
        $seen[$name] = $true

        $sizeBytes = 0
        if ($_.EstimatedSize) { $sizeBytes = [int64]$_.EstimatedSize * 1KB }

        $script:KnownPrograms[$name] = $_.UninstallString

        $installLoc = $_.InstallLocation
        $progDrive = $null
        if (-not [string]::IsNullOrWhiteSpace($installLoc) -and $installLoc.Length -ge 2 -and $installLoc[1] -eq ':') {
            $progDrive = $installLoc.Substring(0, 2)
        }

        $all += [PSCustomObject]@{
            name            = $name
            publisher       = $_.Publisher
            sizeBytes       = $sizeBytes
            sizeReadable    = if ($sizeBytes -gt 0) { Format-Bytes $sizeBytes } else { "Unknown" }
            installLocation = $installLoc
            installDate     = $_.InstallDate
            _drive          = $progDrive
        }
    }

    $filtered = $all | Where-Object {
        if ($null -ne $_._drive) { $_._drive -ieq $DriveLetter }
        else { $DriveLetter -ieq $SystemDrive }
    }

    return $filtered | Select-Object name, publisher, sizeBytes, sizeReadable, installLocation, installDate |
        Sort-Object -Property sizeBytes -Descending
}

# ---------------------------------------------------------------------------
# Delete / uninstall actions
# ---------------------------------------------------------------------------

function Invoke-DeletePath {
    param([string]$Path, [string]$Kind)

    if ([string]::IsNullOrWhiteSpace($Path)) { throw "No path supplied." }
    $norm = $Path.TrimEnd('\')

    if (Test-IsProtected -Path $norm) {
        throw "Refusing to delete a protected system location: $Path"
    }
    if (-not $script:KnownPaths.ContainsKey($norm)) {
        throw "This path wasn't part of a scan result - refusing to delete: $Path"
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path no longer exists: $Path"
    }

    $isDir = (Get-Item -LiteralPath $Path -Force).PSIsContainer

    if ($Kind -eq 'junk') {
        # Cache/temp locations regenerate automatically - permanent delete is fine.
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } else {
        # Anything else goes to the Recycle Bin so it can be restored.
        if ($isDir) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $Path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $Path,
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
        }
    }
    $script:KnownPaths.Remove($norm)
}

function Invoke-Uninstall {
    param([string]$Name)
    if (-not $script:KnownPrograms.ContainsKey($Name)) {
        throw "Unknown program: $Name"
    }
    $uninstallString = $script:KnownPrograms[$Name]
    if ([string]::IsNullOrWhiteSpace($uninstallString)) {
        throw "No uninstall command was reported for this program."
    }
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$uninstallString`"" -WindowStyle Normal
}

# ---------------------------------------------------------------------------
# Front-end (single page, no external dependencies)
# ---------------------------------------------------------------------------

$indexHtml = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DriveWise - Smart Disk Cleanup</title>
<style>
  :root {
    --bg: #0b0e17; --bg2: #10141f;
    --panel: #141a29; --panel2: #1a2236; --panel3: #1f2942;
    --border: #253253; --border-soft: #1c2540;
    --text: #eef1fa; --muted: #8b97b8; --muted2: #64719a;
    --accent: #5b8dff; --accent2: #8f6bff;
    --grad: linear-gradient(135deg, #5b8dff 0%, #8f6bff 100%);
    --green: #33d17a; --green-bg: rgba(51,209,122,.12);
    --yellow: #f0b429; --yellow-bg: rgba(240,180,41,.12);
    --red: #ff5d6c; --red-bg: rgba(255,93,108,.12);
    --radius: 16px; --radius-sm: 10px;
    --shadow: 0 8px 30px rgba(0,0,0,.35);
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; }
  body {
    margin: 0; font-family: "Segoe UI", -apple-system, Roboto, Arial, sans-serif;
    background:
      radial-gradient(1200px 600px at 15% -10%, rgba(91,141,255,.14), transparent 60%),
      radial-gradient(900px 500px at 100% 0%, rgba(143,107,255,.10), transparent 55%),
      var(--bg);
    color: var(--text);
    min-height: 100%;
  }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }

  /* ---------- Header ---------- */
  header.top {
    display: flex; align-items: center; justify-content: space-between;
    padding: 22px 32px 6px;
  }
  .brand { display: flex; align-items: center; gap: 12px; }
  .brand-badge {
    width: 40px; height: 40px; border-radius: 12px; background: var(--grad);
    display: flex; align-items: center; justify-content: center;
    box-shadow: 0 6px 18px rgba(91,141,255,.35);
    font-weight: 800; font-size: 15px; color: #fff; letter-spacing: -0.5px;
  }
  .brand-text h1 { margin: 0; font-size: 19px; font-weight: 700; letter-spacing: -0.2px; }
  .brand-text .ver { color: var(--muted2); font-size: 11.5px; font-weight: 600; }
  .top-actions { display: flex; align-items: center; gap: 10px; }
  .pill-btn {
    display: inline-flex; align-items: center; gap: 7px;
    background: var(--panel2); border: 1px solid var(--border); color: var(--text);
    padding: 9px 15px; border-radius: 999px; cursor: pointer; font-size: 12.5px; font-weight: 600;
    transition: all .15s ease;
  }
  .pill-btn:hover { border-color: var(--accent); background: var(--panel3); text-decoration: none; }
  .pill-btn.primary { background: var(--grad); border: none; color: #fff; box-shadow: 0 6px 16px rgba(91,141,255,.3); }
  .pill-btn.primary:hover { filter: brightness(1.08); }
  .pill-btn svg { width: 14px; height: 14px; }

  main { padding: 10px 32px 50px; max-width: 1180px; margin: 0 auto; }

  /* ---------- Drive selector ---------- */
  .section-label {
    font-size: 12px; font-weight: 700; text-transform: uppercase; letter-spacing: .06em;
    color: var(--muted2); margin: 22px 2px 10px;
  }
  .drive-row { display: flex; gap: 12px; flex-wrap: wrap; }
  .drive-card {
    position: relative; width: 178px; padding: 14px 16px; border-radius: var(--radius-sm);
    background: var(--panel); border: 1.5px solid var(--border-soft); cursor: pointer;
    transition: all .15s ease;
  }
  .drive-card:hover { border-color: var(--accent); transform: translateY(-1px); }
  .drive-card.active { border-color: var(--accent); background: var(--panel2); box-shadow: 0 0 0 3px rgba(91,141,255,.15); }
  .drive-card .dtop { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 8px; }
  .drive-card .letter { font-size: 20px; font-weight: 800; }
  .drive-card .type-badge {
    font-size: 9.5px; font-weight: 700; text-transform: uppercase; letter-spacing: .04em;
    color: var(--muted); background: var(--panel3); padding: 2px 7px; border-radius: 999px;
  }
  .drive-card .label { font-size: 11.5px; color: var(--muted); margin-bottom: 10px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .drive-card .mini-track { height: 6px; border-radius: 4px; background: var(--panel3); overflow: hidden; margin-bottom: 8px; }
  .drive-card .mini-fill { height: 100%; border-radius: 4px; }
  .drive-card .dstat { font-size: 11px; color: var(--muted2); }

  /* ---------- Overview card ---------- */
  .overview {
    margin-top: 18px; background: var(--panel); border: 1px solid var(--border-soft);
    border-radius: var(--radius); padding: 22px 24px; box-shadow: var(--shadow);
  }
  .overview .orow { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 12px; flex-wrap: wrap; gap: 6px; }
  .overview .otitle { font-size: 16px; font-weight: 700; }
  .overview .ostats { color: var(--muted); font-size: 13px; }
  .bar-track { height: 16px; border-radius: 8px; background: var(--panel3); overflow: hidden; }
  .bar-fill { height: 100%; border-radius: 8px; transition: width .5s cubic-bezier(.4,0,.2,1); background: var(--grad); }
  .freed { margin-top: 12px; font-size: 13px; color: var(--green); font-weight: 600; display: none; align-items: center; gap: 6px; }
  .freed.show { display: flex; }

  /* ---------- Tabs ---------- */
  nav.tabs { display: flex; gap: 8px; margin: 26px 0 16px; flex-wrap: wrap; }
  nav.tabs button {
    display: inline-flex; align-items: center; gap: 7px;
    background: var(--panel); border: 1px solid var(--border-soft); color: var(--muted);
    padding: 10px 16px; border-radius: 999px; cursor: pointer; font-size: 13px; font-weight: 600;
    transition: all .15s ease;
  }
  nav.tabs button svg { width: 15px; height: 15px; opacity: .8; }
  nav.tabs button:hover { color: var(--text); border-color: var(--border); }
  nav.tabs button.active { background: var(--grad); border-color: transparent; color: #fff; }
  nav.tabs button.active svg { opacity: 1; }

  .panel { display: none; }
  .panel.active { display: block; animation: fadein .2s ease; }
  @keyframes fadein { from { opacity: 0; transform: translateY(4px);} to { opacity: 1; transform: translateY(0);} }

  .toolbar { display: flex; align-items: center; gap: 14px; margin-bottom: 16px; flex-wrap: wrap; }
  .scanbtn {
    background: var(--grad); color: #fff; border: none; padding: 11px 20px;
    border-radius: 10px; cursor: pointer; font-size: 13.5px; font-weight: 700;
    box-shadow: 0 6px 18px rgba(91,141,255,.3); transition: filter .15s ease, transform .15s ease;
  }
  .scanbtn:hover { filter: brightness(1.07); }
  .scanbtn:active { transform: scale(.98); }
  .scanbtn:disabled { opacity: .55; cursor: default; filter: none; }
  .hint { color: var(--muted2); font-size: 12.5px; }
  .status { color: var(--muted); font-size: 13px; margin-bottom: 10px; min-height: 18px; }

  .tablewrap {
    background: var(--panel); border: 1px solid var(--border-soft); border-radius: var(--radius);
    overflow: hidden; box-shadow: var(--shadow);
  }
  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: 13px 16px; border-bottom: 1px solid var(--border-soft); font-size: 13px; vertical-align: top; }
  th { color: var(--muted2); font-weight: 700; font-size: 11px; text-transform: uppercase; letter-spacing: .05em; background: var(--panel2); }
  tbody tr { transition: background .12s ease; }
  tbody tr:hover { background: var(--panel2); }
  tr:last-child td { border-bottom: none; }
  td.path { word-break: break-all; color: var(--text); font-weight: 600; }
  td.size { white-space: nowrap; font-weight: 700; color: var(--text); }
  .desc { color: var(--muted); font-size: 12px; margin-top: 3px; font-weight: 400; }
  .badge { display: inline-block; font-size: 10.5px; font-weight: 700; padding: 2px 9px; border-radius: 999px; margin-left: 7px; vertical-align: middle; }
  .badge.safe { background: var(--green-bg); color: var(--green); }
  .badge.caution { background: var(--yellow-bg); color: var(--yellow); }

  .removebtn {
    background: transparent; border: 1.5px solid var(--red); color: var(--red);
    padding: 7px 14px; border-radius: 8px; cursor: pointer; font-size: 12.5px; font-weight: 700; white-space: nowrap;
    transition: all .15s ease;
  }
  .removebtn:hover { background: var(--red-bg); }
  .removebtn:disabled { opacity: .5; cursor: default; }
  .removebtn.done { border-color: var(--muted2); color: var(--muted2); }
  .removebtn.uninstall { border-color: var(--accent); color: var(--accent); }
  .removebtn.uninstall:hover { background: rgba(91,141,255,.12); }

  .empty { color: var(--muted); padding: 40px 18px; text-align: center; font-size: 13px; }

  /* ---------- Footer ---------- */
  footer {
    margin-top: 46px; padding-top: 20px; border-top: 1px solid var(--border-soft);
    display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px;
    color: var(--muted2); font-size: 12.5px;
  }
  footer .flinks { display: flex; gap: 16px; }
  footer .flinks a { color: var(--muted); font-weight: 600; }

  /* ---------- Modal ---------- */
  .overlay {
    position: fixed; inset: 0; background: rgba(6,8,14,.65); backdrop-filter: blur(3px);
    display: none; align-items: center; justify-content: center; z-index: 100;
  }
  .overlay.show { display: flex; }
  .modal {
    width: 420px; max-width: 90vw; background: var(--panel2); border: 1px solid var(--border);
    border-radius: var(--radius); padding: 24px; box-shadow: 0 20px 60px rgba(0,0,0,.5);
    animation: popin .16s ease;
  }
  @keyframes popin { from { opacity: 0; transform: scale(.96); } to { opacity: 1; transform: scale(1); } }
  .modal h3 { margin: 0 0 10px; font-size: 16px; }
  .modal p { margin: 0 0 20px; font-size: 13.5px; color: var(--muted); line-height: 1.5; word-break: break-word; }
  .modal .mactions { display: flex; justify-content: flex-end; gap: 10px; }
  .modal button {
    padding: 9px 18px; border-radius: 9px; font-size: 13px; font-weight: 700; cursor: pointer; border: none;
  }
  .modal .cancel { background: var(--panel3); color: var(--text); }
  .modal .confirm { background: var(--red); color: #fff; }
  .modal .confirm.blue { background: var(--accent); }

  /* ---------- Toasts ---------- */
  .toasts { position: fixed; top: 20px; right: 20px; z-index: 200; display: flex; flex-direction: column; gap: 10px; }
  .toast {
    min-width: 260px; max-width: 360px; background: var(--panel2); border: 1px solid var(--border);
    border-left: 4px solid var(--accent); border-radius: 10px; padding: 12px 16px;
    box-shadow: 0 10px 30px rgba(0,0,0,.4); font-size: 13px; animation: slidein .18s ease;
  }
  .toast.success { border-left-color: var(--green); }
  .toast.error { border-left-color: var(--red); }
  @keyframes slidein { from { opacity: 0; transform: translateX(20px);} to { opacity: 1; transform: translateX(0);} }
</style>
</head>
<body>

<header class="top">
  <div class="brand">
    <div class="brand-badge">DW</div>
    <div class="brand-text">
      <h1>DriveWise</h1>
      <div class="ver">v1.0.0 &middot; by Aadesh Gulumbe</div>
    </div>
  </div>
  <div class="top-actions">
    <button class="pill-btn" id="feedbackBtn">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>
      Send Feedback
    </button>
    <a class="pill-btn" id="githubBtn" href="https://github.com/aadesh0706/DriveWise" target="_blank" rel="noopener">
      <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 .5C5.65.5.5 5.65.5 12c0 5.08 3.29 9.39 7.86 10.91.57.1.78-.25.78-.55 0-.27-.01-1.15-.02-2.09-3.2.7-3.88-1.36-3.88-1.36-.52-1.34-1.28-1.69-1.28-1.69-1.04-.72.08-.7.08-.7 1.16.08 1.77 1.19 1.77 1.19 1.03 1.77 2.7 1.26 3.36.96.1-.75.4-1.26.73-1.55-2.55-.29-5.24-1.28-5.24-5.68 0-1.26.45-2.28 1.19-3.08-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.18 1.18a11 11 0 0 1 5.8 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.24 2.76.12 3.05.74.8 1.18 1.82 1.18 3.08 0 4.41-2.69 5.38-5.25 5.67.41.36.78 1.06.78 2.15 0 1.55-.01 2.8-.01 3.18 0 .3.2.66.79.55A10.52 10.52 0 0 0 23.5 12C23.5 5.65 18.35.5 12 .5z"/></svg>
      GitHub
    </a>
  </div>
</header>

<main>
  <div class="section-label">Your Drives</div>
  <div class="drive-row" id="driveRow"><div class="hint">Loading drives...</div></div>

  <div class="overview">
    <div class="orow">
      <div class="otitle" id="activeTitle">Drive</div>
      <div class="ostats" id="activeStats">Loading...</div>
    </div>
    <div class="bar-track"><div class="bar-fill" id="barFill" style="width:0%"></div></div>
    <div class="freed" id="freedText">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><polyline points="20 6 9 17 4 12"/></svg>
      <span id="freedAmount"></span>
    </div>
  </div>

  <nav class="tabs">
    <button class="tabbtn active" data-tab="junk">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 6h18M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2m3 0-1 14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2L4 6"/></svg>
      Cache &amp; Junk
    </button>
    <button class="tabbtn" data-tab="folders">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>
      Big Folders
    </button>
    <button class="tabbtn" data-tab="files">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/></svg>
      Big Files
    </button>
    <button class="tabbtn" data-tab="programs">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/></svg>
      Programs
    </button>
  </nav>

  <section class="panel active" id="panel-junk">
    <div class="toolbar">
      <button class="scanbtn" id="scanJunkBtn">Scan for junk &amp; cache</button>
      <span class="hint">Always checks your system drive - usually finishes in a few seconds.</span>
    </div>
    <div class="status" id="junkStatus"></div>
    <div class="tablewrap" id="junkTableWrap"></div>
  </section>

  <section class="panel" id="panel-folders">
    <div class="toolbar">
      <button class="scanbtn" id="scanFoldersBtn">Scan for big folders</button>
      <span class="hint">Scans the selected drive. Can take a minute or two on large drives.</span>
    </div>
    <div class="status" id="foldersStatus"></div>
    <div class="tablewrap" id="foldersTableWrap"></div>
  </section>

  <section class="panel" id="panel-files">
    <div class="toolbar">
      <button class="scanbtn" id="scanFilesBtn">Scan for big files (&gt;200MB)</button>
      <span class="hint">Searches the selected drive for individual large files.</span>
    </div>
    <div class="status" id="filesStatus"></div>
    <div class="tablewrap" id="filesTableWrap"></div>
  </section>

  <section class="panel" id="panel-programs">
    <div class="toolbar">
      <button class="scanbtn" id="scanProgramsBtn">List installed programs</button>
      <span class="hint">Shows programs installed on the selected drive. Not all report a size.</span>
    </div>
    <div class="status" id="programsStatus"></div>
    <div class="tablewrap" id="programsTableWrap"></div>
  </section>

  <footer>
    <div>DriveWise v1.0.0 &middot; Built by <a href="https://github.com/aadesh0706" target="_blank" rel="noopener">Aadesh Gulumbe</a></div>
    <div class="flinks">
      <a href="https://github.com/aadesh0706/DriveWise" target="_blank" rel="noopener">GitHub</a>
      <a href="#" id="footerFeedback">Send Feedback</a>
    </div>
  </footer>
</main>

<div class="overlay" id="overlay">
  <div class="modal">
    <h3 id="modalTitle">Confirm</h3>
    <p id="modalText"></p>
    <div class="mactions">
      <button class="cancel" id="modalCancel">Cancel</button>
      <button class="confirm" id="modalConfirm">Confirm</button>
    </div>
  </div>
</div>

<div class="toasts" id="toasts"></div>

<script>
// ---- DriveWise feedback form ----
const FEEDBACK_FORM_URL = "https://docs.google.com/forms/d/e/1FAIpQLSf0f4vhJda0SYY0oVhfR5WXGgSLSDokjaew7zcxVhOAi1Te6Q/viewform?usp=header";

let drives = [];
let currentDrive = null;
let totalFreed = 0;

function escapeHtml(s) {
  if (s === null || s === undefined) return '';
  return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function setStatus(id, text) { document.getElementById(id).textContent = text; }

function toast(message, type) {
  const wrap = document.getElementById('toasts');
  const el = document.createElement('div');
  el.className = 'toast' + (type ? ' ' + type : '');
  el.textContent = message;
  wrap.appendChild(el);
  setTimeout(() => { el.style.transition = 'opacity .3s ease'; el.style.opacity = '0'; setTimeout(() => el.remove(), 300); }, 4200);
}

function confirmDialog(title, text, confirmLabel, danger) {
  return new Promise(resolve => {
    const overlay = document.getElementById('overlay');
    document.getElementById('modalTitle').textContent = title;
    document.getElementById('modalText').textContent = text;
    const confirmBtn = document.getElementById('modalConfirm');
    confirmBtn.textContent = confirmLabel || 'Confirm';
    confirmBtn.className = 'confirm' + (danger ? '' : ' blue');
    overlay.classList.add('show');
    function cleanup(result) {
      overlay.classList.remove('show');
      confirmBtn.removeEventListener('click', onConfirm);
      cancelBtn.removeEventListener('click', onCancel);
      resolve(result);
    }
    function onConfirm() { cleanup(true); }
    function onCancel() { cleanup(false); }
    const cancelBtn = document.getElementById('modalCancel');
    confirmBtn.addEventListener('click', onConfirm);
    cancelBtn.addEventListener('click', onCancel);
  });
}

document.getElementById('feedbackBtn').addEventListener('click', () => window.open(FEEDBACK_FORM_URL, '_blank'));
document.getElementById('footerFeedback').addEventListener('click', (e) => { e.preventDefault(); window.open(FEEDBACK_FORM_URL, '_blank'); });

function driveColor(pct) {
  return pct > 90 ? 'var(--red)' : (pct > 75 ? 'var(--yellow)' : 'var(--green)');
}

async function loadDrives(selectLetter) {
  try {
    const r = await fetch('/api/drives');
    const data = await r.json();
    drives = data.items || [];
    if (!drives.length) {
      document.getElementById('driveRow').innerHTML = '<div class="hint">No drives detected.</div>';
      return;
    }
    if (!currentDrive || !drives.some(d => d.drive === currentDrive)) {
      const sysDrive = drives.find(d => d.isSystem);
      currentDrive = (selectLetter && drives.some(d => d.drive === selectLetter)) ? selectLetter : (sysDrive ? sysDrive.drive : drives[0].drive);
    }
    renderDriveRow();
    renderOverview();
  } catch (e) {
    document.getElementById('driveRow').innerHTML = '<div class="hint">Could not load drives.</div>';
  }
}

function renderDriveRow() {
  const row = document.getElementById('driveRow');
  row.innerHTML = '';
  drives.forEach(d => {
    const card = document.createElement('div');
    card.className = 'drive-card' + (d.drive === currentDrive ? ' active' : '');
    card.innerHTML =
      '<div class="dtop"><div class="letter">' + escapeHtml(d.drive) + '</div><div class="type-badge">' + escapeHtml(d.type) + (d.isSystem ? ' &middot; OS' : '') + '</div></div>' +
      '<div class="label">' + escapeHtml(d.label) + '</div>' +
      '<div class="mini-track"><div class="mini-fill" style="width:' + d.percentUsed + '%; background:' + driveColor(d.percentUsed) + '"></div></div>' +
      '<div class="dstat">' + d.percentUsed + '% full &middot; ' + escapeHtml(d.freeReadable) + ' free</div>';
    card.addEventListener('click', () => {
      currentDrive = d.drive;
      renderDriveRow();
      renderOverview();
      clearTables();
    });
    row.appendChild(card);
  });
}

function renderOverview() {
  const d = drives.find(x => x.drive === currentDrive);
  if (!d) return;
  document.getElementById('activeTitle').textContent = d.drive + ' ' + (d.isSystem ? '(System Drive)' : '(' + d.type + ' Drive)');
  document.getElementById('activeStats').textContent =
    d.usedReadable + ' used of ' + d.totalReadable + ' (' + d.freeReadable + ' free) - ' + d.percentUsed + '% full';
  const fill = document.getElementById('barFill');
  fill.style.width = d.percentUsed + '%';
  fill.style.background = driveColor(d.percentUsed);
}

function clearTables() {
  ['foldersTableWrap', 'filesTableWrap', 'programsTableWrap'].forEach(id => document.getElementById(id).innerHTML = '');
  ['foldersStatus', 'filesStatus', 'programsStatus'].forEach(id => setStatus(id, ''));
}

function updateFreed(bytes) {
  totalFreed += bytes;
  const mb = totalFreed / (1024*1024);
  const text = mb > 1024 ? (mb/1024).toFixed(2) + ' GB' : mb.toFixed(1) + ' MB';
  const el = document.getElementById('freedText');
  if (totalFreed > 0) {
    document.getElementById('freedAmount').textContent = 'Freed ' + text + ' this session';
    el.classList.add('show');
  }
}

function switchTab(tab) {
  document.querySelectorAll('.tabbtn').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
  document.querySelectorAll('.panel').forEach(p => p.classList.toggle('active', p.id === 'panel-' + tab));
}
document.querySelectorAll('.tabbtn').forEach(b => b.addEventListener('click', () => switchTab(b.dataset.tab)));

async function removeRow(kind, path, sizeBytes, btn, rowEl, title, text, confirmLabel, danger) {
  const ok = await confirmDialog(title, text, confirmLabel, danger);
  if (!ok) return;
  btn.disabled = true;
  btn.textContent = 'Removing...';
  try {
    const r = await fetch('/api/delete', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ kind: kind, path: path })
    });
    const res = await r.json();
    if (res.success) {
      btn.textContent = 'Removed';
      btn.classList.add('done');
      rowEl.style.opacity = '0.45';
      updateFreed(sizeBytes);
      toast('Removed successfully.', 'success');
      loadDrives(currentDrive);
    } else {
      toast('Could not remove: ' + (res.error || 'unknown error'), 'error');
      btn.disabled = false;
      btn.textContent = 'Remove';
    }
  } catch (e) {
    toast('Request failed: ' + e, 'error');
    btn.disabled = false;
    btn.textContent = 'Remove';
  }
}

function buildTable(wrapId, headers, rows) {
  const wrap = document.getElementById(wrapId);
  if (!rows.length) {
    wrap.innerHTML = '<div class="empty">Nothing found here.</div>';
    return null;
  }
  const table = document.createElement('table');
  const thead = document.createElement('thead');
  thead.innerHTML = '<tr>' + headers.map(h => '<th>' + h + '</th>').join('') + '<th></th></tr>';
  table.appendChild(thead);
  const tbody = document.createElement('tbody');
  table.appendChild(tbody);
  wrap.innerHTML = '';
  wrap.appendChild(table);
  return tbody;
}

// ---- Junk & cache ----
document.getElementById('scanJunkBtn').addEventListener('click', async () => {
  const btn = document.getElementById('scanJunkBtn');
  btn.disabled = true;
  setStatus('junkStatus', 'Scanning...');
  try {
    const r = await fetch('/api/scan');
    const data = await r.json();
    setStatus('junkStatus', data.items.length + ' item(s) found.');
    const tbody = buildTable('junkTableWrap', ['Item', 'Size'], data.items);
    if (tbody) {
      data.items.forEach(item => {
        const tr = document.createElement('tr');
        const badge = item.safe ? '<span class="badge safe">Safe</span>' : '<span class="badge caution">Review first</span>';
        tr.innerHTML =
          '<td class="path">' + escapeHtml(item.name) + badge +
            '<div class="desc">' + escapeHtml(item.description) + ' &mdash; ' + escapeHtml(item.path) + '</div></td>' +
          '<td class="size">' + escapeHtml(item.sizeReadable) + '</td>' +
          '<td></td>';
        const td = tr.lastElementChild;
        const btn2 = document.createElement('button');
        btn2.className = 'removebtn';
        btn2.textContent = 'Remove';
        btn2.addEventListener('click', () => removeRow('junk', item.path, item.sizeBytes, btn2, tr,
          'Delete "' + item.name + '"?', 'This permanently deletes ' + item.sizeReadable + ' from:\n' + item.path, 'Delete', true));
        td.appendChild(btn2);
        tbody.appendChild(tr);
      });
    }
  } catch (e) {
    setStatus('junkStatus', 'Scan failed: ' + e);
  }
  btn.disabled = false;
});

// ---- Big folders ----
document.getElementById('scanFoldersBtn').addEventListener('click', async () => {
  const btn = document.getElementById('scanFoldersBtn');
  btn.disabled = true;
  setStatus('foldersStatus', 'Scanning ' + currentDrive + ' ... this can take a minute or two on large drives.');
  try {
    const r = await fetch('/api/folders?drive=' + encodeURIComponent(currentDrive));
    const data = await r.json();
    setStatus('foldersStatus', data.items.length + ' folder(s) over 100MB found on ' + currentDrive);
    const tbody = buildTable('foldersTableWrap', ['Folder', 'Size'], data.items);
    if (tbody) {
      data.items.forEach(item => {
        const tr = document.createElement('tr');
        tr.innerHTML =
          '<td class="path">' + escapeHtml(item.path) + '<div class="desc">Sent to Recycle Bin if removed</div></td>' +
          '<td class="size">' + escapeHtml(item.sizeReadable) + '</td>' +
          '<td></td>';
        const td = tr.lastElementChild;
        const btn2 = document.createElement('button');
        btn2.className = 'removebtn';
        btn2.textContent = 'Remove';
        btn2.addEventListener('click', () => removeRow('folder', item.path, item.sizeBytes, btn2, tr,
          'Move folder to Recycle Bin?', 'This moves ' + item.sizeReadable + ' to the Recycle Bin:\n' + item.path, 'Move to Recycle Bin', true));
        td.appendChild(btn2);
        tbody.appendChild(tr);
      });
    }
  } catch (e) {
    setStatus('foldersStatus', 'Scan failed: ' + e);
  }
  btn.disabled = false;
});

// ---- Big files ----
document.getElementById('scanFilesBtn').addEventListener('click', async () => {
  const btn = document.getElementById('scanFilesBtn');
  btn.disabled = true;
  setStatus('filesStatus', 'Scanning ' + currentDrive + ' ...');
  try {
    const r = await fetch('/api/largefiles?drive=' + encodeURIComponent(currentDrive));
    const data = await r.json();
    setStatus('filesStatus', data.items.length + ' file(s) over 200MB found on ' + currentDrive);
    const tbody = buildTable('filesTableWrap', ['File', 'Size', 'Modified'], data.items);
    if (tbody) {
      data.items.forEach(item => {
        const tr = document.createElement('tr');
        tr.innerHTML =
          '<td class="path">' + escapeHtml(item.path) + '<div class="desc">Sent to Recycle Bin if removed</div></td>' +
          '<td class="size">' + escapeHtml(item.sizeReadable) + '</td>' +
          '<td>' + escapeHtml(item.modified) + '</td>' +
          '<td></td>';
        const td = tr.lastElementChild;
        const btn2 = document.createElement('button');
        btn2.className = 'removebtn';
        btn2.textContent = 'Remove';
        btn2.addEventListener('click', () => removeRow('file', item.path, item.sizeBytes, btn2, tr,
          'Move file to Recycle Bin?', 'This moves ' + item.sizeReadable + ' to the Recycle Bin:\n' + item.path, 'Move to Recycle Bin', true));
        td.appendChild(btn2);
        tbody.appendChild(tr);
      });
    }
  } catch (e) {
    setStatus('filesStatus', 'Scan failed: ' + e);
  }
  btn.disabled = false;
});

// ---- Installed programs ----
document.getElementById('scanProgramsBtn').addEventListener('click', async () => {
  const btn = document.getElementById('scanProgramsBtn');
  btn.disabled = true;
  setStatus('programsStatus', 'Loading...');
  try {
    const r = await fetch('/api/programs?drive=' + encodeURIComponent(currentDrive));
    const data = await r.json();
    setStatus('programsStatus', data.items.length + ' program(s) found on ' + currentDrive);
    const tbody = buildTable('programsTableWrap', ['Program', 'Publisher', 'Size'], data.items);
    if (tbody) {
      data.items.forEach(item => {
        const tr = document.createElement('tr');
        tr.innerHTML =
          '<td class="path">' + escapeHtml(item.name) + '<div class="desc">Launches the program\'s own uninstaller</div></td>' +
          '<td>' + escapeHtml(item.publisher || '') + '</td>' +
          '<td class="size">' + escapeHtml(item.sizeReadable) + '</td>' +
          '<td></td>';
        const td = tr.lastElementChild;
        const btn2 = document.createElement('button');
        btn2.className = 'removebtn uninstall';
        btn2.textContent = 'Uninstall';
        btn2.addEventListener('click', async () => {
          const ok = await confirmDialog('Uninstall program?', 'This launches the official uninstaller for "' + item.name + '".', 'Uninstall', false);
          if (!ok) return;
          btn2.disabled = true;
          btn2.textContent = 'Launching...';
          try {
            const rr = await fetch('/api/uninstall', {
              method: 'POST',
              headers: {'Content-Type': 'application/json'},
              body: JSON.stringify({ name: item.name })
            });
            const res = await rr.json();
            if (res.success) {
              btn2.textContent = 'Uninstaller opened';
              btn2.classList.add('done');
              toast('Uninstaller launched for ' + item.name, 'success');
            } else {
              toast('Could not launch uninstaller: ' + (res.error || 'unknown error'), 'error');
              btn2.disabled = false;
              btn2.textContent = 'Uninstall';
            }
          } catch (e) {
            toast('Request failed: ' + e, 'error');
            btn2.disabled = false;
            btn2.textContent = 'Uninstall';
          }
        });
        td.appendChild(btn2);
        tbody.appendChild(tr);
      });
    }
  } catch (e) {
    setStatus('programsStatus', 'Load failed: ' + e);
  }
  btn.disabled = false;
});

loadDrives();
</script>
</body>
</html>
'@

# ---------------------------------------------------------------------------
# HTTP plumbing
# ---------------------------------------------------------------------------

function Send-Json {
    param($Response, $Object, [int]$StatusCode = 200)
    $json = $Object | ConvertTo-Json -Depth 6 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json; charset=utf-8"
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Send-Html {
    param($Response, [string]$Html, [int]$StatusCode = 200)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "text/html; charset=utf-8"
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Read-JsonBody {
    param($Request)
    $reader = New-Object System.IO.StreamReader($Request.InputStream, [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $reader.Close()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

$listener = $null
$boundPort = $Port
$started = $false
for ($i = 0; $i -lt 15; $i++) {
    try {
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://localhost:$boundPort/")
        $listener.Start()
        $started = $true
        break
    } catch {
        $boundPort++
    }
}

if (-not $started) {
    Write-Host "Could not start the local server - no free port found." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  DriveWise v$AppVersion is running." -ForegroundColor Green
Write-Host "  Opening: http://localhost:$boundPort/" -ForegroundColor Cyan
if (-not $isAdmin) {
    Write-Host "  Tip: re-run as Administrator for the most complete scan results." -ForegroundColor Yellow
}
Write-Host "  Keep this window open while using the tool. Press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host ""

Start-Process "http://localhost:$boundPort/"

try {
    while ($listener.IsListening) {
        $context  = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response
        try {
            $path   = $request.Url.AbsolutePath
            $method = $request.HttpMethod

            if ($path -eq '/' -and $method -eq 'GET') {
                Send-Html -Response $response -Html $indexHtml
            }
            elseif ($path -eq '/api/drives' -and $method -eq 'GET') {
                Send-Json -Response $response -Object @{ items = @(Get-AllDrives) }
            }
            elseif ($path -eq '/api/scan' -and $method -eq 'GET') {
                Send-Json -Response $response -Object @{ items = @(Get-JunkCandidates) }
            }
            elseif ($path -eq '/api/folders' -and $method -eq 'GET') {
                $d = Get-QueryParam -Request $request -Name 'drive' -Default $SystemDrive
                Send-Json -Response $response -Object @{ items = @(Get-BigFolders -DriveLetter $d) }
            }
            elseif ($path -eq '/api/largefiles' -and $method -eq 'GET') {
                $d = Get-QueryParam -Request $request -Name 'drive' -Default $SystemDrive
                Send-Json -Response $response -Object @{ items = @(Get-BigFiles -DriveLetter $d) }
            }
            elseif ($path -eq '/api/programs' -and $method -eq 'GET') {
                $d = Get-QueryParam -Request $request -Name 'drive' -Default $SystemDrive
                Send-Json -Response $response -Object @{ items = @(Get-InstalledPrograms -DriveLetter $d) }
            }
            elseif ($path -eq '/api/delete' -and $method -eq 'POST') {
                $body = Read-JsonBody -Request $request
                try {
                    Invoke-DeletePath -Path $body.path -Kind $body.kind
                    Send-Json -Response $response -Object @{ success = $true }
                } catch {
                    Send-Json -Response $response -Object @{ success = $false; error = $_.Exception.Message } -StatusCode 400
                }
            }
            elseif ($path -eq '/api/uninstall' -and $method -eq 'POST') {
                $body = Read-JsonBody -Request $request
                try {
                    Invoke-Uninstall -Name $body.name
                    Send-Json -Response $response -Object @{ success = $true }
                } catch {
                    Send-Json -Response $response -Object @{ success = $false; error = $_.Exception.Message } -StatusCode 400
                }
            }
            else {
                Send-Html -Response $response -Html "<h1>404 Not Found</h1>" -StatusCode 404
            }
        } catch {
            try {
                Send-Json -Response $response -Object @{ error = $_.Exception.Message } -StatusCode 500
            } catch {}
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
