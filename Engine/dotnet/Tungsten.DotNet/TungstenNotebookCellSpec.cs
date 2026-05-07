namespace Tungsten.DotNet;

/// <summary>
/// Describes a notebook cell to create through Tungsten's notebook CLI.
/// </summary>
/// <param name="Style">The Wolfram notebook style name, such as <c>Text</c> or <c>Input</c>.</param>
/// <param name="Text">The cell text.</param>
public sealed record TungstenNotebookCellSpec(string Style, string Text);
