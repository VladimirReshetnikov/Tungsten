using System.Text.Json;
using System.Text.Json.Serialization;

namespace Tungsten.DotNet;

/// <summary>
/// Describes the discovered Tungsten/Wolfram environment.
/// </summary>
public sealed record TungstenEnvironmentResponse
{
    [JsonPropertyName("product")]
    public string? Product { get; init; }

    [JsonPropertyName("product_family")]
    public string? ProductFamily { get; init; }

    [JsonPropertyName("version")]
    public string? Version { get; init; }

    [JsonPropertyName("install_dir")]
    public string? InstallDir { get; init; }

    [JsonPropertyName("kernel_cli")]
    public string? KernelCli { get; init; }

    [JsonPropertyName("kernel_executable")]
    public string? KernelExecutable { get; init; }

    [JsonPropertyName("frontend_executable")]
    public string? FrontEndExecutable { get; init; }

    [JsonPropertyName("wolframscript")]
    public string? WolframScript { get; init; }

    [JsonPropertyName("mathpass")]
    public string? Mathpass { get; init; }

    [JsonPropertyName("docs_roots")]
    public string[] DocsRoots { get; init; } = [];

    [JsonPropertyName("bundled_python_client")]
    public string? BundledPythonClient { get; init; }

    [JsonPropertyName("default_index_path")]
    public string? DefaultIndexPath { get; init; }

    [JsonPropertyName("user_base")]
    public string? UserBase { get; init; }

    [JsonPropertyName("system_base")]
    public string? SystemBase { get; init; }

    [JsonPropertyName("mathpass_candidates")]
    public string[] MathpassCandidates { get; init; } = [];

    [JsonPropertyName("available_installations")]
    public TungstenInstallationSummary[] AvailableInstallations { get; init; } = [];

    [JsonPropertyName("selection_reason")]
    public string? SelectionReason { get; init; }

