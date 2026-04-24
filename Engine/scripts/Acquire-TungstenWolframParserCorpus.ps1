#requires -Version 7.0
<#
.SYNOPSIS
Acquires a large notebook/package corpus for Tungsten's Wolfram parser work.

.DESCRIPTION
Wraps `acquire_wolfram_parser_corpus.py` with Windows-friendly defaults so the corpus can be
refreshed with a single PowerShell command. The underlying Python script downloads Wolfram
notebooks and packages into `C:\TestData` by default, preserving provenance and writing a manifest
and README alongside the corpus.

This corpus is intended for local parser-corpus use only. It is not meant to be bundled into
Tungsten or redistributed from this workspace.

.PARAMETER OutDir
Destination directory for the acquired corpus.

.PARAMETER Force
Re-downloads and overwrites existing snapshots and archive files under `OutDir`.

.PARAMETER SkipGitHub
Skips GitHub package/notebook corpus acquisition.

.PARAMETER SkipNotebookArchive
Skips Notebook Archive notebook acquisition.

.PARAMETER SkipHistoricalNotebookArchive
Only fetches the non-historical Notebook Archive notebook bucket.

.PARAMETER MaxDiscoveredRepositories
Maximum number of non-curated GitHub repositories to add through discovery queries and org scans.

.PARAMETER MaxDiscoveredRepoSizeMB
Skips discovered GitHub repositories larger than this approximate size.

.PARAMETER MaxFileMB
Drops individual GitHub snapshot files larger than this size after sparse checkout.

.PARAMETER NoExtractPaclets
Keeps `.paclet` files without extracting parser-relevant contents.

.PARAMETER FetchLfsContent
Allows Git LFS blobs to materialize during GitHub sparse checkout.

.PARAMETER GitHubToken
Optional GitHub token. Defaults to `GITHUB_TOKEN` when present.

.PARAMETER NotebookArchiveWorkers
Concurrent Notebook Archive download workers.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string] $OutDir = 'C:\TestData\tungsten-wolfram-parser-corpus',

    [Parameter()]
    [switch] $Force,

    [Parameter()]
    [switch] $SkipGitHub,

    [Parameter()]
    [switch] $SkipNotebookArchive,

    [Parameter()]
    [switch] $SkipHistoricalNotebookArchive,

    [Parameter()]
    [int] $MaxDiscoveredRepositories = 24,

    [Parameter()]
    [int] $MaxDiscoveredRepoSizeMB = 512,

    [Parameter()]
    [int] $MaxFileMB = 64,

    [Parameter()]
    [switch] $NoExtractPaclets,

    [Parameter()]
    [switch] $FetchLfsContent,

    [Parameter()]
    [string] $GitHubToken = $env:GITHUB_TOKEN,

    [Parameter()]
    [int] $NotebookArchiveWorkers = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Tool([string] $Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' was not found on PATH."
    }
}

Assert-Tool python

$pythonScript = Join-Path $PSScriptRoot 'acquire_wolfram_parser_corpus.py'
if (-not (Test-Path -LiteralPath $pythonScript -PathType Leaf)) {
    throw "Python corpus acquisition script not found: $pythonScript"
}

$arguments = @(
    $pythonScript,
    '--out', $OutDir,
    '--max-discovered-repositories', $MaxDiscoveredRepositories,
    '--max-discovered-repo-size-mb', $MaxDiscoveredRepoSizeMB,
    '--max-file-mb', $MaxFileMB,
    '--notebook-archive-workers', $NotebookArchiveWorkers
)

if ($Force) {
    $arguments += '--force'
}
if ($SkipGitHub) {
    $arguments += '--skip-github'
}
if ($SkipNotebookArchive) {
    $arguments += '--skip-notebook-archive'
}
if ($SkipHistoricalNotebookArchive) {
    $arguments += '--skip-historical-notebook-archive'
}
if ($NoExtractPaclets) {
    $arguments += '--no-extract-paclets'
}
if ($FetchLfsContent) {
    $arguments += '--fetch-lfs-content'
}
if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
    $arguments += '--github-token'
    $arguments += $GitHubToken
}

& python @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Corpus acquisition failed with exit code $LASTEXITCODE."
}
