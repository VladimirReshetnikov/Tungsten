#requires -Version 7.0
<#
.SYNOPSIS
Acquires sparse snapshots of upstream Wolfram-language parser and evaluator test suites for Tungsten.

.DESCRIPTION
Clones a curated set of upstream repositories with `--filter=blob:none`, checks out only the
selected test and dataset paths via sparse checkout, preserves root license/readme files when
present, and writes snapshot provenance into `C:\TestData` by default.

This is intended for local corpus mining and later adaptation into Tungsten tests. The downloaded
snapshots are not guaranteed to be directly runnable in isolation because some upstream projects
co-locate tests with implementation code or expect their native build/runtime environment.

.PARAMETER OutDir
Destination directory for the sparse snapshots and generated manifests.

.PARAMETER Repository
Optional repository selector. Accepts either the local corpus id (for example `mathics-core`) or
the upstream `owner/name` repo slug (for example `Mathics3/mathics-core`).

.PARAMETER Force
Re-downloads and overwrites existing snapshots under `OutDir`.

.PARAMETER FetchLfsContent
Allows Git LFS objects to be fetched. By default the script sets `GIT_LFS_SKIP_SMUDGE=1` so large
LFS-backed assets are not materialized unnecessarily.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string] $OutDir = 'C:\TestData\tungsten-wolfram-upstream-tests',

    [Parameter()]
    [string[]] $Repository,

    [Parameter()]
    [switch] $Force,

    [Parameter()]
    [switch] $FetchLfsContent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CuratedRepositories = @(
    [pscustomobject]@{
        Id = 'mathics-core'
        Repository = 'Mathics3/mathics-core'
        Url = 'https://github.com/Mathics3/mathics-core.git'
        Directories = @('test')
        Files = @()
        Focus = @('parser', 'evaluator', 'builtins', 'patterns')
        Why = 'Largest maintained WL-like evaluator/parser suite; good source of builtin semantics and structural cases.'
    }
    [pscustomobject]@{
        Id = 'mathics3-scanner'
        Repository = 'Mathics3/Mathics3-scanner'
        Url = 'https://github.com/Mathics3/Mathics3-scanner.git'
        Directories = @('test')
        Files = @()
        Focus = @('lexer', 'parser', 'operators')
        Why = 'Tokenizer/operator-table tests that complement Tungsten parser coverage.'
    }
    [pscustomobject]@{
        Id = 'expreduce'
        Repository = 'corywalker/expreduce'
        Url = 'https://github.com/corywalker/expreduce.git'
        Directories = @('expreduce')
        Files = @()
        Focus = @('parser', 'evaluator', 'rules', 'pattern-matching')
        Why = 'Go tests are co-located with implementation files, so the full package directory is the useful unit.'
    }
    [pscustomobject]@{
        Id = 'symja_android_library'
        Repository = 'axkr/symja_android_library'
        Url = 'https://github.com/axkr/symja_android_library.git'
        Directories = @(
            'symja_android_library/matheclipse-core/src/test',
            'symja_android_library/matheclipse-parser/src/test'
        )
        Files = @()
        Focus = @('parser', 'evaluator', 'java', 'broad-builtins')
        Why = 'Parser and evaluator suites are split cleanly into dedicated test roots.'
    }
    [pscustomobject]@{
        Id = 'woxi'
        Repository = 'ad-si/Woxi'
        Url = 'https://github.com/ad-si/Woxi.git'
        Directories = @('tests', 'datasets')
        Files = @('all_mathics_tests.txt')
        Focus = @('parser', 'evaluator', 'golden-snapshots', 'datasets')
        Why = 'Modern Rust subset implementation with explicit tests plus a Mathics-derived corpus file.'
    }
    [pscustomobject]@{
        Id = 'howl'
        Repository = 'davidsd/howl'
        Url = 'https://github.com/davidsd/howl.git'
        Directories = @('test')
        Files = @()
        Focus = @('parser', 'evaluator', 'subset', 'small-suite')
        Why = 'Compact Haskell subset interpreter; likely easier to port into focused Tungsten cases.'
    }
    [pscustomobject]@{
        Id = 'mmaclone'
        Repository = 'jyh1/mmaclone'
        Url = 'https://github.com/jyh1/mmaclone.git'
        Directories = @('mmaclone/test')
        Files = @()
        Focus = @('parser', 'evaluator', 'subset', 'small-suite')
        Why = 'Small Haskell Wolfram clone with a dedicated test directory inside the mmaclone subproject.'
        LicenseOverride = 'BSD 3-Clause-style (repo LICENSE)'
    }
    [pscustomobject]@{
        Id = 'wolfram-codeparser'
        Repository = 'WolframResearch/codeparser'
        Url = 'https://github.com/WolframResearch/codeparser.git'
        Directories = @('Tests')
        Files = @()
        Focus = @('official-parser', 'syntax', 'precedence', 'trivia')
        Why = 'Official open-source Wolfram parser project with parser-correctness coverage.'
    }
)

