namespace Tungsten.DotNet;

/// <summary>
/// Base exception type for the Tungsten .NET client.
/// </summary>
public class TungstenException : Exception
{
    /// <summary>
    /// Initializes a new instance of the <see cref="TungstenException"/> class.
    /// </summary>
    public TungstenException(string message)
        : base(message)
    {
    }

    /// <summary>
    /// Initializes a new instance of the <see cref="TungstenException"/> class.
    /// </summary>
    public TungstenException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
