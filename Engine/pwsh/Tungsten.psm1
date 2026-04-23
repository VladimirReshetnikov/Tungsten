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

function Get-TungstenNotebookAssistantSelectorArguments {
    [CmdletBinding(DefaultParameterSetName = "CellIndex")]
    param(
        [Parameter(Mandatory)]
        [string] $ParameterSetName,

        [int] $CellIndex,

        [int[]] $CellPath,

        [string] $ExpressionUuid,

        [int] $CellId,

        [string] $CellTag
    )

    switch ($ParameterSetName) {
        "CellIndex" {
            return @("--cell-index", $CellIndex.ToString())
        }
        "CellPath" {
            return @("--cell-path", ($CellPath -join ","))
        }
        "ExpressionUuid" {
            return @("--expression-uuid", $ExpressionUuid)
        }
        "CellId" {
            return @("--cell-id", $CellId.ToString())
        }
        "CellTag" {
            return @("--cell-tag", $CellTag)
        }
        default {
            throw "Unsupported notebook assistant selector parameter set '$ParameterSetName'."
        }
    }
}

function New-TungstenNotebookAssistantFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ErrorType,

        [Parameter(Mandatory)]
        [string] $Message,

        [hashtable] $Extra = @{},

        $Evaluation
    )

    $assistant = [ordered]@{
        success = $false
        error_type = $ErrorType
        error = $Message
    }

    foreach ($key in $Extra.Keys) {
        $assistant[$key] = $Extra[$key]
    }

    [pscustomobject]@{
        assistant_success = $false
        assistant = [pscustomobject] $assistant
        evaluation = $Evaluation
    }
}

function Resolve-TungstenWinDeskModulePath {
    [CmdletBinding()]
    param(
        [switch] $BuildIfNeeded = $true
    )

    $repoRoot = Resolve-Path (Join-Path $script:ProjectRoot "..\..")
    $winDeskProjectRoot = Join-Path $repoRoot "src\WinDesk\src\WinDesk.PowerShell"
    $winDeskProjectFile = Join-Path $winDeskProjectRoot "WinDesk.PowerShell.csproj"

    $findModule = {
        @(Get-ChildItem -Path $winDeskProjectRoot -Recurse -Filter "WinDesk.PowerShell.dll" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "\\bin\\(Debug|Release)\\" } |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1)
    }

    $module = @(& $findModule)
    if ($module.Count -gt 0) {
        return $module[0].FullName
    }

    if (-not $BuildIfNeeded) {
        throw "WinDesk.PowerShell.dll was not found under $winDeskProjectRoot."
    }

    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $dotnet) {
        throw "dotnet was not found on PATH, so Tungsten cannot build the required WinDesk PowerShell module."
    }

    & $dotnet.Source build $winDeskProjectFile "-v" "minimal" "-p:UseSharedCompilation=false" "-m:1"
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed while building the WinDesk PowerShell module."
    }

    $module = @(& $findModule)
    if ($module.Count -eq 0) {
        throw "WinDesk.PowerShell.dll was still not found after building $winDeskProjectFile."
    }

    return $module[0].FullName
}

function Import-TungstenWinDeskModule {
    [CmdletBinding()]
    param(
        [switch] $BuildIfNeeded = $true
    )

    if ($null -ne (Get-Command Get-WinDeskWindow -ErrorAction SilentlyContinue)) {
        return
    }

    $modulePath = Resolve-TungstenWinDeskModulePath -BuildIfNeeded:$BuildIfNeeded
    Import-Module $modulePath -Force
}

function Wait-TungstenWinDeskWindowByTitle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Title,

        [int] $TimeoutMilliseconds = 10000,

        [int] $PollIntervalMilliseconds = 200
    )

    $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $matches = @(Get-WinDeskWindow -VisibleOnly | Where-Object { $_.Title -eq $Title })
        if ($matches.Count -gt 0) {
            return ($matches |
                Sort-Object `
                    @{ Expression = { [int] $_.IsForeground }; Descending = $true }, `
                    @{ Expression = { if ($null -eq $_.ZOrder) { [int]::MaxValue } else { [int] $_.ZOrder } }; Descending = $false } |
                Select-Object -First 1)
        }

        Start-Sleep -Milliseconds $PollIntervalMilliseconds
    }
    while ([DateTimeOffset]::UtcNow -lt $deadline)

    return $null
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

