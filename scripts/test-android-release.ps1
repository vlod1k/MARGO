$ErrorActionPreference = 'Stop'

# Load the real identity reader without running the release CLI. Only external
# commands are substituted so parser regressions do not need a built APK.
$tokens = $null
$parseErrors = $null
$scriptPath = Join-Path $PSScriptRoot 'verify-android-release.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Release verification script has syntax errors.' }
$reader = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-ApkIdentity' }, $true)
if (-not $reader) { throw 'Read-ApkIdentity was not found.' }
. ([scriptblock]::Create($reader.Extent.Text))

$java = 'Invoke-TestApkSigner'
$aapt = 'Invoke-TestAapt'
$buildTools = [pscustomobject]@{ FullName = $PSScriptRoot }
$script:signatureExitCode = 0
function Invoke-TestApkSigner {
    $global:LASTEXITCODE = $script:signatureExitCode
    $script:signatureReport -split "`n"
}
function Invoke-TestAapt {
    $global:LASTEXITCODE = 0
    "package: name='dev.thoth.thoth' versionCode='13' versionName='0.4.5'"
}

$digest = 'a' * 64
$otherDigest = 'b' * 64
$cases = @(
    @{ Name = 'numbered signer with LF'; Report = "Number of signers: 1`nSigner #1 certificate SHA-256 digest: $digest"; Accept = $true },
    @{ Name = 'numbered signer with CRLF'; Report = "Number of signers: 1`r`nSigner #1 certificate SHA-256 digest: $($digest.ToUpperInvariant())`r`n"; Accept = $true },
    @{ Name = 'SDK-range signer'; Report = "Number of signers: 1`nSigner (minSdkVersion=24, maxSdkVersion=2147483647) certificate SHA-256 digest: $digest"; Accept = $true },
    @{ Name = 'same certificate across SDK ranges'; Report = "Number of signers: 1`nSigner (minSdkVersion=24, maxSdkVersion=32) certificate SHA-256 digest: $digest`nSigner (minSdkVersion=33, maxSdkVersion=2147483647) certificate SHA-256 digest: $digest"; Accept = $true },
    @{ Name = 'source stamp is not an APK signer'; Report = "Number of signers: 1`nSigner #1 certificate SHA-256 digest: $digest`nSource Stamp Signer certificate SHA-256 digest: $otherDigest"; Accept = $true },
    @{ Name = 'different certificates across SDK ranges'; Report = "Number of signers: 1`nSigner (minSdkVersion=24, maxSdkVersion=32) certificate SHA-256 digest: $digest`nSigner (minSdkVersion=33, maxSdkVersion=2147483647) certificate SHA-256 digest: $otherDigest"; Accept = $false },
    @{ Name = 'multiple APK signers'; Report = "Number of signers: 2`nSigner #1 certificate SHA-256 digest: $digest`nSigner #2 certificate SHA-256 digest: $otherDigest"; Accept = $false },
    @{ Name = 'multiple signers with identical certificates'; Report = "Number of signers: 2`nSigner #1 certificate SHA-256 digest: $digest`nSigner #2 certificate SHA-256 digest: $digest"; Accept = $false },
    @{ Name = 'missing signer count'; Report = "Signer #1 certificate SHA-256 digest: $digest"; Accept = $false },
    @{ Name = 'missing certificate digest'; Report = 'Number of signers: 1'; Accept = $false },
    @{ Name = 'truncated certificate digest'; Report = 'Number of signers: 1' + "`nSigner #1 certificate SHA-256 digest: abc123"; Accept = $false }
)
$failed = @()
foreach ($case in $cases) {
    $script:signatureReport = $case.Report
    try {
        $identity = Read-ApkIdentity $scriptPath
        if (-not $case.Accept) { throw "Accepted an invalid signature report: $($case.Name)" }
        if ($identity.Sha256 -cne $digest -or $identity.Package -ne 'dev.thoth.thoth' -or $identity.Build -ne 13) { throw 'Incorrect APK identity.' }
        Write-Host "PASS $($case.Name)"
    } catch {
        if ($case.Accept -or $_.Exception.Message -like 'Accepted an invalid*' -or $_.Exception.Message -eq 'Incorrect APK identity.') {
            $failed += "$($case.Name): $($_.Exception.Message)"
        } else {
            Write-Host "PASS rejects $($case.Name)"
        }
    }
}
$script:signatureExitCode = 1
$script:signatureReport = "Number of signers: 1`nSigner #1 certificate SHA-256 digest: $digest"
try {
    $null = Read-ApkIdentity $scriptPath
    $failed += 'Invalid APK signature exit code was accepted.'
} catch {
    if ($_.Exception.Message -notlike 'Invalid APK signature:*') { $failed += 'Unexpected failure for invalid APK signature.' }
    else { Write-Host 'PASS rejects failed cryptographic verification' }
}
if ($failed.Count) { throw ($failed -join "`n") }
Write-Host 'All Android release verification tests passed.'
