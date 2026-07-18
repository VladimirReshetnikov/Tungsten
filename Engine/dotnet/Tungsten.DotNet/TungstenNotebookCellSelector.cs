using System.Globalization;
using System.Text.Json;

namespace Tungsten.DotNet;

/// <summary>
/// Identifies a notebook cell using the same selector concepts exposed by Tungsten's CLI.
/// </summary>
public sealed record TungstenNotebookCellSelector
{
    private TungstenNotebookCellSelector(
        int? cellIndex,
        IReadOnlyList<int>? cellPath,
        string? expressionUuid,
        int? cellId,
        string? cellTag)
    {
        var selectorCount =
            (cellIndex is null ? 0 : 1) +
            (cellPath is null ? 0 : 1) +
            (expressionUuid is null ? 0 : 1) +
            (cellId is null ? 0 : 1) +
            (cellTag is null ? 0 : 1);

        if (selectorCount != 1)
        {
            throw new ArgumentException(
                "Exactly one cell selector must be provided: cell index, cell path, expression UUID, cell ID, or cell tag.");
        }

        CellIndex = cellIndex;
        CellPath = cellPath;
        ExpressionUuid = expressionUuid;
        CellId = cellId;
        CellTag = cellTag;
    }

    /// <summary>
    /// Gets the flat notebook cell index selector, if present.
    /// </summary>
    public int? CellIndex { get; }

    /// <summary>
    /// Gets the structural notebook cell path selector, if present.
    /// </summary>
    public IReadOnlyList<int>? CellPath { get; }

    /// <summary>
    /// Gets the expression UUID selector, if present.
    /// </summary>
    public string? ExpressionUuid { get; }

    /// <summary>
    /// Gets the CellID selector, if present.
    /// </summary>
    public int? CellId { get; }

    /// <summary>
    /// Gets the cell tag selector, if present.
    /// </summary>
    public string? CellTag { get; }

    /// <summary>
    /// Creates a selector that targets a flat notebook cell index.
    /// </summary>
    public static TungstenNotebookCellSelector ByIndex(int index) =>
        new(cellIndex: index, cellPath: null, expressionUuid: null, cellId: null, cellTag: null);

    /// <summary>
    /// Creates a selector that targets a notebook cell path.
    /// </summary>
    public static TungstenNotebookCellSelector ByPath(params int[] path)
    {
        ArgumentNullException.ThrowIfNull(path);
        if (path.Length == 0)
        {
            throw new ArgumentException("Notebook cell paths must not be empty.", nameof(path));
        }
        return new(cellIndex: null, cellPath: path, expressionUuid: null, cellId: null, cellTag: null);
    }

    /// <summary>
    /// Creates a selector that targets an expression UUID.
    /// </summary>
    public static TungstenNotebookCellSelector ByExpressionUuid(string expressionUuid)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(expressionUuid);
        return new(cellIndex: null, cellPath: null, expressionUuid, cellId: null, cellTag: null);
    }

    /// <summary>
    /// Creates a selector that targets a CellID.
    /// </summary>
    public static TungstenNotebookCellSelector ByCellId(int cellId) =>
        new(cellIndex: null, cellPath: null, expressionUuid: null, cellId, cellTag: null);

    /// <summary>
    /// Creates a selector that targets a cell tag.
    /// </summary>
    public static TungstenNotebookCellSelector ByCellTag(string cellTag)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(cellTag);
        return new(cellIndex: null, cellPath: null, expressionUuid: null, cellId: null, cellTag);
    }

    internal void AppendArguments(ICollection<string> arguments)
    {
        if (CellIndex is not null)
        {
            arguments.Add("--cell-index");
            arguments.Add(CellIndex.Value.ToString(CultureInfo.InvariantCulture));
            return;
        }

        if (CellPath is not null)
        {
            arguments.Add("--cell-path");
            arguments.Add(JsonSerializer.Serialize(CellPath));
            return;
        }

        if (ExpressionUuid is not null)
        {
            arguments.Add("--expression-uuid");
            arguments.Add(ExpressionUuid);
            return;
        }

        if (CellId is not null)
        {
            arguments.Add("--cell-id");
            arguments.Add(CellId.Value.ToString(CultureInfo.InvariantCulture));
            return;
        }

        arguments.Add("--cell-tag");
        arguments.Add(CellTag!);
    }
}
