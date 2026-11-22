$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sdk = Join-Path $root '.tools/flutter/bin/flutter.bat'
if (-not (Test-Path -LiteralPath $sdk)) { $sdk = 'flutter' }
Push-Location -LiteralPath (Join-Path $root 'apps/margo_flutter')
try {
    & $sdk pub get
    if ($LASTEXITCODE -ne 0) { throw 'pub get failed' }
    & $sdk analyze
    if ($LASTEXITCODE -ne 0) { throw 'Analysis failed' }
    & $sdk test
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
    $endpointArgs = @()
    foreach ($name in 'API_BASE_URL', 'UPDATE_MANIFEST_URL') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { $endpointArgs += "--dart-define=$name=$value" }
    }
    & $sdk build windows --release @endpointArgs
    if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
    $out = Join-Path $root 'dist'
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    @('MARGO', 'Extract the entire archive, then run margo.exe.', 'Keep all DLL files and the data folder next to the executable.', 'Sign in to sync or choose demo mode.') | Set-Content -LiteralPath 'build/windows/x64/runner/Release/START-HERE.txt' -Encoding UTF8
    Compress-Archive -Path 'build/windows/x64/runner/Release/*' -DestinationPath (Join-Path $out 'MARGO-Windows.zip') -Force
    Write-Host 'Готово: dist/MARGO-Windows.zip. Передавайте весь архив, не только exe.'
} finally { Pop-Location }