$ExcludedCandidates = @()

function Assert-Tool([string] $Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' was not found on PATH."
    }
}

function Get-NormalizedFullPath([string] $PathValue) {
    return [System.IO.Path]::GetFullPath($PathValue)
}

function Assert-ChildPath([string] $RootPath, [string] $CandidatePath, [string] $Label) {
    $normalizedRoot = (Get-NormalizedFullPath $RootPath).TrimEnd('\')
    $normalizedCandidate = Get-NormalizedFullPath $CandidatePath
    $comparison = [System.StringComparison]::OrdinalIgnoreCase

    if ($normalizedCandidate.Equals($normalizedRoot, $comparison)) {
        return
    }

    if (-not $normalizedCandidate.StartsWith($normalizedRoot + '\', $comparison)) {
        throw "$Label path '$normalizedCandidate' is not under the expected root '$normalizedRoot'."
    }
}

function Get-DefaultBranch([string] $Url) {
    $symrefLines = @(git ls-remote --symref $Url HEAD 2>$null)
    foreach ($line in $symrefLines) {
        if ($line -match '^ref:\s+refs/heads/(?<branch>[^\s]+)\s+HEAD$') {
            return $Matches['branch']
        }
    }

    if ((git ls-remote --exit-code --heads $Url main 2>$null | Measure-Object).Count -gt 0) {
        return 'main'
    }

    if ((git ls-remote --exit-code --heads $Url master 2>$null | Measure-Object).Count -gt 0) {
        return 'master'
    }

    throw "Unable to determine the default branch for '$Url'."
}

function Try-GetGitHubMetadata([pscustomobject] $Entry) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $json = & gh repo view $Entry.Repository --json description,defaultBranchRef,licenseInfo,pushedAt,url 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
            return $null
        }

        $repo = $json | ConvertFrom-Json
        $license = $null
        if ($null -ne $repo.licenseInfo) {
            $license = if ($repo.licenseInfo.nickname) {
                $repo.licenseInfo.nickname
            }
            elseif ($repo.licenseInfo.name) {
                $repo.licenseInfo.name
            }
            else {
                $repo.licenseInfo.key
            }
        }

        return [pscustomobject]@{
            Description = $repo.description
            DefaultBranch = if ($repo.defaultBranchRef) { $repo.defaultBranchRef.name } else { $null }
            License = if ($Entry.PSObject.Properties.Name -contains 'LicenseOverride' -and $Entry.LicenseOverride) { $Entry.LicenseOverride } else { $license }
            PushedAt = $repo.pushedAt
            Url = $repo.url
        }
    }
    catch {
        return $null
    }
}

function Get-SparsePatterns([pscustomobject] $Entry) {
    $patterns = [System.Collections.Generic.List[string]]::new()
    foreach ($pattern in @(
        '/LICENSE*',
        '/license*',
        '/COPYING*',
        '/copying*',
        '/NOTICE*',
        '/notice*',
        '/README*',
        '/readme*'
    )) {
        [void] $patterns.Add($pattern)
    }

    foreach ($dir in $Entry.Directories) {
        $normalized = $dir.Trim('/')
        [void] $patterns.Add("/$normalized")
        [void] $patterns.Add("/$normalized/**")
    }

    foreach ($file in $Entry.Files) {
        $normalized = $file.Trim('/')
        [void] $patterns.Add("/$normalized")
    }

    return ,$patterns.ToArray()
}

