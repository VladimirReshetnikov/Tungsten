param(
    [string]$WolframRoot = "C:\Program Files\Wolfram Research\Wolfram\15.0",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot "src\tungsten\data\system_symbols_wolfram_15_0.json"
}

$wolframExe = Join-Path $WolframRoot "wolfram.exe"
if (-not (Test-Path -LiteralPath $wolframExe)) {
    throw "wolfram.exe was not found under '$WolframRoot'."
}

$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$wolframOutputPath = ($OutputPath -replace "\\", "/")
$code = @'
names = Select[Names["System`*"], FreeQ[#, "`"] &];
rows = ({#, ToString /@ Attributes[Evaluate["System`" <> #]]} &) /@ names;
payload = <|
  "wolframVersion" -> $Version,
  "context" -> "System`",
  "symbolCount" -> Length[rows],
  "symbols" -> rows
|>;
Export["__OUTPUT__", payload, "RawJSON", CharacterEncoding -> "UTF-8"]
'@
$code = $code.Replace("__OUTPUT__", $wolframOutputPath)

$scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("tungsten-system-symbols-" + [guid]::NewGuid().ToString("N") + ".wl")
try {
    Set-Content -LiteralPath $scriptPath -Value $code -Encoding UTF8
    & $wolframExe -noprompt -script $scriptPath
    $exitCode = $LASTEXITCODE
}
finally {
    if (Test-Path -LiteralPath $scriptPath) {
        Remove-Item -LiteralPath $scriptPath -Force
    }
}

if ($exitCode -ne 0) {
    throw "wolfram.exe exited with code $exitCode."
}

$json = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($json.symbolCount -ne $json.symbols.Count) {
    throw "Generated symbol snapshot count mismatch: metadata=$($json.symbolCount), rows=$($json.symbols.Count)."
}

Write-Host "Wrote $($json.symbolCount) System symbols to $OutputPath"
