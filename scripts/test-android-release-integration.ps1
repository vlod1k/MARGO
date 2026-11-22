$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $root '.tools/android-sdk' }
$tools = Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'lib/apksigner.jar') } |
    Sort-Object { [version]($_.Name -replace '-.*$', '') } -Descending | Select-Object -First 1
$platform = Get-ChildItem -LiteralPath (Join-Path $sdk 'platforms') -Directory |
    Where-Object { $_.Name -match '^android-\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'android.jar')) } |
    Sort-Object { [int]($_.Name -replace '^android-', '') } -Descending | Select-Object -First 1
if (-not $tools -or -not $platform) { throw 'Android SDK build-tools and a platform are required.' }
$suffix = if ($IsWindows) { '.exe' } else { '' }
$javaHome = $env:JAVA_HOME
if (-not $javaHome) {
    $javaHome = Get-ChildItem -LiteralPath (Join-Path $root '.tools/java') -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "bin/java$suffix") } |
        Select-Object -First 1 -ExpandProperty FullName
}
$java = Join-Path $javaHome "bin/java$suffix"
$keytool = Join-Path $javaHome "bin/keytool$suffix"
$aapt = Join-Path $tools.FullName "aapt$suffix"
$jar = Join-Path $tools.FullName 'lib/apksigner.jar'
$androidJar = Join-Path $platform.FullName 'android.jar'
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { Join-Path $root '.tools' }
$work = Join-Path $tempRoot ('margo-apk-verifier-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work
function Invoke-RequiredNative([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Native test command failed: $Executable (exit $LASTEXITCODE)" }
}
$keystore = Join-Path $work 'ci-only.jks'
$certificate = Join-Path $work 'ci-only.der'
Invoke-RequiredNative $keytool @('-genkeypair', '-keystore', $keystore, '-storetype', 'JKS', '-alias', 'ci-only', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '2', '-dname', 'CN=MARGO CI ONLY', '-storepass', 'ci-only-password', '-keypass', 'ci-only-password')
Invoke-RequiredNative $keytool @('-exportcert', '-keystore', $keystore, '-alias', 'ci-only', '-storepass', 'ci-only-password', '-file', $certificate)
$fingerprint = (Get-FileHash -LiteralPath $certificate -Algorithm SHA256).Hash
foreach ($scheme in 'v1', 'v2', 'v3') {
$targetSdk = if ($scheme -eq 'v1') { 23 } else { 36 }
foreach ($build in 12, 13) {
    $manifest = Join-Path $work 'AndroidManifest.xml'
    $unsigned = Join-Path $work "unsigned-$build.apk"
    $signed = Join-Path $work "$scheme-$build.apk"
    @"
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="dev.thoth.thoth" android:versionCode="$build" android:versionName="0.4.5">
  <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="$targetSdk" />
  <application android:label="MARGO CI" android:hasCode="false" />
</manifest>
"@ | Set-Content -LiteralPath $manifest -Encoding utf8NoBOM
    Invoke-RequiredNative $aapt @('package', '-f', '-M', $manifest, '-I', $androidJar, '-F', $unsigned)
    $v2 = if ($scheme -eq 'v1') { 'false' } else { 'true' }
    $v3 = if ($scheme -eq 'v3') { 'true' } else { 'false' }
    Invoke-RequiredNative $java @('-jar', $jar, 'sign', '--ks', $keystore, '--ks-key-alias', 'ci-only', '--ks-pass', 'pass:ci-only-password', '--key-pass', 'pass:ci-only-password', '--v1-signing-enabled', 'true', '--v2-signing-enabled', $v2, '--v3-signing-enabled', $v3, '--out', $signed, $unsigned)
}
Write-Host "Android build-tools: $($tools.Name)"
$report = & $java -jar $jar verify --verbose --print-certs (Join-Path $work "$scheme-13.apk")
if ($LASTEXITCODE -ne 0) { throw 'The signed test APK failed apksigner verification.' }
Write-Host ('apksigner output: ' + ($report | ConvertTo-Json -Compress))
& (Join-Path $PSScriptRoot 'verify-android-release.ps1') -Apk (Join-Path $work "$scheme-13.apk") -PreviousApk (Join-Path $work "$scheme-12.apk") -ExpectedSha256 $fingerprint
}
Write-Host 'Android SDK release verification integration test passed.'
exit 0