function Get-DownloadedFiles([string] $RootPath) {
    return @(Get-ChildItem -LiteralPath $RootPath -Recurse -File | Where-Object {
        $_.FullName -notmatch '\\\.git(\\|$)'
    })
}

function Get-ExtensionHistogram([System.IO.FileInfo[]] $Files) {
    $histogram = [ordered]@{}
    foreach ($file in $Files) {
        $key = if ([string]::IsNullOrEmpty($file.Extension)) { '[none]' } else { $file.Extension.ToLowerInvariant() }
        if ($histogram.Contains($key)) {
            $histogram[$key] += 1
        }
        else {
            $histogram[$key] = 1
        }
    }

    return [pscustomobject] $histogram
}

function Get-SelectedPathStatuses([string] $SnapshotRoot, [pscustomobject] $Entry) {
    $statuses = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in $Entry.Directories) {
        $path = Join-Path $SnapshotRoot $dir
        $statuses.Add([pscustomobject]@{
            kind = 'directory'
            path = $dir
            exists = Test-Path -LiteralPath $path -PathType Container
        }) | Out-Null
    }

    foreach ($file in $Entry.Files) {
        $path = Join-Path $SnapshotRoot $file
        $statuses.Add([pscustomobject]@{
            kind = 'file'
            path = $file
            exists = Test-Path -LiteralPath $path -PathType Leaf
        }) | Out-Null
    }

    return $statuses.ToArray()
}

function Get-SnapshotMetadata(
    [pscustomobject] $Entry,
    [pscustomobject] $RepoMetadata,
    [string] $SnapshotRoot,
    [string] $Commit,
    [string] $DefaultBranch,
    [string] $Status
) {
    $files = Get-DownloadedFiles $SnapshotRoot
    return [pscustomobject]@{
        id = $Entry.Id
        repository = $Entry.Repository
        repoUrl = if ($RepoMetadata -and $RepoMetadata.Url) { $RepoMetadata.Url } else { $Entry.Url -replace '\.git$','' }
        description = if ($RepoMetadata -and $RepoMetadata.Description) { $RepoMetadata.Description } else { $null }
        defaultBranch = $DefaultBranch
        commit = $Commit
        license = if ($RepoMetadata -and $RepoMetadata.License) {
            $RepoMetadata.License
        }
        elseif ($Entry.PSObject.Properties.Name -contains 'LicenseOverride' -and $Entry.LicenseOverride) {
            $Entry.LicenseOverride
        }
        else {
            $null
        }
        pushedAt = if ($RepoMetadata -and $RepoMetadata.PushedAt) { $RepoMetadata.PushedAt } else { $null }
        snapshotPath = $SnapshotRoot
        status = $Status
        generatedUtc = [DateTime]::UtcNow.ToString('o')
        focus = @($Entry.Focus)
        why = $Entry.Why
        directories = @($Entry.Directories)
        files = @($Entry.Files)
        selectedPathStatuses = [object[]](Get-SelectedPathStatuses -SnapshotRoot $SnapshotRoot -Entry $Entry)
        fileCount = $files.Count
        fileCountByExtension = Get-ExtensionHistogram $files
    }
}

function Write-SnapshotMetadata([string] $SnapshotRoot, [pscustomobject] $Metadata) {
    $metadataPath = Join-Path $SnapshotRoot '.snapshot.json'
    $Metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
}

function Read-SnapshotMetadata([string] $SnapshotRoot) {
    $metadataPath = Join-Path $SnapshotRoot '.snapshot.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        return $null
    }

    return (Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json)
}

