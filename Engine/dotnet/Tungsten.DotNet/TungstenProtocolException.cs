namespace Tungsten.DotNet;

/// <summary>
/// Raised when a Tungsten command succeeds at the process level but does not produce valid JSON.
/// </summary>
public sealed class TungstenProtocolException : TungstenException
{
    /// <summary>
    /// Initializes a new instance of the <see cref="TungstenProtocolException"/> class.
    /// </summary>
    public TungstenProtocolException(
        string message,
        string standardOutput,
        string standardError,
        Exception innerException)
        : base(message, innerException)
    {
        StandardOutput = standardOutput;
        StandardError = standardError;
    }

    /// <summary>
    /// Gets the captured standard output.
    /// </summary>
    public string StandardOutput { get; }

    /// <summary>
    /// Gets the captured standard error.
    /// </summary>
    public string StandardError { get; }
}
