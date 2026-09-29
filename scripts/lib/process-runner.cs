using System;
using System.Diagnostics;
using System.IO;
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

        public static ProcessCaptureResult Run(string fileName, string arguments, int timeoutMilliseconds, int maxOutputBytes, CancellationToken cancellationToken)
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
                try
                {
                    if (!process.Start())
                    {
                        result.ErrorCode = "START_FAILED";
                        return result;
                    }
                    result.Started = true;
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
    }
}
