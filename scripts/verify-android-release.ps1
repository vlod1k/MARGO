param(
    [Parameter(Mandatory)][string]$Apk,
    [string]$PreviousApk,
    [string]$ExpectedSha256 = $env:MARGO_ANDROID_CERT_SHA256,
    [switch]$AllowLegacyDebugCertificate
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sdkRoot = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { Join-Path $root '.tools/android-sdk' }
$buildTools = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'build-tools') -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'lib/apksigner.jar') } |
    Sort-Object { [version]($_.Name -replace '-.*$', '') } -Descending | Select-Object -First 1
if (-not $buildTools) { throw 'Android build-tools with apksigner and aapt are required.' }
$java = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin/java' } else { 'java' }
if ($IsWindows -or $env:OS -eq 'Windows_NT') { $java = if ($env:JAVA_HOME) { "$java.exe" } else { 'java.exe' } }
if (-not $env:JAVA_HOME) {
    $localJava = Get-ChildItem -Path (Join-Path $root '.tools/java/*/bin/java.exe') -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if ($localJava) { $java = $localJava }
    elseif (-not (Get-Command $java -ErrorAction SilentlyContinue)) { throw 'Java is required for apksigner. Set JAVA_HOME.' }
}
$aapt = Join-Path $buildTools.FullName $(if ($env:OS -eq 'Windows_NT') { 'aapt.exe' } else { 'aapt' })
function Read-ApkIdentity([string]$Path) {
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $signature = (& $java -jar (Join-Path $buildTools.FullName 'lib/apksigner.jar') verify --verbose --print-certs $resolved 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "Invalid APK signature: $Path" }
    $signerCounts = [regex]::Matches($signature, '(?m)^Number of signers:[ \t]*(\d+)[ \t]*\r?$')
    # apksigner labels vary by build-tools version and signature scheme.
    # Repeated appearances of the same certificate still identify one signing key.
    $certificateMatches = [regex]::Matches($signature, '(?m)^(?:Signer (?:#\d+|\(minSdkVersion=\d+(?: \(dev release=true\))?, maxSdkVersion=\d+\))|V3\.[012] Signer:) certificate SHA-256 digest:[ \t]*([a-fA-F0-9]{64})[ \t]*\r?$')
    $digests = @($certificateMatches | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Sort-Object -Unique)
    if ($signerCounts.Count -ne 1 -or $signerCounts[0].Groups[1].Value -ne '1' -or $digests.Count -ne 1) {
        $details = $signature -replace '\r?\n', '; '
        throw "Expected exactly one APK signer and signing certificate. apksigner reported: $details"
    }
    $badging = (& $aapt dump badging $resolved) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $badging -notmatch "package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'") { throw 'Unable to read APK identity.' }
    $identity = @{ Package = $Matches[1]; Build = [long]$Matches[2]; Version = $Matches[3]; Sha256 = $digests[0]; DebugCertificate = $signature -match 'CN=Android Debug'; Debuggable = $badging -match '(?m)^application-debuggable' }
    return $identity
}
$current = Read-ApkIdentity $Apk
if ($current.Package -ne 'dev.thoth.thoth' -or $current.Debuggable) { throw 'Not a MARGO release APK (identity or debuggable flag).' }
if ($current.DebugCertificate -and (-not $AllowLegacyDebugCertificate -or -not $ExpectedSha256)) {
    throw 'Legacy debug certificate requires -AllowLegacyDebugCertificate AND a pinned MARGO_ANDROID_CERT_SHA256. Use only to preserve the existing direct-install channel.'
}
if ($ExpectedSha256) {
    $expected = ($ExpectedSha256 -replace ':|\s', '').ToLowerInvariant()
    if ($expected -notmatch '^[a-f0-9]{64}$' -or $current.Sha256 -ne $expected) { throw 'APK signer differs from the pinned release certificate.' }
}
if ($PreviousApk) {
    $previous = Read-ApkIdentity $PreviousApk
    if ($current.Package -ne $previous.Package -or $current.Sha256 -ne $previous.Sha256 -or $current.Build -le $previous.Build) {
        throw 'APK cannot update the previous package: package/signer must match and versionCode must increase. Do not publish to that update channel.'
    }
}
Write-Host "Verified APK $($current.Version)+$($current.Build); signer SHA-256: $($current.Sha256)"
if ($current.DebugCertificate) { Write-Warning 'Legacy Android identity retained for existing installations. This is not eligible for Google Play publication.' }