function Convert-TungstenExpression {
    [CmdletBinding(DefaultParameterSetName = "Code")]
    param(
        [Parameter(Mandatory, ParameterSetName = "Code")]
        [string] $Code,

        [Parameter(Mandatory, ParameterSetName = "File")]
        [string] $File,

        [ValidateSet("input", "fullform", "standard")]
        [string] $Form = "input"
    )

    $args = @("expr", "parse", "--form", $Form)
    if ($PSCmdlet.ParameterSetName -eq "Code") {
        $args += @("--code", $Code)
    }
    else {
        $args += @("--file", $File)
    }

    Invoke-TungstenCliJson -Arguments $args
}

function Invoke-TungstenExpression {
    [CmdletBinding(DefaultParameterSetName = "Code")]
    param(
        [Parameter(Mandatory, ParameterSetName = "Code")]
        [string] $Code,

        [Parameter(Mandatory, ParameterSetName = "File")]
        [string] $File,

        [ValidateSet("input", "fullform", "standard")]
        [string] $Form = "input"
    )

    $args = @("expr", "evaluate", "--form", $Form)
    if ($PSCmdlet.ParameterSetName -eq "Code") {
        $args += @("--code", $Code)
    }
    else {
        $args += @("--file", $File)
    }

    Invoke-TungstenCliJson -Arguments $args
}

function New-TungstenInlineBoxString {
    [CmdletBinding()]
    param(
        [string] $Prefix = "",

        [string[]] $BoxExpression = @(),

        [string] $Suffix = ""
    )

    $args = @("inline-box", "compose")
    if ($Prefix -ne "") {
        $args += @("--prefix", $Prefix)
    }
    foreach ($expression in $BoxExpression) {
        $args += @("--box-expr", $expression)
    }
    if ($Suffix -ne "") {
        $args += @("--suffix", $Suffix)
    }

    Invoke-TungstenCliJson -Arguments $args
}