    [JsonPropertyName("probe")]
    public JsonElement Probe { get; init; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes one local Wolfram product/version discovered by Tungsten.
/// </summary>
public sealed record TungstenInstallationSummary
{
    [JsonPropertyName("product")]
    public string? Product { get; init; }

    [JsonPropertyName("product_family")]
    public string? ProductFamily { get; init; }

    [JsonPropertyName("version")]
    public string? Version { get; init; }

    [JsonPropertyName("install_dir")]
    public string? InstallDir { get; init; }

    [JsonPropertyName("kernel_cli")]
    public string? KernelCli { get; init; }

    [JsonPropertyName("wolframscript")]
    public string? WolframScript { get; init; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes Tungsten's mathpass inspection payload.
/// </summary>
public sealed record TungstenMathpassInspection
{
    [JsonPropertyName("path")]
    public string? Path { get; init; }

    [JsonPropertyName("header_present")]
    public bool HeaderPresent { get; init; }

    [JsonPropertyName("original_line_count")]
    public int OriginalLineCount { get; init; }

    [JsonPropertyName("unique_entry_count")]
    public int UniqueEntryCount { get; init; }

    [JsonPropertyName("duplicate_entry_count")]
    public int DuplicateEntryCount { get; init; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes a kernel-backed Tungsten evaluation.
/// </summary>
public sealed record TungstenKernelEvaluationResponse
{
    [JsonPropertyName("command")]
    public string[] Command { get; init; } = [];

    [JsonPropertyName("exit_code")]
    public int ExitCode { get; init; }

    [JsonPropertyName("success")]
    public bool? Success { get; init; }

    [JsonPropertyName("failure_type")]
    public string? FailureType { get; init; }

    [JsonPropertyName("result")]
    public string? Result { get; init; }

    [JsonPropertyName("result_head")]
    public string? ResultHead { get; init; }

    [JsonPropertyName("messages")]
    public string[] Messages { get; init; } = [];

    [JsonPropertyName("messages_text")]
    public string[] MessagesText { get; init; } = [];

    [JsonPropertyName("output")]
    public string[] Output { get; init; } = [];

    [JsonPropertyName("timing")]
    public double? Timing { get; init; }

    [JsonPropertyName("absolute_timing")]
    public double? AbsoluteTiming { get; init; }

    [JsonPropertyName("stdout")]
    public string? StandardOutput { get; init; }

    [JsonPropertyName("stderr")]
    public string? StandardError { get; init; }

    [JsonPropertyName("json_path")]
    public string? JsonPath { get; init; }

    [JsonPropertyName("evaluation_available")]
    public bool EvaluationAvailable { get; init; }

    [JsonPropertyName("mathpass")]
    public TungstenMathpassInspection? Mathpass { get; init; }

    [JsonPropertyName("used_mathpass_workaround")]
    public bool UsedMathpassWorkaround { get; init; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes a notebook cell summary returned by Tungsten notebook commands.
/// </summary>
public sealed record TungstenNotebookCellSummary
{
    [JsonPropertyName("index")]
    public int? Index { get; init; }

    [JsonPropertyName("kind")]
    public string? Kind { get; init; }

    [JsonPropertyName("path")]
    public int[] Path { get; init; } = [];

    [JsonPropertyName("depth")]
    public int Depth { get; init; }

    [JsonPropertyName("style")]
    public string? Style { get; init; }

    [JsonPropertyName("preview")]
    public string? Preview { get; init; }

    [JsonPropertyName("cell_id")]
    public int? CellId { get; init; }

    [JsonPropertyName("expression_uuid")]
    public string? ExpressionUuid { get; init; }

    [JsonPropertyName("cell_tags")]
    public string[] CellTags { get; init; } = [];

    [JsonPropertyName("options")]
    public string[] Options { get; init; } = [];

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes a notebook document summary returned by Tungsten notebook commands.
/// </summary>
public sealed record TungstenNotebookDocumentResponse
{
    [JsonPropertyName("path")]
    public string? Path { get; init; }

    [JsonPropertyName("title")]
    public string? Title { get; init; }

    [JsonPropertyName("cell_count")]
    public int CellCount { get; init; }

    [JsonPropertyName("group_count")]
    public int GroupCount { get; init; }

    [JsonPropertyName("options")]
    public string[] Options { get; init; } = [];

    [JsonPropertyName("cells")]
    public TungstenNotebookCellSummary[] Cells { get; init; } = [];

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes a parsed expression.
/// </summary>
public sealed record TungstenExpressionParseResponse
{
    [JsonPropertyName("command")]
    public string? Command { get; init; }

    [JsonPropertyName("form")]
    public string? Form { get; init; }

    [JsonPropertyName("source")]
    public string? Source { get; init; }

    [JsonPropertyName("input_form")]
    public string? InputForm { get; init; }

    [JsonPropertyName("full_form")]
    public string? FullForm { get; init; }

    [JsonPropertyName("depth")]
    public int Depth { get; init; }

    [JsonPropertyName("length")]
    public int Length { get; init; }

    [JsonPropertyName("tree")]
    public JsonElement Tree { get; init; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes an expression value payload.
/// </summary>
public sealed record TungstenExpressionValue
{
    [JsonPropertyName("input_form")]
    public string? InputForm { get; init; }

    [JsonPropertyName("full_form")]
    public string? FullForm { get; init; }

    [JsonPropertyName("depth")]
    public int Depth { get; init; }

    [JsonPropertyName("length")]
    public int Length { get; init; }

    [JsonPropertyName("tree")]
    public JsonElement Tree { get; init; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes a structural expression evaluation.
/// </summary>
public sealed record TungstenExpressionEvaluationResponse
{
    [JsonPropertyName("command")]
    public string? Command { get; init; }

    [JsonPropertyName("form")]
    public string? Form { get; init; }

    [JsonPropertyName("source")]
    public string? Source { get; init; }

    [JsonPropertyName("parsed_input_form")]
    public string? ParsedInputForm { get; init; }

    [JsonPropertyName("parsed_full_form")]
    public string? ParsedFullForm { get; init; }

    [JsonPropertyName("result")]
    public TungstenExpressionValue? Result { get; init; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes the output of a documentation-index build command.
/// </summary>
public sealed record TungstenDocumentationIndexResponse
{
    [JsonPropertyName("index_path")]
    public string? IndexPath { get; init; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes a documentation search hit.
/// </summary>
public sealed record TungstenDocumentationHit
{
    [JsonPropertyName("title")]
    public string? Title { get; init; }

    [JsonPropertyName("paclet")]
    public string? Paclet { get; init; }

    [JsonPropertyName("kind")]
    public string? Kind { get; init; }

    [JsonPropertyName("category")]
    public string? Category { get; init; }

    [JsonPropertyName("path")]
    public string? Path { get; init; }

    [JsonPropertyName("preview")]
    public string? Preview { get; init; }

    [JsonPropertyName("snippet")]
    public string? Snippet { get; init; }

    [JsonPropertyName("score")]
    public double? Score { get; init; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes a documentation search response.
/// </summary>
public sealed record TungstenDocumentationSearchResponse
{
    [JsonPropertyName("hits")]
    public TungstenDocumentationHit[] Hits { get; init; } = [];

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes a documentation record returned by Tungsten.
/// </summary>
public sealed record TungstenDocumentationRecord
{
    [JsonPropertyName("title")]
    public string? Title { get; init; }

    [JsonPropertyName("paclet")]
    public string? Paclet { get; init; }

    [JsonPropertyName("kind")]
    public string? Kind { get; init; }

    [JsonPropertyName("category")]
    public string? Category { get; init; }

    [JsonPropertyName("path")]
    public string? Path { get; init; }

    [JsonPropertyName("preview")]
    public string? Preview { get; init; }

    [JsonPropertyName("text")]
    public string? Text { get; init; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes the assistant-specific portion of a Notebook Assistant response.
/// </summary>
public sealed record TungstenNotebookAssistantPayload
{
    [JsonPropertyName("success")]
    public bool Success { get; init; }

    [JsonPropertyName("error_type")]
    public string? ErrorType { get; init; }

    [JsonPropertyName("error")]
    public string? Error { get; init; }

    [JsonPropertyName("response_text")]
    public string? ResponseText { get; init; }

    [JsonPropertyName("insert_mode")]
    public string? InsertMode { get; init; }

    [JsonPropertyName("saved_notebook")]
    public bool? SavedNotebook { get; init; }

    [JsonPropertyName("source_cell")]
    public JsonElement SourceCell { get; init; }

    [JsonPropertyName("code_blocks")]
    public JsonElement[] CodeBlocks { get; init; } = [];

    [JsonPropertyName("wolfram_code_blocks")]
    public JsonElement[] WolframCodeBlocks { get; init; } = [];

    [JsonPropertyName("inserted")]
    public JsonElement[] Inserted { get; init; } = [];

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes a Notebook Assistant command response.
/// </summary>
public sealed record TungstenNotebookAssistantResponse
{
    [JsonPropertyName("assistant_success")]
    public bool AssistantSuccess { get; init; }

    [JsonPropertyName("assistant")]
    public TungstenNotebookAssistantPayload? Assistant { get; init; }

    [JsonPropertyName("evaluation")]
    public TungstenKernelEvaluationResponse? Evaluation { get; init; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes an inline-box object.
/// </summary>
public sealed record TungstenInlineBoxRecord
{
    [JsonPropertyName("index")]
    public int Index { get; init; }

    [JsonPropertyName("head")]
    public string? Head { get; init; }

    [JsonPropertyName("box_expression")]
    public string? BoxExpression { get; init; }

    [JsonPropertyName("inline_box_escape")]
    public string? InlineBoxEscape { get; init; }

    [JsonPropertyName("string_literal")]
    public string? StringLiteral { get; init; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes an inline-box string composition response.
/// </summary>
public sealed record TungstenInlineBoxComposeResponse
{
    [JsonPropertyName("success")]
    public bool Success { get; init; }

    [JsonPropertyName("prefix")]
    public string? Prefix { get; init; }

    [JsonPropertyName("suffix")]
    public string? Suffix { get; init; }

    [JsonPropertyName("box_count")]
    public int BoxCount { get; init; }

    [JsonPropertyName("boxes")]
    public TungstenInlineBoxRecord[] Boxes { get; init; } = [];

    [JsonPropertyName("string_value")]
    public string? StringValue { get; init; }

    [JsonPropertyName("string_literal")]
    public string? StringLiteral { get; init; }

    [JsonPropertyName("string_segments")]
    public JsonElement[] StringSegments { get; init; } = [];

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}

/// <summary>
/// Describes an inline-box extraction response from a notebook cell.
/// </summary>
public sealed record TungstenInlineBoxExtractionResponse
{
    [JsonPropertyName("success")]
    public bool Success { get; init; }

    [JsonPropertyName("error_type")]
    public string? ErrorType { get; init; }

    [JsonPropertyName("error")]
    public string? Error { get; init; }

    [JsonPropertyName("notebook_path")]
    public string? NotebookPath { get; init; }

    [JsonPropertyName("source_cell")]
    public TungstenNotebookCellSummary? SourceCell { get; init; }

    [JsonPropertyName("selection_mode")]
    public string? SelectionMode { get; init; }

    [JsonPropertyName("object_index")]
    public int? ObjectIndex { get; init; }

    [JsonPropertyName("available_box_count")]
    public int AvailableBoxCount { get; init; }

    [JsonPropertyName("available_boxes")]
    public TungstenInlineBoxRecord[] AvailableBoxes { get; init; } = [];

    [JsonPropertyName("selected_box_count")]
    public int SelectedBoxCount { get; init; }

    [JsonPropertyName("selected_boxes")]
    public TungstenInlineBoxRecord[] SelectedBoxes { get; init; } = [];

    [JsonPropertyName("prefix")]
    public string? Prefix { get; init; }

    [JsonPropertyName("suffix")]
    public string? Suffix { get; init; }

    [JsonPropertyName("string_value")]
    public string? StringValue { get; init; }

    [JsonPropertyName("string_literal")]
    public string? StringLiteral { get; init; }

    [JsonPropertyName("string_segments")]
    public JsonElement[] StringSegments { get; init; } = [];

    [JsonExtensionData]
    public Dictionary<string, JsonElement> ExtensionData { get; init; } = [];
}
