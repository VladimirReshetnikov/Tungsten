#requires -Version 7.0
<#
.SYNOPSIS
Runs Tungsten parser corpus checks against the local Wolfram parser corpus.

.DESCRIPTION
This is a Windows-friendly wrapper around:

    tungsten-cpp parser-corpus compare

By default it parses a bounded sample from
`C:\TestData\wolfram\tungsten-wolfram-parser-corpus`, compares Tungsten parse acceptance with the local
Wolfram kernel using held parsing, and writes JSON/Markdown artifacts under the corpus
`validation` directory.

The Wolfram side uses `ToExpression[..., InputForm, HoldComplete]`; corpus files are parsed but
not evaluated.

Use `-TungstenWorkers 8` on this machine for broad notebook-heavy runs.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string] $CorpusRoot = 'C:\TestData\wolfram\tungsten-wolfram-parser-corpus',

    [Parameter()]
    [string] $OutDir,

    [Parameter()]
    [string[]] $Extension = @(),

    [Parameter()]
    [string[]] $IncludeGlob = @(),

    [Parameter()]
    [string[]] $ExcludeGlob = @(),

    [Parameter()]
    [Nullable[long]] $MaxFiles = 100,

    [Parameter()]
    [double] $MaxFileMB = 2.0,

    [Parameter()]
    [string] $MaxBytes,

    [Parameter()]
    [switch] $NoMaxBytes,

    [Parameter()]
    [ValidateSet('input', 'fullform', 'standard')]
    [string] $Form = 'input',

    [Parameter()]
    [switch] $SkipWolfram,

    [Parameter()]
    [int] $KernelBatchSize = 100,

    [Parameter()]
    [int] $TungstenWorkers = 1,

    [Parameter()]
    [int] $PreviewChars = 2000,

    [Parameter()]
    [switch] $Shuffle,

    [Parameter()]
    [string] $Seed = '0',

    [Parameter()]
    [switch] $NoWrite,

    [Parameter()]
    [switch] $IncludeResults,

    [Parameter()]
    [switch] $FailOnTungstenGap,

    [Parameter()]
    [switch] $FailOnMismatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-TungstenExecutable {
    if (-not [string]::IsNullOrWhiteSpace($env:TUNGSTEN_EXECUTABLE)) {
        return $env:TUNGSTEN_EXECUTABLE
    }
    $name = if ($IsWindows) { 'tungsten-cpp.exe' } else { 'tungsten-cpp' }
    foreach ($relativePath in @(
        "build/cpp/$name",
        "build/cpp/Release/$name",
        "build/cpp/Debug/$name",
        "build/cpp/RelWithDebInfo/$name",
        "build/cpp/MinSizeRel/$name"
    )) {
        $candidate = Join-Path $projectRoot $relativePath
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    $command = Get-Command tungsten-cpp -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    throw "The native Tungsten executable was not found. Build tungsten-cpp or set TUNGSTEN_EXECUTABLE."
}

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$tungsten = Resolve-TungstenExecutable
$invariantCulture = [Globalization.CultureInfo]::InvariantCulture

$arguments = @(
    'parser-corpus', 'compare',
    '--corpus-root', $CorpusRoot,
    '--max-file-mb', $MaxFileMB.ToString($null, $invariantCulture),
    '--form', $Form,
    '--kernel-batch-size', $KernelBatchSize.ToString($invariantCulture),
    '--tungsten-workers', $TungstenWorkers.ToString($invariantCulture),
    '--preview-chars', $PreviewChars.ToString($invariantCulture),
    '--seed', $Seed
)

if ($OutDir) {
    $arguments += @('--out-dir', $OutDir)
}
foreach ($item in $Extension) {
    $arguments += @('--extension', $item)
}
foreach ($item in $IncludeGlob) {
    $arguments += @('--include-glob', $item)
}
foreach ($item in $ExcludeGlob) {
    $arguments += @('--exclude-glob', $item)
}
if ($null -ne $MaxFiles) {
    $arguments += @('--max-files', $MaxFiles.ToString($invariantCulture))
}
if (-not [string]::IsNullOrWhiteSpace($MaxBytes)) {
    $arguments += @('--max-bytes', $MaxBytes)
}
if ($NoMaxBytes) {
    $arguments += '--no-max-bytes'
}
if ($SkipWolfram) {
    $arguments += '--skip-wolfram'
}
if ($Shuffle) {
    $arguments += '--shuffle'
}
if ($NoWrite) {
    $arguments += '--no-write'
}
if ($IncludeResults) {
    $arguments += '--include-results'
}
if ($FailOnTungstenGap) {
    $arguments += '--fail-on-tungsten-gap'
}
if ($FailOnMismatch) {
    $arguments += '--fail-on-mismatch'
}

& $tungsten @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Tungsten parser corpus comparison failed with exit code $LASTEXITCODE."
}
