param([Parameter(Mandatory)][string]$FilePath)
$ErrorActionPreference = 'Stop'
if ($env:MARGO_WINDOWS_CERT_SHA1 -notmatch '^[a-fA-F0-9]{40}$') { throw 'Set MARGO_WINDOWS_CERT_SHA1 to the code-signing certificate thumbprint in CurrentUser/My.' }
if (-not $env:MARGO_TIMESTAMP_URL -or $env:MARGO_TIMESTAMP_URL -notmatch '^https?://') { throw 'Set MARGO_TIMESTAMP_URL to the certificate provider RFC3161 timestamp service.' }
$signtool = $env:MARGO_SIGNTOOL
if (-not $signtool) { $signtool = (Get-Command signtool.exe -ErrorAction SilentlyContinue).Source }
if (-not $signtool) {
    $signtool = Get-ChildItem -Path "${env:ProgramFiles(x86)}/Windows Kits/10/bin/*/x64/signtool.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $signtool) { throw 'Windows SDK signtool.exe is required (or set MARGO_SIGNTOOL).' }
& $signtool sign /s My /sha1 $env:MARGO_WINDOWS_CERT_SHA1 /fd SHA256 /tr $env:MARGO_TIMESTAMP_URL /td SHA256 $FilePath
if ($LASTEXITCODE -ne 0) { throw 'Authenticode signing failed.' }
& $signtool verify /pa /all /tw $FilePath
if ($LASTEXITCODE -ne 0) { throw 'Authenticode verification failed.' }
& (Join-Path $PSScriptRoot 'verify-windows-release.ps1') -FilePath $FilePath
