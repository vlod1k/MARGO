param(
    [string]$IsccPath,
    [string]$CRuntimeDir,
    [switch]$AllowUnsigned
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $AllowUnsigned -and $env:MARGO_WINDOWS_CERT_SHA1 -notmatch '^[a-fA-F0-9]{40}$') {
    throw 'Release signing is required. Configure MARGO_WINDOWS_CERT_SHA1 and MARGO_TIMESTAMP_URL; see docs/release-signing.md. Use -AllowUnsigned only for development.'
}
$release = Join-Path $root 'apps/margo_flutter/build/windows/x64/runner/Release'
foreach ($file in @('margo.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat')) {
    if (-not (Test-Path -LiteralPath (Join-Path $release $file) -PathType Leaf)) {
        throw 'Windows release files are missing. Run scripts/build-windows.ps1 first.'
    }
}

$programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
if (-not $IsccPath) {
    $IsccPath = @(
        (Join-Path $root '.tools/inno-setup/ISCC.exe')
        (Get-Command ISCC.exe -CommandType Application -ErrorAction SilentlyContinue).Source
        (Join-Path $programFilesX86 'Inno Setup 6/ISCC.exe')
        (Join-Path $env:LOCALAPPDATA 'Programs/Inno Setup 6/ISCC.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
}
if (-not $IsccPath -or -not (Test-Path -LiteralPath $IsccPath -PathType Leaf)) {
    throw 'Install Inno Setup 6 or pass the path to ISCC.exe with -IsccPath.'
}

if (-not $CRuntimeDir) {
    $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($vs) {
            $redist = Join-Path $vs 'VC/Redist/MSVC'
            $CRuntimeDir = Get-ChildItem -Path (Join-Path $redist '*/x64/Microsoft.VC*.CRT') -Directory |
                Sort-Object { [version]$_.Parent.Parent.Name } -Descending |
                Select-Object -First 1 -ExpandProperty FullName
        }
    }
}
foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (-not $CRuntimeDir -or -not (Test-Path -LiteralPath (Join-Path $CRuntimeDir $dll) -PathType Leaf)) {
        throw 'Visual C++ x64 redistributable DLLs are missing. Install the Visual Studio C++ tools or pass their x64 CRT directory with -CRuntimeDir.'
    }
}

$iscc = (Resolve-Path -LiteralPath $IsccPath).Path
$crt = (Resolve-Path -LiteralPath $CRuntimeDir).Path
$compilerArguments = @("/DCRuntimeDir=$crt")
if (-not $AllowUnsigned) {
    & (Join-Path $PSScriptRoot 'sign-windows.ps1') -FilePath (Join-Path $release 'margo.exe')
    # Inno substitutes $q and $f with quoted paths; no private key/password is passed.
    $signScript = Join-Path $PSScriptRoot 'sign-windows.ps1'
    $compilerArguments += '/DProductionSigning=1'
    $compilerArguments += ('/Smargo=powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $q' + $signScript + '$q -FilePath $f')
}
& $iscc @compilerArguments (Join-Path $root 'packaging/windows/margo.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compiler failed (exit code $LASTEXITCODE)." }
if (-not $AllowUnsigned) {
    $version = (Get-Item -LiteralPath (Join-Path $release 'margo.exe')).VersionInfo
    $installer = Join-Path $root "dist/MARGO-Setup-$($version.FileMajorPart).$($version.FileMinorPart).$($version.FileBuildPart).exe"
    & (Join-Path $PSScriptRoot 'verify-windows-release.ps1') -FilePath $installer
}
