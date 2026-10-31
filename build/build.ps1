#Requires -Version 7.0
# (Windows PowerShell 5.1's ConvertTo-Json mangles arrays in the manifests: use PowerShell 7.)
<#
.SYNOPSIS
  Builds Puddock: puddock.exe, extension packages (Chromium + Firefox), installer, SHA256SUMS.

.EXAMPLE
  .\build\build.ps1 -Ahk2Exe "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" `
                    -AhkBase "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

.PARAMETER SignScript
  Optional PowerShell script taking -Path <file> that Authenticode-signs that file in place.
  puddock.exe is signed BEFORE it is packed into the installer; the installer and its
  uninstaller are signed through Inno Setup with the same script.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Ahk2Exe,     # Ahk2Exe.exe
    [Parameter(Mandatory)] [string] $AhkBase,     # AutoHotkey64.exe (v2) used as the exe base
    [string] $Iscc = "",                          # ISCC.exe; auto-detected if empty
    [string] $SignScript = "",                    # see .PARAMETER SignScript
    [switch] $SkipInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$GeckoId          = 'puddock@puddock.app'
$GeckoMinVersion  = '140.0'   # data_collection_permissions needs 140 (ESR)

# Exactly what may ship in the extension packages: anything else in extension/ (keys, notes,
# editor backups…) fails the build instead of being published.
$ExtensionFiles = @(
    'manifest.json', 'background.js', 'channel.js', 'chat.js', 'connect.js', 'content.js', 'content.css',
    'options.html', 'options.css', 'options.js',
    'icons/16.png', 'icons/32.png', 'icons/48.png', 'icons/128.png'
)

$root    = Split-Path $PSScriptRoot -Parent
$dist    = Join-Path $root 'dist'
$extSrc  = Join-Path $root 'extension'
$utf8    = New-Object System.Text.UTF8Encoding $false
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function Write-Json($obj, $path) {
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 32), $utf8)
}

# Zip with forward-slash entry names (Compress-Archive on Windows PowerShell 5.1 can write
# backslashes, which AMO and some stores reject).
function New-Zip($sourceDir, $zipPath) {
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
    try {
        # Enumerate from the very string we cut off, so the prefix always matches (with a short 8.3
        # %TEMP% like C:\Users\ABCDEF~1, Resolve-Path and FullName can disagree on its length).
        $base = (Get-Item -LiteralPath $sourceDir).FullName.TrimEnd('\') + '\'
        Get-ChildItem -LiteralPath $base -Recurse -File | ForEach-Object {
            if (-not $_.FullName.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw "Unexpected path: $($_.FullName)" }
            $entry = $_.FullName.Substring($base.Length).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $entry, 'Optimal') | Out-Null
        }
    } finally { $zip.Dispose() }
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try { if (-not $zip.GetEntry('manifest.json')) { throw "$zipPath has no manifest.json at its root" } }
    finally { $zip.Dispose() }
}

function Copy-Extension($dest) {
    $base = (Resolve-Path $extSrc).Path.TrimEnd('\') + '\'
    $present = Get-ChildItem $extSrc -Recurse -File -Force |
               ForEach-Object { $_.FullName.Substring($base.Length).Replace('\', '/') }
    $unexpected = $present | Where-Object { $_ -notin $ExtensionFiles }
    if ($unexpected) { throw "Unexpected files in extension/ (add them to `$ExtensionFiles or remove them): $($unexpected -join ', ')" }
    $missing = $ExtensionFiles | Where-Object { $_ -notin $present }
    if ($missing) { throw "Missing extension files: $($missing -join ', ')" }

    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    foreach ($f in $ExtensionFiles) {
        $target = Join-Path $dest $f
        New-Item (Split-Path $target -Parent) -ItemType Directory -Force | Out-Null
        Copy-Item (Join-Path $extSrc $f) $target
    }
    return (Get-Content (Join-Path $dest 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Invoke-Sign($path) {
    if (-not $SignScript) { return }
    & $SignScript -Path $path
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "Signing failed for $path" }
    $sig = Get-AuthenticodeSignature $path
    if ($sig.Status -ne 'Valid') { throw "Signature of $path is $($sig.Status) after signing" }
}

# ---------- version: single source of truth ----------
$version = (Get-Content (Join-Path $PSScriptRoot 'version.txt') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "build/version.txt must contain X.Y.Z, got '$version'" }
$manifest = Get-Content (Join-Path $extSrc 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.version -ne $version) {
    throw "Version mismatch: build/version.txt=$version, extension/manifest.json=$($manifest.version)"
}
Write-Host "Building Puddock $version"

foreach ($p in @($Ahk2Exe, $AhkBase)) { if (-not (Test-Path $p -PathType Leaf)) { throw "Not found: $p" } }
if ($SignScript -and -not (Test-Path $SignScript -PathType Leaf)) { throw "Not found: $SignScript" }

if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item $dist -ItemType Directory | Out-Null

# ---------- app ----------
$exe = Join-Path $dist 'puddock.exe'
# Start-Process does not quote array elements on Windows PowerShell: build the quoted line ourselves.
$ahkArgs = '/in "{0}" /out "{1}" /base "{2}" /silent verbose' -f (Join-Path $root 'app\puddock.ahk'), $exe, $AhkBase
$proc = Start-Process -FilePath $Ahk2Exe -ArgumentList $ahkArgs -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0 -or -not (Test-Path $exe)) { throw "Ahk2Exe failed (exit code $($proc.ExitCode))" }
Invoke-Sign $exe                                  # before it gets packed into the installer
Write-Host "  app        -> $exe$(if ($SignScript) { ' (signed)' })"

