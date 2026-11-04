# SPDX-License-Identifier: GPL-2.0-or-later OR LGPL-2.1-or-later
# Collects your Altium Designer user data from a Windows PC into a zip that setup.sh can import
# (menu: Import user data, or --user-data): the preferences (registry), editor defaults, menus and
# shortcuts, user tools, color schemes, the last workspace and dictionaries. Program files, caches,
# logs, recovery backups and the license (file and activation key) are left out.
#
# Run in PowerShell:
#   powershell -ExecutionPolicy Bypass -File export-windows.ps1 [-OutDir C:\path]
#
# Writes altium<major version>-user-data_<date-time>.zip for each installed version (the full version instead if
# two installs share a major version) to -OutDir (default: the current folder).
#
# Read-only on the system; writes only to a temp folder and the output zips.

param(
    [string]$OutDir = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

$builds = @()
if (Test-Path 'HKLM:\SOFTWARE\Altium\Builds') {
    $builds = @(Get-ChildItem 'HKLM:\SOFTWARE\Altium\Builds' |
        Where-Object { (Get-ItemProperty $_.PSPath).Version })
}
if ($builds.Count -eq 0) { throw "No Altium builds found." }
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$majors = $builds | ForEach-Object { (Get-ItemProperty $_.PSPath).Version.Split('.')[0] }

foreach ($build in $builds) {
    $buildKey = $build.PSChildName                   # "Altium Designer {GUID}"
    $version = (Get-ItemProperty $build.PSPath).Version
    $major = $version.Split('.')[0]
    $name = if (@($majors | Where-Object { $_ -eq $major }).Count -gt 1) { $version } else { $major }
    $outFile = Join-Path $OutDir "altium$name-user-data_$ts.zip"
    Write-Host "Exporting user data of $buildKey, version $version"

    $out = Join-Path $env:TEMP 'altium-user-data'
    Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory $out | Out-Null

    # Preferences: setup.sh keeps only this build's keys and renames them to the new install's GUID.
    reg export "HKCU\SOFTWARE\Altium\$buildKey" "$out\hkcu.reg" /y | Out-Null
    # without NetworkLicenseUsage (the activation key)
    $keep = $true
    $lines = foreach ($line in Get-Content "$out\hkcu.reg" -Encoding Unicode) {
        if ($line.StartsWith('[')) { $keep = $line -notlike '*\NetworkLicenseUsage*' }
        if ($keep) { $line }
    }
    Set-Content "$out\hkcu.reg" $lines -Encoding Unicode

    # settings: from AppData\Roaming\Altium\<build>, only what you made or changed
    $settings = Join-Path $env:APPDATA "Altium\$buildKey"
    New-Item -ItemType Directory "$out\settings" | Out-Null
    if (Test-Path $settings) {
        Get-ChildItem $settings | Where-Object {
            $_.Name -match '\.(dft|mmsdft|mbsdft|pcbdwf)$' -or
            $_.Name -in 'DXP.RAF', 'UserTools.TLT', 'ViewConfigurations', 'LastWorkspace'
        } | Copy-Item -Destination "$out\settings\" -Recurse
    }

    # user data such as dictionaries
    New-Item -ItemType Directory "$out\userdata" | Out-Null
    $src = Join-Path $env:ProgramData "Altium\$buildKey\UserData"
    if (Test-Path $src) { Copy-Item "$src\*" "$out\userdata\" -Recurse }

    @(
        "build_key=$buildKey"
        "version=$version"
    ) | Set-Content "$out\build.txt" -Encoding ASCII

    Remove-Item $outFile -ErrorAction SilentlyContinue
    Compress-Archive -Path "$out\*" -DestinationPath $outFile
    Remove-Item $out -Recurse -Force
    Write-Host "Wrote $outFile"
}
