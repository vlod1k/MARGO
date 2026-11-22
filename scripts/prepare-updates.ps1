param(
    [string]$WindowsInstaller,
    [string]$AndroidApk,
    [string]$OutputDirectory,
    [string]$Notes = '',
    [Parameter(Mandatory)][string]$PreviousAndroidApk,
    [switch]$AllowLegacyDebugCertificate
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$pubspec = Get-Content -LiteralPath (Join-Path $root 'apps/margo_flutter/pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') { throw 'Invalid pubspec version.' }
$versionName = $Matches[1]
$buildNumber = [int]$Matches[2]
if (-not $WindowsInstaller) { $WindowsInstaller = Join-Path $root "dist/MARGO-Setup-$versionName.exe" }
if (-not $AndroidApk) { $AndroidApk = Join-Path $root 'dist/MARGO-Android.apk' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'backend/releases' }
if (-not $env:MARGO_ANDROID_CERT_SHA256) { throw 'Pin MARGO_ANDROID_CERT_SHA256 before preparing public updates.' }
& (Join-Path $PSScriptRoot 'verify-windows-release.ps1') -FilePath $WindowsInstaller
& (Join-Path $PSScriptRoot 'verify-android-release.ps1') -Apk $AndroidApk -PreviousApk $PreviousAndroidApk -AllowLegacyDebugCertificate:$AllowLegacyDebugCertificate
& (Join-Path $PSScriptRoot 'verify-android-account-access.ps1') -Apk $AndroidApk

# Read versions from the actual deliverables to reject stale dist files.
$windowsInfo = (Get-Item -LiteralPath $WindowsInstaller).VersionInfo
if ("$($windowsInfo.FileMajorPart).$($windowsInfo.FileMinorPart).$($windowsInfo.FileBuildPart)" -ne $versionName -or $windowsInfo.FilePrivatePart -ne $buildNumber) {
    throw 'Windows installer version differs from pubspec. Rebuild the Windows client and installer.'
}
$sdkRoot = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $root '.tools/android-sdk' }
$aapt = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'build-tools') -Directory |
    Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'aapt.exe' } |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $aapt) { throw 'Android SDK aapt.exe is required to verify the APK version.' }
$badging = (& $aapt dump badging $AndroidApk) -join "`n"
if ($LASTEXITCODE -ne 0 -or $badging -notmatch "package: name='dev.thoth.thoth' versionCode='(\d+)' versionName='([^']+)'") {
    throw 'Unable to verify MARGO APK metadata.'
}
if ([int]$Matches[1] -ne $buildNumber -or $Matches[2] -ne $versionName) { throw 'APK version differs from pubspec. Rebuild Android.' }

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$manifestPath = Join-Path $OutputDirectory 'latest.json'
$lockPath = Join-Path $OutputDirectory '.publish.lock'
$publishLock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try {
    if (Test-Path -LiteralPath $manifestPath) {
        $previous = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        foreach ($platform in @('windows', 'android')) {
            if ($previous.$platform -and [int]$previous.$platform.build -ge $buildNumber) {
                throw 'Increase the pubspec build number before preparing a new release.'
            }
        }
    }
    $manifest = [ordered]@{}
    foreach ($entry in @(
        @{ Platform = 'windows'; Source = $WindowsInstaller; Extension = 'exe' },
        @{ Platform = 'android'; Source = $AndroidApk; Extension = 'apk' }
    )) {
        $source = Get-Item -LiteralPath $entry.Source
        if ($source.Length -le 0 -or $source.Length -gt 512MB) { throw 'Unsupported update size.' }
        $hash = (Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $name = "MARGO-$($entry.Platform)-$versionName-$buildNumber-$hash.$($entry.Extension)"
        Copy-Item -LiteralPath $source.FullName -Destination (Join-Path $OutputDirectory $name) -Force
        $manifest[$entry.Platform] = [ordered]@{
            version = $versionName; build = $buildNumber; url = $name
            sha256 = $hash; size = $source.Length; notes = $Notes
        }
    }
    $temporaryManifest = Join-Path $OutputDirectory 'latest.json.tmp'
    [System.IO.File]::WriteAllText($temporaryManifest, ($manifest | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $manifestPath) {
        $previousManifestPath = Join-Path $OutputDirectory 'latest.previous.json'
        [System.IO.File]::Replace($temporaryManifest, $manifestPath, $previousManifestPath)
    } else {
        [System.IO.File]::Move($temporaryManifest, $manifestPath)
    }
} finally {
    $publishLock.Dispose()
    Remove-Item -LiteralPath $lockPath -Force
}
Write-Host "Prepared $versionName+$buildNumber in $OutputDirectory. Upload the packages first, then latest.json to the HTTPS server's releases directory."