function Select-RepositoryEntries([pscustomobject[]] $Entries, [string[]] $Requested) {
    if (-not $Requested -or $Requested.Count -eq 0) {
        return ,$Entries
    }

    $requestedLookup = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Requested) {
        [void] $requestedLookup.Add($item)
    }

    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $Entries) {
        if ($requestedLookup.Contains($entry.Id) -or $requestedLookup.Contains($entry.Repository)) {
            $selected.Add($entry) | Out-Null
        }
    }

    if ($selected.Count -eq 0) {
        $available = ($Entries | ForEach-Object { $_.Id }) -join ', '
        throw "No curated repositories matched the requested selector(s). Available ids: $available"
    }

    return ,$selected.ToArray()
}

function New-CorpusReadme([string] $ManifestPath, [string] $OutDirPath, [pscustomobject[]] $Repositories, [pscustomobject[]] $Excluded) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Tungsten upstream Wolfram-language test corpus') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add("Generated (UTC): $([DateTime]::UtcNow.ToString('o'))") | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('This directory contains sparse snapshots of upstream Wolfram-language-adjacent parser, tokenizer, and evaluator test suites selected for Tungsten corpus mining.') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('Refresh command:') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('```powershell') | Out-Null
    $lines.Add('pwsh -File C:\Tools3\Tools\src\Tungsten\scripts\Acquire-TungstenWolframUpstreamTests.ps1 -Force') | Out-Null
    $lines.Add('```') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('Notes:') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('- Root `LICENSE*`/`COPYING*`/`README*` files are preserved when present.') | Out-Null
    $lines.Add('- Some suites are intended for corpus adaptation rather than direct execution from this sparse snapshot alone.') | Out-Null
    $lines.Add('- `expreduce` is intentionally wider than a pure test-folder snapshot because its Go tests live next to implementation files.') | Out-Null
    $lines.Add('- Copyleft licenses are present in this corpus. Reuse should respect each upstream license, especially if tests are copied into the repository later.') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('## Included repositories') | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('| Id | Repository | Commit | License | Focus | Selected paths |') | Out-Null
    $lines.Add('| --- | --- | --- | --- | --- | --- |') | Out-Null
    foreach ($repo in $Repositories) {
        $focus = ($repo.focus | ForEach-Object { $_ }) -join ', '
        $paths = (@($repo.directories) + @($repo.files)) -join ', '
        $license = if ($repo.license) { $repo.license } else { 'unknown' }
        $lines.Add('| ' + $repo.id + ' | `' + $repo.repository + '` | `' + $repo.commit + '` | ' + $license + ' | ' + $focus + ' | `' + $paths + '` |') | Out-Null
    }

    if ($Excluded.Count -gt 0) {
        $lines.Add('') | Out-Null
        $lines.Add('## Excluded candidates') | Out-Null
        $lines.Add('') | Out-Null
        foreach ($candidate in $Excluded) {
            $lines.Add('- `' + $candidate.Repository + '`: ' + $candidate.Reason) | Out-Null
        }
    }

    $lines.Add('') | Out-Null
    $lines.Add('Machine-readable manifest: `' + $ManifestPath + '`') | Out-Null
    $lines.Add('Corpus root: `' + $OutDirPath + '`') | Out-Null
    return ($lines -join [Environment]::NewLine)
}

Assert-Tool git

$selectedEntries = Select-RepositoryEntries -Entries $CuratedRepositories -Requested $Repository
$normalizedOutDir = Get-NormalizedFullPath $OutDir
New-Item -ItemType Directory -Force -Path $normalizedOutDir | Out-Null

$previousLfsSkipSmudge = $env:GIT_LFS_SKIP_SMUDGE
if (-not $FetchLfsContent) {
    $env:GIT_LFS_SKIP_SMUDGE = '1'
}
else {
    Remove-Item Env:GIT_LFS_SKIP_SMUDGE -ErrorAction SilentlyContinue
}

$manifestEntries = [System.Collections.Generic.List[object]]::new()

