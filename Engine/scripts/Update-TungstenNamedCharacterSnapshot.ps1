param(
    [string]$WolframRoot = "C:\Program Files\Wolfram Research\Wolfram\15.0",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot "src\tungsten\data\wolfram_named_characters_15_0.json"
}

$unicodeCharactersPath = Join-Path $WolframRoot "SystemFiles\FrontEnd\TextResources\UnicodeCharacters.tr"
if (-not (Test-Path -LiteralPath $unicodeCharactersPath)) {
    throw "UnicodeCharacters.tr was not found under '$WolframRoot'."
}

$excludedKernelRejectedNames = @(
    "COMPATIBILITYKanjiSpace",
    "COMPATIBILITYNoBreak"
)

$characters = [ordered]@{}
foreach ($line in Get-Content -LiteralPath $unicodeCharactersPath -Encoding UTF8) {
    if ($line -notmatch '^0x([0-9A-Fa-f]+)\s+\\\[([^\]]+)\]') {
        continue
    }

    $name = $Matches[2]
    if ($excludedKernelRejectedNames -contains $name) {
        continue
    }

    $characters[$name] = [Convert]::ToInt32($Matches[1], 16)
}

$sortedCharacters = [ordered]@{}
foreach ($name in ($characters.Keys | Sort-Object)) {
    $sortedCharacters[$name] = $characters[$name]
}

$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$version = Split-Path -Leaf $WolframRoot
$payload = [ordered]@{
    source = "Wolfram $version SystemFiles/FrontEnd/TextResources/UnicodeCharacters.tr"
    excludedKernelRejectedNames = $excludedKernelRejectedNames
    characters = $sortedCharacters
}

$payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

$json = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
$jsonCharacterCount = @($json.characters.PSObject.Properties).Count
if ($jsonCharacterCount -ne $characters.Count) {
    throw "Generated named-character snapshot count mismatch: metadata=$($characters.Count), rows=$jsonCharacterCount."
}

Write-Host "Wrote $($characters.Count) named characters to $OutputPath"