# ---------- extension ----------
# Puddock is distributed through GitHub only: users load the extension unpacked ("Load unpacked"),
# and the "key" in manifest.json gives it the fixed ID the app trusts. Keep the key in every
# Chromium copy. (A store upload would need it removed - the store assigns its own ID.)
$null = Copy-Extension (Join-Path $dist 'extension')            # shipped by the installer
Write-Host "  extension  -> dist\extension (unpacked)"

$chromiumZip = Join-Path $dist "puddock-chromium-$version.zip"   # same files, for users without the installer
New-Zip (Join-Path $dist 'extension') $chromiumZip
Write-Host "  chromium   -> $chromiumZip"

# Firefox package: background scripts instead of a service worker, gecko id.
$stage = Join-Path $env:TEMP "puddock-build-firefox"
$m = Copy-Extension $stage
$m.PSObject.Properties.Remove('key')
$m.background = [pscustomobject]@{ scripts = @('channel.js', 'background.js') }
# AMO requires new add-ons to declare data collection; Puddock collects nothing (the token only
# goes to the user's own local app). VERIFY against AMO's current schema (web-ext lint) before upload.
$gecko = [pscustomobject]@{ gecko = [pscustomobject]@{
    id = $GeckoId; strict_min_version = $GeckoMinVersion
    data_collection_permissions = [pscustomobject]@{ required = @('none') } } }
$m | Add-Member -NotePropertyName browser_specific_settings -NotePropertyValue $gecko -Force
Write-Json $m (Join-Path $stage 'manifest.json')
$firefoxZip = Join-Path $dist "puddock-firefox-$version.zip"
New-Zip $stage $firefoxZip
Remove-Item $stage -Recurse -Force
Write-Host "  firefox    -> $firefoxZip"

# ---------- installer ----------
if (-not $SkipInstaller) {
    if (-not $Iscc) {
        $Iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") |
                Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if ($Iscc) {
        $isccArgs = @("/DAppVersion=$version", "/DDistDir=$dist", "/O$dist")
        if ($SignScript) {
            $isccArgs += '/DSignInstaller=1'
            $isccArgs += "/Spuddock=pwsh -NoProfile -File `$q$SignScript`$q -Path `$f"
        }
        & $Iscc @isccArgs (Join-Path $root 'installer\puddock.iss')
        if ($LASTEXITCODE -ne 0) { throw "ISCC failed (exit code $LASTEXITCODE)" }
        if ($SignScript) { Invoke-Sign (Join-Path $dist "Puddock-Setup-$version.exe") }   # verifies it
        Write-Host "  installer  -> dist\Puddock-Setup-$version.exe"
    } else {
        Write-Warning "Inno Setup (ISCC.exe) not found - installer skipped. Use -Iscc or -SkipInstaller."
    }
}

# ---------- checksums ----------
$sums = Get-ChildItem $dist -File | Where-Object { $_.Extension -in '.exe', '.zip' } | Sort-Object Name |
        ForEach-Object { '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name }
[IO.File]::WriteAllLines((Join-Path $dist 'SHA256SUMS.txt'), [string[]]$sums, $utf8)
Write-Host "  checksums  -> dist\SHA256SUMS.txt"
$sums | ForEach-Object { Write-Host "    $_" }