function Get-TungstenNotebookCellInlineBoxes {
    [CmdletBinding(DefaultParameterSetName = "CellIndex")]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory, ParameterSetName = "CellIndex")]
        [int] $CellIndex,

        [Parameter(Mandatory, ParameterSetName = "CellPath")]
        [int[]] $CellPath,

        [Parameter(Mandatory, ParameterSetName = "ExpressionUuid")]
        [string] $ExpressionUuid,

        [Parameter(Mandatory, ParameterSetName = "CellId")]
        [int] $CellId,

        [Parameter(Mandatory, ParameterSetName = "CellTag")]
        [string] $CellTag,

        [string] $Prefix = "",

        [string] $Suffix = "",

        [ValidateRange(0, 2147483647)]
        [int] $ObjectIndex = 0,

        [switch] $AllObjects,

        [switch] $RequireSuccess
    )

    $selectorArgs = Get-TungstenNotebookAssistantSelectorArguments `
        -ParameterSetName $PSCmdlet.ParameterSetName `
        -CellIndex $CellIndex `
        -CellPath $CellPath `
        -ExpressionUuid $ExpressionUuid `
        -CellId $CellId `
        -CellTag $CellTag

    $args = @("inline-box", "from-cell", "--file", $Path) + $selectorArgs
    if ($Prefix -ne "") {
        $args += @("--prefix", $Prefix)
    }
    if ($Suffix -ne "") {
        $args += @("--suffix", $Suffix)
    }
    if ($AllObjects) {
        $args += "--all-objects"
    }
    else {
        $args += @("--object-index", $ObjectIndex.ToString())
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

function Invoke-TungstenNotebookAssistant {
    [CmdletBinding(DefaultParameterSetName = "CellIndex")]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Question,

        [Parameter(Mandatory, ParameterSetName = "CellIndex")]
        [int] $CellIndex,

        [Parameter(Mandatory, ParameterSetName = "CellPath")]
        [int[]] $CellPath,

        [Parameter(Mandatory, ParameterSetName = "ExpressionUuid")]
        [string] $ExpressionUuid,

        [Parameter(Mandatory, ParameterSetName = "CellId")]
        [int] $CellId,

        [Parameter(Mandatory, ParameterSetName = "CellTag")]
        [string] $CellTag,

        [switch] $InsertWolframCodeBelow,

        [switch] $InsertAllWolframCodeBelow,

        [switch] $Save,

        [switch] $CloseAssistantNotebook,

        [string] $ExtraInstructions,

        [string] $ModelService,

        [string] $ModelName,

        [ValidateSet("NotebookChatCell", "DesktopInline", "KernelWindow")]
        [string] $Backend = "NotebookChatCell",

        [ValidateSet("ClipboardPaste", "Keyboard")]
        [string] $InputMethod = "ClipboardPaste",

        [ValidateRange(1000, 900000)]
        [int] $TimeoutMilliseconds = 180000,

        [ValidateRange(100, 60000)]
        [int] $PollIntervalMilliseconds = 1500,

        [switch] $RequireSuccess
    )

    $selectorArgs = Get-TungstenNotebookAssistantSelectorArguments `
        -ParameterSetName $PSCmdlet.ParameterSetName `
        -CellIndex $CellIndex `
        -CellPath $CellPath `
        -ExpressionUuid $ExpressionUuid `
        -CellId $CellId `
        -CellTag $CellTag

    if ($Backend -in @("NotebookChatCell", "KernelWindow")) {
        $args = @("assistant", "ask-cell", "--file", $Path, "--question", $Question) + $selectorArgs

        if ($InsertWolframCodeBelow) {
            $args += "--insert-wolfram-code-below"
        }
        if ($InsertAllWolframCodeBelow) {
            $args += "--insert-all-wolfram-code-below"
        }
        if ($Save) {
            $args += "--save"
        }
        if ($CloseAssistantNotebook) {
            $args += "--close-assistant-notebook"
        }
        if ($ExtraInstructions) {
            $args += @("--extra-instructions", $ExtraInstructions)
        }
        if ($ModelService) {
            $args += @("--model-service", $ModelService)
        }
        if ($ModelName) {
            $args += @("--model-name", $ModelName)
        }
        if ($RequireSuccess) {
            $args += "--require-success"
        }

        return Invoke-TungstenCliJson -Arguments $args -AllowFailure:$RequireSuccess
    }

    if ($CloseAssistantNotebook) {
        return New-TungstenNotebookAssistantFailure `
            -ErrorType "UnsupportedDesktopInlineOption" `
            -Message "DesktopInline backend does not use a separate assistant notebook, so -CloseAssistantNotebook is not applicable." `
            -Extra @{
                backend = $Backend
                notebook_path = $Path
            }
    }

    if ($ExtraInstructions -or $ModelService -or $ModelName) {
        return New-TungstenNotebookAssistantFailure `
            -ErrorType "UnsupportedDesktopInlineOption" `
            -Message "DesktopInline backend currently drives the built-in inline Notebook Assistant UI and does not yet support -ExtraInstructions, -ModelService, or -ModelName overrides." `
            -Extra @{
                backend = $Backend
                notebook_path = $Path
            }
    }

    $prepare = $null
    $lastCapture = $null

    try {
        $prepare = Invoke-TungstenCliJson -Arguments (@("assistant", "prepare-inline", "--file", $Path) + $selectorArgs)
        if ($null -eq $prepare) {
            return New-TungstenNotebookAssistantFailure `
                -ErrorType "InlineAssistantPrepareFailed" `
                -Message "prepare-inline did not return a payload." `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                }
        }

        if (-not $prepare.assistant_success) {
            return $prepare
        }

        $windowTitle = [string] $prepare.assistant.window_title
        if ([string]::IsNullOrWhiteSpace($windowTitle)) {
            return New-TungstenNotebookAssistantFailure `
                -ErrorType "NotebookWindowTitleUnavailable" `
                -Message "Tungsten opened the inline assistant, but the source notebook did not report a usable window title." `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                    prepare = $prepare.assistant
                } `
                -Evaluation $prepare.evaluation
        }

        Import-TungstenWinDeskModule

        $window = Wait-TungstenWinDeskWindowByTitle -Title $windowTitle -TimeoutMilliseconds ([Math]::Min($TimeoutMilliseconds, 15000))
        if ($null -eq $window) {
            return New-TungstenNotebookAssistantFailure `
                -ErrorType "NotebookWindowNotVisible" `
                -Message "The notebook window '$windowTitle' was not visible to WinDesk." `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                    window_title = $windowTitle
                    prepare = $prepare.assistant
                } `
                -Evaluation $prepare.evaluation
        }

        if ($window.IsMinimized) {
            $restore = Set-WinDeskWindowState -Handle $window.Handle -State Restore
            if (-not $restore.Succeeded) {
                return New-TungstenNotebookAssistantFailure `
                    -ErrorType "NotebookWindowRestoreFailed" `
                    -Message ($restore.Summary ?? "Unable to restore the notebook window before driving inline assistant input.") `
                    -Extra @{
                        backend = $Backend
                        notebook_path = $Path
                        window_title = $windowTitle
                        window_handle = $window.Handle
                        windesk = $restore
                    } `
                    -Evaluation $prepare.evaluation
            }

            Start-Sleep -Milliseconds 250
            $window = Get-WinDeskWindow -Handle $window.Handle | Select-Object -First 1
        }

        $activation = Set-WinDeskForegroundWindow -Handle $window.Handle
        if (-not $activation.Succeeded) {
            return New-TungstenNotebookAssistantFailure `
                -ErrorType "NotebookWindowActivationFailed" `
                -Message ($activation.Summary ?? "WinDesk could not activate the notebook window.") `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                    window_title = $windowTitle
                    window_handle = $window.Handle
                    windesk = $activation
                } `
                -Evaluation $prepare.evaluation
        }

        Start-Sleep -Milliseconds 250
        $window = Get-WinDeskWindow -Handle $window.Handle | Select-Object -First 1
        if ($null -eq $window -or -not $window.IsForeground) {
            $currentWindowHandle = $null
            if ($null -ne $window) {
                $currentWindowHandle = $window.Handle
            }

            return New-TungstenNotebookAssistantFailure `
                -ErrorType "NotebookWindowNotForeground" `
                -Message "The notebook window could not be confirmed as the foreground window, so Tungsten refused to inject input into the desktop." `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                    window_title = $windowTitle
                    window_handle = $currentWindowHandle
                } `
                -Evaluation $prepare.evaluation
        }

        $textResult = Send-WinDeskText -Text $Question -Method $InputMethod -ExpectedForegroundWindowHandle $window.Handle
        if (-not $textResult.Succeeded) {
            return New-TungstenNotebookAssistantFailure `
                -ErrorType "InlineAssistantTextInjectionFailed" `
                -Message ($textResult.Summary ?? "WinDesk could not send the assistant question.") `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                    window_title = $windowTitle
                    window_handle = $window.Handle
                    windesk = $textResult
                } `
                -Evaluation $prepare.evaluation
        }

        $enterResult = Send-WinDeskKeys -Gesture Enter -ExpectedForegroundWindowHandle $window.Handle
        if (-not $enterResult.Succeeded) {
            return New-TungstenNotebookAssistantFailure `
                -ErrorType "InlineAssistantSubmitFailed" `
                -Message ($enterResult.Summary ?? "WinDesk could not submit the assistant question.") `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                    window_title = $windowTitle
                    window_handle = $window.Handle
                    windesk = $enterResult
                } `
                -Evaluation $prepare.evaluation
        }

        $captureArgs = @("assistant", "capture-inline", "--file", $Path) + $selectorArgs
        $deadline = [DateTimeOffset]::UtcNow.AddMilliseconds($TimeoutMilliseconds)

        do {
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
            $lastCapture = Invoke-TungstenCliJson -Arguments $captureArgs
            if ($null -eq $lastCapture) {
                return New-TungstenNotebookAssistantFailure `
                    -ErrorType "InlineAssistantCaptureFailed" `
                    -Message "capture-inline did not return a payload while waiting for the inline assistant response." `
                    -Extra @{
                        backend = $Backend
                        notebook_path = $Path
                        window_title = $windowTitle
                        window_handle = $window.Handle
                    } `
                    -Evaluation $prepare.evaluation
            }

            if (-not $lastCapture.assistant_success) {
                return $lastCapture
            }
        }
        while (-not $lastCapture.assistant.completed -and [DateTimeOffset]::UtcNow -lt $deadline)

        if (-not $lastCapture.assistant.completed) {
            return New-TungstenNotebookAssistantFailure `
                -ErrorType "InlineAssistantTimedOut" `
                -Message "The inline Notebook Assistant did not finish before the configured timeout elapsed." `
                -Extra @{
                    backend = $Backend
                    notebook_path = $Path
                    window_title = $windowTitle
                    window_handle = $window.Handle
                    prepare = $prepare.assistant
                    last_capture = $lastCapture.assistant
                } `
                -Evaluation $lastCapture.evaluation
        }

        $final = $lastCapture
        if ($InsertWolframCodeBelow -or $InsertAllWolframCodeBelow -or $Save) {
            $finalArgs = @($captureArgs)
            if ($InsertWolframCodeBelow) {
                $finalArgs += "--insert-wolfram-code-below"
            }
            if ($InsertAllWolframCodeBelow) {
                $finalArgs += "--insert-all-wolfram-code-below"
            }
            if ($Save) {
                $finalArgs += "--save"
            }

            $final = Invoke-TungstenCliJson -Arguments $finalArgs
            if ($null -eq $final) {
                return New-TungstenNotebookAssistantFailure `
                    -ErrorType "InlineAssistantFinalizeFailed" `
                    -Message "capture-inline did not return a payload during the final insert/save step." `
                    -Extra @{
                        backend = $Backend
                        notebook_path = $Path
                        window_title = $windowTitle
                        window_handle = $window.Handle
                    } `
                    -Evaluation $lastCapture.evaluation
            }

            if (-not $final.assistant_success) {
                return $final
            }
        }

        $desktopAutomation = [pscustomobject]@{
            backend = $Backend
            input_method = $InputMethod
            timeout_milliseconds = $TimeoutMilliseconds
            poll_interval_milliseconds = $PollIntervalMilliseconds
            window_title = $windowTitle
            window_handle = $window.Handle
        }
        $final.assistant | Add-Member -NotePropertyName "desktop_automation" -NotePropertyValue $desktopAutomation -Force
        return $final
    }
    catch {
        $preparePayload = $null
        if ($null -ne $prepare) {
            $preparePayload = $prepare.assistant
        }

        $lastCapturePayload = $null
        if ($null -ne $lastCapture) {
            $lastCapturePayload = $lastCapture.assistant
        }

        $evaluation = $null
        if ($null -ne $lastCapture) {
            $evaluation = $lastCapture.evaluation
        }
        elseif ($null -ne $prepare) {
            $evaluation = $prepare.evaluation
        }

        return New-TungstenNotebookAssistantFailure `
            -ErrorType "DesktopInlineAutomationFailed" `
            -Message $_.Exception.Message `
            -Extra @{
                backend = $Backend
                notebook_path = $Path
                prepare = $preparePayload
                last_capture = $lastCapturePayload
            } `
            -Evaluation $evaluation
    }
}

Export-ModuleMember -Function @(
    "Convert-TungstenExpression",
    "Find-TungstenDocumentation",
    "Get-TungstenDocumentationPage",
    "Get-TungstenEnvironment",
    "Get-TungstenNotebook",
    "Get-TungstenNotebookCellInlineBoxes",
    "Invoke-TungstenFrontEnd",
    "Invoke-TungstenKernel",
    "Invoke-TungstenNotebookAssistant",
    "Invoke-TungstenExpression",
    "New-TungstenInlineBoxString",
    "New-TungstenNotebook",
    "Open-TungstenDocumentation",
    "Open-TungstenNotebook",
    "Set-TungstenNotebook"
)
