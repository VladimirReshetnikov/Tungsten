<#
.SYNOPSIS
Tungsten wrapper around the shared Scriptorium Update-DocsProvenance tool.

.DESCRIPTION
Thin product-specific wrapper: targets the Tungsten project's README.md and docs/ tree and
forwards to the canonical provenance-header updater at Scriptorium repo\Update-DocsProvenance.ps1
(see C:\Scriptorium\TOOLS.md). The header spellings ('Created (UTC):', 'Updated (UTC):',
'Repository HEAD:') are the cross-repo convention maintained by the canonical tool.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $IncludeReports
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptoriumRoot =
    @($env:SCRIPTORIUM, (Join-Path $PSScriptRoot '..\..\..\..\Scriptorium'), 'C:\Scriptorium') |
    Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
    Select-Object -First 1
if (-not $scriptoriumRoot) {
    throw 'Scriptorium toolbox not found (set $env:SCRIPTORIUM or clone it beside this repository).'
}

$tungstenRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

& (Join-Path $scriptoriumRoot 'repo\Update-DocsProvenance.ps1') `
    -Path @((Join-Path $tungstenRoot 'README.md'), (Join-Path $tungstenRoot 'docs')) `
    -IncludeReports:$IncludeReports `
    -WhatIf:$WhatIfPreference
