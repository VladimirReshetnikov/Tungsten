using System.Diagnostics;

static string? FindTungstenPythonSource()
{
    var directory = new DirectoryInfo(AppContext.BaseDirectory);
    while (directory is not null)
    {
        var candidate = Path.Combine(directory.FullName, "src", "tungsten", "__init__.py");
        if (File.Exists(candidate))
        {
            return Path.Combine(directory.FullName, "src");
        }

        var siblingCandidate = Path.Combine(directory.FullName, "Engine", "src", "tungsten", "__init__.py");
        if (File.Exists(siblingCandidate))
        {
            return Path.Combine(directory.FullName, "Engine", "src");
        }

        directory = directory.Parent;
    }

    var currentDirectoryCandidate = Path.Combine(Environment.CurrentDirectory, "Engine", "src", "tungsten", "__init__.py");
    if (File.Exists(currentDirectoryCandidate))
    {
        return Path.Combine(Environment.CurrentDirectory, "Engine", "src");
    }

    return null;
}

static string FindPythonExecutable()
{
    var configured = Environment.GetEnvironmentVariable("TUNGSTEN_PYTHON");
    return string.IsNullOrWhiteSpace(configured) ? "python" : configured;
}

var startInfo = new ProcessStartInfo
{
    FileName = FindPythonExecutable(),
    UseShellExecute = false,
};
startInfo.ArgumentList.Add("-m");
startInfo.ArgumentList.Add("tungsten");
foreach (var argument in args)
{
    startInfo.ArgumentList.Add(argument);
}

var sourceRoot = FindTungstenPythonSource();
if (sourceRoot is not null)
{
    var existingPythonPath = Environment.GetEnvironmentVariable("PYTHONPATH");
    startInfo.Environment["PYTHONPATH"] = string.IsNullOrWhiteSpace(existingPythonPath)
        ? sourceRoot
        : sourceRoot + Path.PathSeparator + existingPythonPath;
}

try
{
    using var process = Process.Start(startInfo);
    if (process is null)
    {
        Console.Error.WriteLine("tungsten.exe could not start Python.");
        return 2;
    }

    process.WaitForExit();
    return process.ExitCode;
}
catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
{
    Console.Error.WriteLine("tungsten.exe could not start Python. Set TUNGSTEN_PYTHON to a Python executable that can run Tungsten.");
    Console.Error.WriteLine(ex.Message);
    return 2;
}
