param(
    [Parameter(Mandatory)][string]$FilePath,
    [string]$ExpectedThumbprint = $env:MARGO_WINDOWS_CERT_SHA1
)
$ErrorActionPreference = 'Stop'
if ($ExpectedThumbprint -notmatch '^[a-fA-F0-9]{40}$') { throw 'MARGO_WINDOWS_CERT_SHA1 must pin the release certificate.' }
$signature = Get-AuthenticodeSignature -LiteralPath $FilePath
if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate -or $signature.SignerCertificate.Thumbprint -ne $ExpectedThumbprint) {
    throw "Invalid, untimestamped or unexpected Authenticode signature: $FilePath"
}
Write-Host "Verified Authenticode signature: $FilePath"
