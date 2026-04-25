#requires -Version 7.0
<#
.SYNOPSIS
Runs Tungsten parser corpus checks against the local Wolfram parser corpus.

.DESCRIPTION
This is a Windows-friendly wrapper around:

    python -m tungsten parser-corpus compare

By default it parses a bounded sample from
`C:\TestData\tungsten-wolfram-parser-corpus`, compares Tungsten parse acceptance with the local
Wolfram kernel using held parsing, and writes JSON/Markdown artifacts under the corpus
`validation` directory.

The Wolfram side uses `ToExpression[..., InputForm, HoldComplete]`; corpus files are parsed but
not evaluated.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string] $CorpusRoot = 'C:\TestData\tungsten-wolfram-parser-corpus',

    [Parameter()]
    [string] $OutDir,

    [Parameter()]
    [string[]] $Extension = @(),

    [Parameter()]
    [string[]] $IncludeGlob = @(),

    [Parameter()]
    [string[]] $ExcludeGlob = @(),

    [Parameter()]
    [Nullable[int]] $MaxFiles = 100,

    [Parameter()]
    [double] $MaxFileMB = 2.0,

    [Parameter()]
    [Nullable[int]] $MaxBytes = $null,

    [Parameter()]
    [switch] $NoMaxBytes,

    [Parameter()]
    [ValidateSet('input', 'fullform', 'standard')]
    [string] $Form = 'input',

    [Parameter()]
    [switch] $SkipWolfram,

    [Parameter()]
    [int] $KernelBatchSize = 25,

    [Parameter()]
    [int] $PreviewChars = 2000,

    [Parameter()]
    [switch] $Shuffle,

    [Parameter()]
    [int] $Seed = 0,

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

function Assert-Tool([string] $Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' was not found on PATH."
    }
}

Assert-Tool python

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$sourceRoot = Join-Path $projectRoot 'src'
$previousPythonPath = $env:PYTHONPATH
$separator = [System.IO.Path]::PathSeparator

$arguments = @(
    '-m', 'tungsten',
    'parser-corpus', 'compare',
    '--corpus-root', $CorpusRoot,
    '--max-file-mb', $MaxFileMB,
    '--form', $Form,
    '--kernel-batch-size', $KernelBatchSize,
    '--preview-chars', $PreviewChars,
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
    $arguments += @('--max-files', $MaxFiles)
}
if ($null -ne $MaxBytes) {
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

try {
    $env:PYTHONPATH = if ([string]::IsNullOrWhiteSpace($previousPythonPath)) {
        $sourceRoot
    }
    else {
        "$sourceRoot$separator$previousPythonPath"
    }

    & python @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Tungsten parser corpus comparison failed with exit code $LASTEXITCODE."
    }
}
finally {
    $env:PYTHONPATH = $previousPythonPath
}
