[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $IncludeReports
)

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$tungstenRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$docsRoot = Join-Path $tungstenRoot "docs"

$head = (& git -C $repoRoot rev-parse HEAD).Trim()
if ([string]::IsNullOrWhiteSpace($head)) {
    throw "git rev-parse HEAD did not return a usable commit SHA."
}

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$targets = @(
    Get-Item (Join-Path $tungstenRoot "README.md")
    Get-ChildItem -Path $docsRoot -Recurse -File -Filter "*.md" |
        Where-Object { $IncludeReports -or $_.FullName -notmatch "\\docs\\reports\\" }
)

foreach ($file in $targets) {
    $original = Get-Content -LiteralPath $file.FullName -Raw
    $updated = [regex]::Replace(
        $original,
        '(?m)^(?<prefix>-\s*)?Repository HEAD: .*$',
        '${prefix}Repository HEAD: ' + $head)

    $updatedLinePattern = '(?m)^(?<prefix>-\s*)?Updated \(UTC\): .*$'
    if ([regex]::IsMatch($updated, $updatedLinePattern)) {
        $updated = [regex]::Replace(
            $updated,
            $updatedLinePattern,
            '${prefix}Updated (UTC): ' + $timestamp)
    }
    else {
        $createdPattern = '(?m)^(?<prefix>-\s*)?Created \(UTC\): .*$'
        $createdMatch = [regex]::Match($updated, $createdPattern)
        if ($createdMatch.Success) {
            $prefix = $createdMatch.Groups["prefix"].Value
            $insertion = $createdMatch.Value + [Environment]::NewLine + $prefix + "Updated (UTC): " + $timestamp
            $updated = $updated.Remove($createdMatch.Index, $createdMatch.Length).Insert($createdMatch.Index, $insertion)
        }
    }

    if ($updated -ne $original -and $PSCmdlet.ShouldProcess($file.FullName, "Update Tungsten doc provenance metadata")) {
        $normalized = $updated.TrimEnd("`r", "`n") + "`r`n"
        Set-Content -LiteralPath $file.FullName -Value $normalized -Encoding utf8 -NoNewline
    }
}
