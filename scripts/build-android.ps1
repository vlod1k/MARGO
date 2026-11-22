param(
    [ValidateSet('release', 'debug')][string]$Mode = 'release',
    [string]$PreviousApk,
    [switch]$AllowLegacyDebugCertificate
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($PreviousApk) { $PreviousApk = (Resolve-Path -LiteralPath $PreviousApk).Path }
$sdk = Join-Path $root '.tools/flutter/bin/flutter.bat'
if (-not (Test-Path -LiteralPath $sdk)) { $sdk = 'flutter' }
$previousJavaHome = $env:JAVA_HOME
$previousAndroidHome = $env:ANDROID_HOME
$previousGradleHome = $env:GRADLE_USER_HOME
$env:GRADLE_USER_HOME = Join-Path $root '.tools/gradle'
$localJava = Join-Path $root '.tools/java'
$localAndroid = Join-Path $root '.tools/android-sdk'
if (Test-Path -LiteralPath $localJava) {
    $jdk = Get-ChildItem -LiteralPath $localJava -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'bin/java.exe')
    } | Select-Object -First 1
    if ($jdk) { $env:JAVA_HOME = $jdk.FullName }
}
if (Test-Path -LiteralPath $localAndroid) { $env:ANDROID_HOME = $localAndroid }
Push-Location -LiteralPath (Join-Path $root 'apps/margo_flutter')
try {
    # Rebuild every ABI from source; stale ARM snapshots previously shipped as 0.4.4.
    if ($Mode -eq 'release') {
        & $sdk clean
        if ($LASTEXITCODE -ne 0) { throw 'flutter clean failed' }
    }
    & $sdk pub get
    if ($LASTEXITCODE -ne 0) { throw 'pub get failed' }
    $endpointArgs = @()
    foreach ($name in 'API_BASE_URL', 'UPDATE_MANIFEST_URL') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $endpointArgs += "--dart-define=$name=$value" }
    }
    & $sdk build apk "--$Mode" --no-pub @endpointArgs
    if ($LASTEXITCODE -ne 0) { throw 'APK build failed. Check Android SDK and accepted licenses.' }
    if ($Mode -eq 'release') {
        & (Join-Path $PSScriptRoot 'verify-android-release.ps1') -Apk "build/app/outputs/flutter-apk/app-release.apk" -PreviousApk $PreviousApk -AllowLegacyDebugCertificate:$AllowLegacyDebugCertificate
        & (Join-Path $PSScriptRoot 'verify-android-account-access.ps1') -Apk "build/app/outputs/flutter-apk/app-release.apk"
    }
    $out = Join-Path $root 'dist'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    $fileName = if ($Mode -eq 'release') { 'MARGO-Android.apk' } else { 'MARGO-Android-debug.apk' }
    Copy-Item -LiteralPath "build/app/outputs/flutter-apk/app-$Mode.apk" -Destination (Join-Path $out $fileName)
    Write-Host "APK: $(Join-Path $out $fileName)"
    if ($Mode -eq 'debug') { Write-Host 'Development APK; do not publish as a release.' }
} finally {
    Pop-Location
    $env:JAVA_HOME = $previousJavaHome
    $env:ANDROID_HOME = $previousAndroidHome
    $env:GRADLE_USER_HOME = $previousGradleHome
}
