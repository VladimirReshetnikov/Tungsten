namespace Tungsten.DotNet;

/// <summary>
/// Identifies the Wolfram syntax form that Tungsten should parse.
/// </summary>
public enum TungstenExpressionForm
{
    /// <summary>
    /// Parse as InputForm.
    /// </summary>
    Input,

    /// <summary>
    /// Parse as FullForm.
    /// </summary>
    FullForm,

    /// <summary>
    /// Parse as Tungsten's supported StandardForm subset.
    /// </summary>
    Standard,
}
