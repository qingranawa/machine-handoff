using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace MachineHandoff
{
    public sealed class ProcessCaptureResult
    {
        public bool Started { get; set; }
        public bool TimedOut { get; set; }
        public bool Cancelled { get; set; }
        public bool StdoutTruncated { get; set; }
        public bool StderrTruncated { get; set; }
        public int ExitCode { get; set; }
        public string Stdout { get; set; }
        public string Stderr { get; set; }
        public string ErrorCode { get; set; }
    }

    public static class ProcessRunner
    {
        private const long MaximumExecutableBytes = 268435456L;

        private sealed class BoundedBuffer
        {
            private readonly object gate = new object();
            private readonly MemoryStream data = new MemoryStream();
            private readonly int maximumBytes;
            public bool Truncated { get; private set; }

            public BoundedBuffer(int maximumBytes)
            {
                this.maximumBytes = maximumBytes;
            }

            public void Append(byte[] buffer, int count)
            {
                lock (gate)
                {
                    int remaining = maximumBytes - (int)data.Length;
                    int accepted = Math.Min(remaining, count);
                    if (accepted > 0) data.Write(buffer, 0, accepted);
                    if (accepted < count) Truncated = true;
                }
            }

            public string Text
            {
                get
                {
                    lock (gate) return Encoding.UTF8.GetString(data.ToArray());
                }
            }
        }

        private static Thread StartReader(Stream stream, BoundedBuffer capture)
        {
            Thread thread = new Thread(delegate()
            {
                byte[] buffer = new byte[4096];
                try
                {
                    int count;
                    while ((count = stream.Read(buffer, 0, buffer.Length)) > 0)
                        capture.Append(buffer, count);
                }
                catch (IOException) { }
                catch (ObjectDisposedException) { }
            });
            thread.IsBackground = true;
            thread.Start();
            return thread;
        }

        public static ProcessCaptureResult Run(string fileName, string arguments, int timeoutMilliseconds, int maxOutputBytes, CancellationToken cancellationToken, string expectedExecutableSha256)
        {
            ProcessCaptureResult result = new ProcessCaptureResult
            {
                Started = false,
                TimedOut = false,
                Cancelled = false,
                StdoutTruncated = false,
                StderrTruncated = false,
                ExitCode = -1,
                Stdout = String.Empty,
                Stderr = String.Empty,
                ErrorCode = null
            };

            if (timeoutMilliseconds <= 0)
            {
                result.TimedOut = true;
                result.ErrorCode = "TIMEOUT";
                return result;
            }
            if (cancellationToken.IsCancellationRequested)
            {
                result.Cancelled = true;
                result.ErrorCode = "CANCELLED";
                return result;
            }
            if (!IsSha256(expectedExecutableSha256))
            {
                result.ErrorCode = "EXECUTABLE_IDENTITY_INVALID";
                return result;
            }
            string executableExtension = Path.GetExtension(fileName);
            if (!String.Equals(executableExtension, ".exe", StringComparison.OrdinalIgnoreCase) &&
                !String.Equals(executableExtension, ".com", StringComparison.OrdinalIgnoreCase))
            {
                result.ErrorCode = "EXECUTABLE_TYPE_UNSUPPORTED";
                return result;
            }

            using (Process process = new Process())
            {
                process.StartInfo = new ProcessStartInfo
                {
                    FileName = fileName,
                    Arguments = arguments,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    StandardOutputEncoding = new UTF8Encoding(false),
                    StandardErrorEncoding = new UTF8Encoding(false)
                };
                process.StartInfo.EnvironmentVariables["GIT_OPTIONAL_LOCKS"] = "0";

                BoundedBuffer stdout = new BoundedBuffer(maxOutputBytes);
                BoundedBuffer stderr = new BoundedBuffer(maxOutputBytes);
                Thread stdoutReader = null;
                Thread stderrReader = null;
                FileStream identityStream = null;
                try
                {
                    try
                    {
                        if ((File.GetAttributes(fileName) & FileAttributes.ReparsePoint) != 0)
                        {
                            result.ErrorCode = "EXECUTABLE_REPARSE_BLOCKED";
                            return result;
                        }
                        identityStream = new FileStream(fileName, FileMode.Open, FileAccess.Read, FileShare.Read);
                        if (identityStream.Length > MaximumExecutableBytes)
                        {
                            result.ErrorCode = "EXECUTABLE_SIZE_LIMIT";
                            return result;
                        }
                        string actualSha256;
                        using (SHA256 sha = SHA256.Create())
                            actualSha256 = ToLowerHex(sha.ComputeHash(identityStream));
                        if (!String.Equals(actualSha256, expectedExecutableSha256, StringComparison.OrdinalIgnoreCase))
                        {
                            result.ErrorCode = "EXECUTABLE_IDENTITY_CHANGED";
                            return result;
                        }
                    }
                    catch
                    {
                        result.ErrorCode = result.ErrorCode ?? "EXECUTABLE_IDENTITY_FAILED";
                        return result;
                    }

                    if (!process.Start())
                    {
                        result.ErrorCode = "START_FAILED";
                        return result;
                    }
                    result.Started = true;
                    identityStream.Dispose();
                    identityStream = null;
                    stdoutReader = StartReader(process.StandardOutput.BaseStream, stdout);
                    stderrReader = StartReader(process.StandardError.BaseStream, stderr);

                    Stopwatch elapsed = Stopwatch.StartNew();
                    bool exited = false;
                    while (!exited && elapsed.ElapsedMilliseconds < timeoutMilliseconds && !cancellationToken.IsCancellationRequested)
                    {
                        int remaining = Math.Max(1, timeoutMilliseconds - (int)elapsed.ElapsedMilliseconds);
                        exited = process.WaitForExit(Math.Min(50, remaining));
                    }
                    if (!exited)
                    {
                        result.Cancelled = cancellationToken.IsCancellationRequested;
                        result.TimedOut = !result.Cancelled;
                        try { process.Kill(); }
                        catch
                        {
                            result.ErrorCode = "KILL_FAILED";
                        }
                        try { process.WaitForExit(3000); }
                        catch { }
                        try { process.StandardOutput.BaseStream.Dispose(); }
                        catch { }
                        try { process.StandardError.BaseStream.Dispose(); }
                        catch { }
                        result.ErrorCode = result.ErrorCode ?? (result.Cancelled ? "CANCELLED" : "TIMEOUT");
                    }
                    else
                    {
                        process.WaitForExit();
                        result.ExitCode = process.ExitCode;
                    }
                }
                catch
                {
                    result.ErrorCode = result.ErrorCode ?? "PROCESS_FAILED";
                    if (result.Started && !process.HasExited)
                    {
                        try { process.Kill(); }
                        catch { }
                    }
                }
                finally
                {
                    if (identityStream != null) identityStream.Dispose();
                    if (stdoutReader != null) stdoutReader.Join(1000);
                    if (stderrReader != null) stderrReader.Join(1000);
                    result.Stdout = stdout.Text;
                    result.Stderr = stderr.Text;
                    result.StdoutTruncated = stdout.Truncated;
                    result.StderrTruncated = stderr.Truncated;
                    if (result.ErrorCode == null && (result.StdoutTruncated || result.StderrTruncated))
                        result.ErrorCode = "OUTPUT_LIMIT";
                }
            }

            return result;
        }

        private static bool IsSha256(string value)
        {
            if (String.IsNullOrEmpty(value) || value.Length != 64) return false;
            for (int index = 0; index < value.Length; index++)
            {
                char character = value[index];
                if (!((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f') || (character >= 'A' && character <= 'F'))) return false;
            }
            return true;
        }

        private static string ToLowerHex(byte[] value)
        {
            StringBuilder builder = new StringBuilder(value.Length * 2);
            for (int index = 0; index < value.Length; index++)
                builder.Append(value[index].ToString("x2"));
            return builder.ToString();
        }
    }
}