try {
    foreach ($entry in $selectedEntries) {
        $dest = Join-Path $normalizedOutDir $entry.Id
        $tmp = Join-Path $normalizedOutDir ($entry.Id + '.__tmp')
        Assert-ChildPath -RootPath $normalizedOutDir -CandidatePath $dest -Label 'Destination'
        Assert-ChildPath -RootPath $normalizedOutDir -CandidatePath $tmp -Label 'Temporary'

        Write-Host "==> $($entry.Id)"

        if (Test-Path -LiteralPath $dest) {
            if (-not $Force) {
                $existingMetadata = Read-SnapshotMetadata -SnapshotRoot $dest
                if ($null -ne $existingMetadata) {
                    Write-Host '    already present; keeping existing snapshot'
                    $manifestEntries.Add($existingMetadata) | Out-Null
                    continue
                }

                Write-Warning "Existing snapshot '$dest' has no .snapshot.json. Re-run with -Force to refresh it."
                continue
            }

            Remove-Item -LiteralPath $dest -Recurse -Force
        }

        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Recurse -Force
        }

        $repoMetadata = Try-GetGitHubMetadata -Entry $entry
        $defaultBranch = if ($repoMetadata -and $repoMetadata.DefaultBranch) {
            $repoMetadata.DefaultBranch
        }
        else {
            Get-DefaultBranch -Url $entry.Url
        }

        git clone --filter=blob:none --no-checkout --depth 1 --branch $defaultBranch $entry.Url $tmp | Out-Null

        Push-Location $tmp
        try {
            git config core.autocrlf false | Out-Null

            $patterns = Get-SparsePatterns -Entry $entry
            git sparse-checkout init --no-cone | Out-Null
            Set-Content -LiteralPath '.git/info/sparse-checkout' -Value $patterns -Encoding UTF8
            git checkout -f --quiet | Out-Null

            $commit = (git rev-parse HEAD).Trim()
            $metadata = Get-SnapshotMetadata -Entry $entry -RepoMetadata $repoMetadata -SnapshotRoot $tmp -Commit $commit -DefaultBranch $defaultBranch -Status 'downloaded'
            Write-SnapshotMetadata -SnapshotRoot $tmp -Metadata $metadata
        }
        finally {
            Pop-Location
        }

        $gitDir = Join-Path $tmp '.git'
        if (Test-Path -LiteralPath $gitDir) {
            Remove-Item -LiteralPath $gitDir -Recurse -Force
        }

        Move-Item -LiteralPath $tmp -Destination $dest
        $savedMetadata = Get-SnapshotMetadata -Entry $entry -RepoMetadata $repoMetadata -SnapshotRoot $dest -Commit $commit -DefaultBranch $defaultBranch -Status 'downloaded'
        Write-SnapshotMetadata -SnapshotRoot $dest -Metadata $savedMetadata
        if ($null -eq $savedMetadata) {
            throw "Snapshot metadata was not found after saving '$dest'."
        }

        $manifestEntries.Add($savedMetadata) | Out-Null
        Write-Host "    done -> $dest"
    }
}
finally {
    if ($null -ne $previousLfsSkipSmudge) {
        $env:GIT_LFS_SKIP_SMUDGE = $previousLfsSkipSmudge
    }
    else {
        Remove-Item Env:GIT_LFS_SKIP_SMUDGE -ErrorAction SilentlyContinue
    }
}

$manifestPath = Join-Path $normalizedOutDir 'manifest.json'
$summary = [pscustomobject]@{
    generatedUtc = [DateTime]::UtcNow.ToString('o')
    outDir = $normalizedOutDir
    repositoryCount = $manifestEntries.Count
    totalFileCount = (@($manifestEntries | Measure-Object -Property fileCount -Sum).Sum)
    repositories = @($manifestEntries)
    excludedCandidates = @($ExcludedCandidates)
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$readmePath = Join-Path $normalizedOutDir 'README.md'
$readme = New-CorpusReadme -ManifestPath $manifestPath -OutDirPath $normalizedOutDir -Repositories $summary.repositories -Excluded $ExcludedCandidates
Set-Content -LiteralPath $readmePath -Value $readme -Encoding UTF8

Write-Host ''
Write-Host "Wrote manifest: $manifestPath"
Write-Host "Wrote README:   $readmePath"
Write-Host "Corpus root:    $normalizedOutDir"
