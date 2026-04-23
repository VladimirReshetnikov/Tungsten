param(
    [switch] $IncludeFrontEnd,
    [switch] $UseWinDesk
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$previousPythonPath = $env:PYTHONPATH
$sourceRoot = Join-Path $projectRoot "src"
$separator = [System.IO.Path]::PathSeparator

try {
    $env:PYTHONPATH = if ([string]::IsNullOrWhiteSpace($previousPythonPath)) {
        $sourceRoot
    }
    else {
        "$sourceRoot$separator$previousPythonPath"
    }

    Push-Location $projectRoot
    try {
        python -m unittest discover -s tests -t .
        if ($LASTEXITCODE -ne 0) {
            throw "Python unit tests failed."
        }
    }
    finally {
        Pop-Location
    }

    Import-Module (Join-Path $projectRoot "pwsh\Tungsten.psd1") -Force

    $environment = Get-TungstenEnvironment -Probe
    if (-not $environment.probe.evaluation.evaluation_available) {
        throw "Kernel probe did not produce a structured result."
    }

    $evaluation = Invoke-TungstenKernel -Code "2+2" -RequireSuccess
    if ($evaluation.result -ne "4") {
        throw "Expected Tungsten evaluation result 4, got $($evaluation.result)."
    }

    $hits = Find-TungstenDocumentation -Query "NotebookGet" -Limit 3
    if ($null -eq $hits -or $hits.Count -lt 1) {
        throw "Documentation search did not return NotebookGet."
    }

    $tempNotebook = Join-Path $env:TEMP "tungsten-smoke.nb"
    $null = New-TungstenNotebook -Path $tempNotebook -Title "Tungsten Smoke" -Cell @(
        "Text:Hello from Tungsten",
        "Input:2+2"
    )

    $notebook = Get-TungstenNotebook -Path $tempNotebook
    if ($notebook.cell_count -lt 2) {
        throw "Expected at least 2 cells in the smoke notebook."
    }

    if ($IncludeFrontEnd) {
        $null = Open-TungstenNotebook -Path $tempNotebook -RequireSuccess
        $null = Open-TungstenDocumentation -Identifier "paclet:ref/NotebookGet" -RequireSuccess
        Start-Sleep -Seconds 2

        if ($UseWinDesk) {
            $repoRoot = Resolve-Path (Join-Path $projectRoot "..\..")
            $winDeskModule = Join-Path $repoRoot "src\WinDesk\src\WinDesk.PowerShell\bin\Debug\net10.0-windows\WinDesk.PowerShell.dll"
            if (Test-Path $winDeskModule) {
                Import-Module $winDeskModule -Force
                $window = Get-WinDeskWindow -VisibleOnly | Where-Object { $_.Title -like "*Wolfram*" } | Select-Object -First 1
                if ($null -ne $window) {
                    $capturePath = Join-Path $env:TEMP "tungsten-front-end-smoke.png"
                    Get-WinDeskScreenshot -WindowHandle $window.Handle -OutFile $capturePath | Out-Null
                    Write-Host "WinDesk capture written to $capturePath"
                }
                else {
                    Write-Host "WinDesk module is present, but no visible Wolfram window was found."
                }
            }
            else {
                Write-Host "Skipping WinDesk capture because the WinDesk PowerShell module has not been built yet."
            }
        }
    }

    Write-Host "Tungsten smoke passed."
}
finally {
    $env:PYTHONPATH = $previousPythonPath
}
