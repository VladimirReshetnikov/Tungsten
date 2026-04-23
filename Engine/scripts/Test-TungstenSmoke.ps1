param(
    [switch] $IncludeFrontEnd,
    [switch] $UseWinDesk,
    [switch] $IncludeAssistant
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

    $parsedExpression = Convert-TungstenExpression -Code "1 + 2 x^3"
    if ($parsedExpression.full_form -ne "Plus[1, Times[2, Power[x, 3]]]") {
        throw "Expression parse smoke returned unexpected FullForm: $($parsedExpression.full_form)"
    }

    $evaluatedExpression = Invoke-TungstenExpression -Code "Level[f[a, g[b]], -1]"
    if ($evaluatedExpression.result.full_form -ne "List[a, b]") {
        throw "Expression evaluation smoke returned unexpected result: $($evaluatedExpression.result.full_form)"
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

    if ($IncludeAssistant) {
        $assistant = Invoke-TungstenNotebookAssistant `
            -Path $tempNotebook `
            -CellIndex 1 `
            -Question "Reply only with Wolfram Language code that computes 2+2." `
            -InsertWolframCodeBelow `
            -Save

        if (-not $assistant.assistant_success) {
            throw "Notebook Assistant smoke failed: $($assistant.assistant.error_type) $($assistant.assistant.error)"
        }

        if ($assistant.assistant.inserted.Count -lt 1) {
            throw "Notebook Assistant smoke did not insert a Wolfram Language code cell."
        }

        $assistantNotebook = Get-TungstenNotebook -Path $tempNotebook
        if ($assistantNotebook.cell_count -lt 3) {
            throw "Notebook Assistant smoke expected at least 3 cells after insertion."
        }
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
