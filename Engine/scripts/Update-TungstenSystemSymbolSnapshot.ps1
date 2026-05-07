param(
    [string]$WolframRoot = "C:\Program Files\Wolfram Research\Wolfram\14.3",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot "src\tungsten\data\system_symbols_wolfram_14_3.json"
}

$wolframScript = Join-Path $WolframRoot "wolframscript.exe"
if (-not (Test-Path -LiteralPath $wolframScript)) {
    throw "wolframscript.exe was not found under '$WolframRoot'."
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

& $wolframScript -code $code
if ($LASTEXITCODE -ne 0) {
    throw "wolframscript exited with code $LASTEXITCODE."
}

$json = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($json.symbolCount -ne $json.symbols.Count) {
    throw "Generated symbol snapshot count mismatch: metadata=$($json.symbolCount), rows=$($json.symbols.Count)."
}

Write-Host "Wrote $($json.symbolCount) System symbols to $OutputPath"
