param([Parameter(Mandatory)][string]$Apk)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Apk).Path)
try {
    $expected = @('armeabi-v7a', 'arm64-v8a', 'x86_64')
    foreach ($abi in $expected) {
        $entry = $archive.GetEntry("lib/$abi/libapp.so")
        if (-not $entry) { throw "Missing Flutter snapshot for $abi" }
        $memory = [System.IO.MemoryStream]::new()
        $stream = $entry.Open()
        try {
            $stream.CopyTo($memory)
            $bytes = $memory.ToArray()
        } finally {
            $stream.Dispose()
            $memory.Dispose()
        }
        # Dart stores these Cyrillic strings as UTF-16; either byte alignment is valid.
        $texts = @(
            [System.Text.Encoding]::UTF8.GetString($bytes)
            [System.Text.Encoding]::Unicode.GetString($bytes)
            [System.Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1)
        )
        foreach ($required in @('Не менее 8 символов', 'Введите 6 цифр из письма')) {
            if (-not ($texts | Where-Object { $_.Contains($required) })) {
                throw "Stale account-access snapshot for ${abi}: missing '$required'"
            }
        }
        if ($texts | Where-Object { $_.Contains('Не менее 10 символов') }) {
            throw "Stale 10-character password rule in $abi"
        }
        Write-Host "Verified account access in ${abi}: six-digit code, password from 8 characters."
    }
} finally {
    $archive.Dispose()
}
