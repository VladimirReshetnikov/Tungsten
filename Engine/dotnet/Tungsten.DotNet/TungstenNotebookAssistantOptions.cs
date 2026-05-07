namespace Tungsten.DotNet;

/// <summary>
/// Configures an <c>assistant ask-cell</c> request.
/// </summary>
public sealed record TungstenNotebookAssistantAskOptions
{
    /// <summary>
    /// Gets the notebook file path.
    /// </summary>
    public required string NotebookPath { get; init; }

    /// <summary>
    /// Gets the target notebook cell selector.
    /// </summary>
    public required TungstenNotebookCellSelector CellSelector { get; init; }

    /// <summary>
    /// Gets the natural-language question to send to Notebook Assistant.
    /// </summary>
    public required string Question { get; init; }

    /// <summary>
    /// Gets a value indicating whether Tungsten should insert the first Wolfram Language code block below the source cell.
    /// </summary>
    public bool InsertWolframCodeBelow { get; init; }

    /// <summary>
    /// Gets a value indicating whether Tungsten should insert every Wolfram Language code block below the source cell.
    /// </summary>
    public bool InsertAllWolframCodeBelow { get; init; }

    /// <summary>
    /// Gets a value indicating whether Tungsten should save the notebook after inserting code.
    /// </summary>
    public bool Save { get; init; }

    /// <summary>
    /// Gets a value indicating whether Tungsten should close the temporary assistant notebook when the request finishes.
    /// </summary>
    public bool CloseAssistantNotebook { get; init; }

    /// <summary>
    /// Gets additional instructions appended to Tungsten's assistant prompt.
    /// </summary>
    public string? ExtraInstructions { get; init; }

    /// <summary>
    /// Gets the optional assistant service override.
    /// </summary>
    public string? ModelService { get; init; }

    /// <summary>
    /// Gets the optional assistant model-name override.
    /// </summary>
    public string? ModelName { get; init; }

    /// <summary>
    /// Gets a value indicating whether Tungsten should treat assistant-reported failure as a command failure.
    /// </summary>
    public bool RequireSuccess { get; init; }

    internal void AppendArguments(ICollection<string> arguments)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        ArgumentException.ThrowIfNullOrWhiteSpace(NotebookPath);
        ArgumentNullException.ThrowIfNull(CellSelector);
        ArgumentException.ThrowIfNullOrWhiteSpace(Question);

        arguments.Add("assistant");
        arguments.Add("ask-cell");
        arguments.Add("--file");
        arguments.Add(NotebookPath);
        CellSelector.AppendArguments(arguments);
        arguments.Add("--question");
        arguments.Add(Question);

        if (InsertWolframCodeBelow)
        {
            arguments.Add("--insert-wolfram-code-below");
        }

        if (InsertAllWolframCodeBelow)
        {
            arguments.Add("--insert-all-wolfram-code-below");
        }

        if (Save)
        {
            arguments.Add("--save");
        }

        if (CloseAssistantNotebook)
        {
            arguments.Add("--close-assistant-notebook");
        }

        if (!string.IsNullOrWhiteSpace(ExtraInstructions))
        {
            arguments.Add("--extra-instructions");
            arguments.Add(ExtraInstructions);
        }

        if (!string.IsNullOrWhiteSpace(ModelService))
        {
            arguments.Add("--model-service");
            arguments.Add(ModelService);
        }

        if (!string.IsNullOrWhiteSpace(ModelName))
        {
            arguments.Add("--model-name");
            arguments.Add(ModelName);
        }

        if (RequireSuccess)
        {
            arguments.Add("--require-success");
        }
    }
}

/// <summary>
/// Configures an <c>assistant capture-inline</c> request.
/// </summary>
public sealed record TungstenNotebookAssistantCaptureOptions
{
    /// <summary>
    /// Gets the notebook file path.
    /// </summary>
    public required string NotebookPath { get; init; }

    /// <summary>
    /// Gets the target notebook cell selector.
    /// </summary>
    public required TungstenNotebookCellSelector CellSelector { get; init; }

    /// <summary>
    /// Gets a value indicating whether Tungsten should insert the first Wolfram Language code block below the source cell.
    /// </summary>
    public bool InsertWolframCodeBelow { get; init; }

    /// <summary>
    /// Gets a value indicating whether Tungsten should insert every Wolfram Language code block below the source cell.
    /// </summary>
    public bool InsertAllWolframCodeBelow { get; init; }

    /// <summary>
    /// Gets a value indicating whether Tungsten should save the notebook after inserting code.
    /// </summary>
    public bool Save { get; init; }

    /// <summary>
    /// Gets a value indicating whether Tungsten should treat assistant-reported failure as a command failure.
    /// </summary>
    public bool RequireSuccess { get; init; }

    internal void AppendArguments(ICollection<string> arguments)
    {
        ArgumentNullException.ThrowIfNull(arguments);
        ArgumentException.ThrowIfNullOrWhiteSpace(NotebookPath);
        ArgumentNullException.ThrowIfNull(CellSelector);

        arguments.Add("assistant");
        arguments.Add("capture-inline");
        arguments.Add("--file");
        arguments.Add(NotebookPath);
        CellSelector.AppendArguments(arguments);

        if (InsertWolframCodeBelow)
        {
            arguments.Add("--insert-wolfram-code-below");
        }

        if (InsertAllWolframCodeBelow)
        {
            arguments.Add("--insert-all-wolfram-code-below");
        }

        if (Save)
        {
            arguments.Add("--save");
        }

        if (RequireSuccess)
        {
            arguments.Add("--require-success");
        }
    }
}
