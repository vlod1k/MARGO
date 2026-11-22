param([ValidateRange(1, 65535)][int]$Port = 8000)
$ErrorActionPreference = 'Stop'
$address = "http://127.0.0.1:$Port"
$listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
if ($listeners.Count -gt 0) {
    $schema = $null
    try {
        $schema = Invoke-RestMethod -Uri "$address/openapi.json" -TimeoutSec 3
    } catch {
        # An occupied port can belong to an unrelated service.
    }
    if ($schema -and $schema.info.title -eq 'MARGO API') {
        Write-Host "MARGO API уже запущен: $address"
        Write-Host "Можно открывать приложение. Документация API: $address/docs"
        return
    }
    $owners = ($listeners.OwningProcess | Sort-Object -Unique) -join ', '
    throw "Порт $Port занят другим процессом (PID: $owners). Запустите ./scripts/start-backend.ps1 -Port 8001 и передайте Flutter параметр --dart-define=API_BASE_URL=http://127.0.0.1:8001."
}
$backend = Join-Path (Split-Path -Parent $PSScriptRoot) 'backend'
Push-Location -LiteralPath $backend
try {
    uv sync --locked
    if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed' }
    uv run alembic upgrade head
    if ($LASTEXITCODE -ne 0) { throw 'Migration failed' }
    uv run python -m app.seed
    if ($LASTEXITCODE -ne 0) { throw 'Catalog initialization failed' }
    uv run uvicorn app.main:app --host 127.0.0.1 --port $Port
    if ($LASTEXITCODE -ne 0) { throw "Не удалось запустить MARGO API на $address. Проверьте, свободен ли порт $Port." }
} finally { Pop-Location }
