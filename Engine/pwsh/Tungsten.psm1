Set-StrictMode -Version Latest

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot

function Invoke-TungstenCliJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [switch] $AllowFailure
    )

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) {
        throw "python was not found on PATH."
    }

    $previousPythonPath = $env:PYTHONPATH
    $sourceRoot = Join-Path $script:ProjectRoot "src"
    $separator = [System.IO.Path]::PathSeparator
    $env:PYTHONPATH = if ([string]::IsNullOrWhiteSpace($previousPythonPath)) {
        $sourceRoot
    }
    else {
        "$sourceRoot$separator$previousPythonPath"
    }

    try {
        $output = & $python.Source -m tungsten @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $env:PYTHONPATH = $previousPythonPath
    }

    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "Tungsten CLI failed with exit code $exitCode.`n$($output -join [Environment]::NewLine)"
    }

    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text | ConvertFrom-Json -Depth 100
}

function Get-TungstenEnvironment {
    [CmdletBinding()]
    param(
        [switch] $Probe
    )

    $args = @("env", "show")
    if ($Probe) {
        $args += "--probe"
    }

    Invoke-TungstenCliJson -Arguments $args
}

function Invoke-TungstenKernel {
    [CmdletBinding(DefaultParameterSetName = "Code")]
    param(
        [Parameter(Mandatory, ParameterSetName = "Code")]
        [string] $Code,

        [Parameter(Mandatory, ParameterSetName = "File")]
        [string] $File,

        [string] $WorkingDirectory,

        [switch] $FrontEnd,

        [switch] $RequireSuccess
    )

    $args = @("kernel", "eval")
    if ($PSCmdlet.ParameterSetName -eq "Code") {
        $args += @("--code", $Code)
    }
    else {
        $args += @("--file", $File)
    }

    if ($WorkingDirectory) {
        $args += @("--working-directory", $WorkingDirectory)
    }

    if ($FrontEnd) {
        $args += "--front-end"
    }

    if ($RequireSuccess) {
        $args += "--require-success"
    }

    Invoke-TungstenCliJson -Arguments $args -AllowFailure:$RequireSuccess
}

function Get-TungstenNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    Invoke-TungstenCliJson -Arguments @("notebook", "inspect", "--file", $Path)
}

function New-TungstenNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $Title,

        [string[]] $Cell = @()
    )

    $args = @("notebook", "create", "--file", $Path)
    if ($Title) {
        $args += @("--title", $Title)
    }
    foreach ($entry in $Cell) {
        $args += @("--cell", $entry)
    }

    Invoke-TungstenCliJson -Arguments $args
}

function Set-TungstenNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Spec,

        [string] $OutFile
    )

    $args = @("notebook", "patch", "--file", $Path, "--spec", $Spec)
    if ($OutFile) {
        $args += @("--out", $OutFile)
    }

    Invoke-TungstenCliJson -Arguments $args
}

function Find-TungstenDocumentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Query,

        [int] $Limit = 10,

        [string] $IndexPath,

        [switch] $Rebuild
    )

    $args = @("docs", "search", $Query, "--limit", $Limit.ToString())
    if ($IndexPath) {
        $args += @("--index-path", $IndexPath)
    }
    if ($Rebuild) {
        $args += "--rebuild"
    }

    $payload = Invoke-TungstenCliJson -Arguments $args
    return $payload.hits
}

function Get-TungstenDocumentationPage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Identifier,

        [string] $IndexPath,

        [switch] $Rebuild
    )

    $args = @("docs", "read", $Identifier)
    if ($IndexPath) {
        $args += @("--index-path", $IndexPath)
    }
    if ($Rebuild) {
        $args += "--rebuild"
    }

    Invoke-TungstenCliJson -Arguments $args
}

function Open-TungstenDocumentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Identifier,

        [string] $IndexPath,

        [switch] $RequireSuccess
    )

    $args = @("frontend", "open-doc", $Identifier)
    if ($IndexPath) {
        $args += @("--index-path", $IndexPath)
    }
    if ($RequireSuccess) {
        $args += "--require-success"
    }

    Invoke-TungstenCliJson -Arguments $args -AllowFailure:$RequireSuccess
}

function Open-TungstenNotebook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [switch] $RequireSuccess
    )

    $args = @("frontend", "open-notebook", "--file", $Path)
    if ($RequireSuccess) {
        $args += "--require-success"
    }

    Invoke-TungstenCliJson -Arguments $args -AllowFailure:$RequireSuccess
}

function Invoke-TungstenFrontEnd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Code,

        [switch] $NoWrap,

        [switch] $RequireSuccess
    )

    $args = @("frontend", "run", "--code", $Code)
    if ($NoWrap) {
        $args += "--no-wrap"
    }
    if ($RequireSuccess) {
        $args += "--require-success"
    }

    Invoke-TungstenCliJson -Arguments $args -AllowFailure:$RequireSuccess
}

Export-ModuleMember -Function @(
    "Find-TungstenDocumentation",
    "Get-TungstenDocumentationPage",
    "Get-TungstenEnvironment",
    "Get-TungstenNotebook",
    "Invoke-TungstenFrontEnd",
    "Invoke-TungstenKernel",
    "New-TungstenNotebook",
    "Open-TungstenDocumentation",
    "Open-TungstenNotebook",
    "Set-TungstenNotebook"
)
