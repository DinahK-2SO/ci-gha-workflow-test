using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class OpenCvBoundedProcess
{
    [StructLayout(LayoutKind.Sequential)]
    struct Startup
    {
        public int size;
        public IntPtr reserved, desktop, title;
        public int x, y, width, height, columns, rows, fill, flags;
        public short show, reservedSize;
        public IntPtr reservedBytes, input, output, error;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ProcessHandles { public IntPtr process, thread; public uint pid, tid; }

    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits
    {
        public long processTime, jobTime;
        public uint flags;
        public UIntPtr minimumWorkingSet, maximumWorkingSet;
        public uint activeProcesses;
        public UIntPtr affinity;
        public uint priority, scheduling;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters { public ulong reads, writes, other, readBytes, writeBytes, otherBytes; }

    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits
    {
        public BasicLimits basic;
        public IoCounters io;
        public UIntPtr processMemory, jobMemory, peakProcessMemory, peakJobMemory;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct Accounting
    {
        public long user, kernel, periodUser, periodKernel;
        public uint faults, totalProcesses, activeProcesses, terminatedProcesses;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetInformationJobObject(IntPtr job, int type, ref ExtendedLimits value, int length);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes,
        IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory,
        ref Startup startup, out ProcessHandles process);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint timeout);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool QueryInformationJobObject(IntPtr job, int type, out Accounting value, int length, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "QueryInformationJobObject")]
    static extern bool QueryLimits(IntPtr job, int type, out ExtendedLimits value, int length, IntPtr returned);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    public sealed class Result
    {
        public string StartedAt, FinishedAt;
        public uint ProcessId, ExitCode, TotalProcesses, ActiveAtCommandExit;
        public bool TimedOut;
        public double OuterWallSeconds, ProcessTreeCpuSeconds;
        public ulong PeakJobMemoryBytes;
    }

    static string Quote(string value)
    {
        if (value.IndexOfAny(new[] { '"', '\r', '\n', '%', '!', '&', '|', '<', '>', '^' }) >= 0)
            throw new ArgumentException("Unsupported shell character in bounded command input.");
        int trailing = 0;
        for (int i = value.Length - 1; i >= 0 && value[i] == '\\'; --i) ++trailing;
        return "\"" + value + new string('\\', trailing) + "\"";
    }

    public static Result Run(string executable, string[] arguments, string directory, string log, int timeoutSeconds)
    {
        return RunWithProgress(executable, arguments, directory, log, timeoutSeconds, null);
    }

    public static Result RunWithProgress(string executable, string[] arguments, string directory, string log,
        int timeoutSeconds, Action<double> progress)
    {
        if (timeoutSeconds < 1 || timeoutSeconds > 1800) throw new ArgumentOutOfRangeException(nameof(timeoutSeconds));
        return RunCore(executable, arguments, directory, log, timeoutSeconds, progress);
    }

    public static Result RunObserved(string executable, string[] arguments, string directory, string log,
        Action<double> progress)
    {
        // Controllers retain their existing inner deadlines; observation adds no outer deadline.
        return RunCore(executable, arguments, directory, log, null, progress);
    }

    private static Result RunCore(string executable, string[] arguments, string directory, string log,
        int? timeoutSeconds, Action<double> progress)
    {
        Quote(directory);
        string cmd = Environment.GetEnvironmentVariable("ComSpec");
        string inner = Quote(executable);
        foreach (string argument in arguments) inner += " " + Quote(argument);
        inner += " > " + Quote(log) + " 2>&1";
        var command = new StringBuilder(Quote(cmd) + " /d /s /c \"" + inner + "\"");
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception();
        ProcessHandles process = default;
        bool assigned = false;
        try
        {
            var limits = new ExtendedLimits { basic = new BasicLimits { flags = 0x2000 } };
            if (!SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf<ExtendedLimits>()))
                throw new Win32Exception();
            var startup = new Startup { size = Marshal.SizeOf<Startup>() };
            if (!CreateProcess(cmd, command, IntPtr.Zero, IntPtr.Zero, false, 0x08000004,
                IntPtr.Zero, directory, ref startup, out process)) throw new Win32Exception();
            // Assign while suspended; closing this unnamed job affects only this command's descendants.
            if (!AssignProcessToJobObject(job, process.process)) throw new Win32Exception();
            assigned = true;
            var result = new Result { ProcessId = process.pid, StartedAt = DateTimeOffset.UtcNow.ToString("o") };
            var clock = Stopwatch.StartNew();
            if (ResumeThread(process.thread) == uint.MaxValue) throw new Win32Exception();
            uint wait;
            do
            {
                uint remaining = timeoutSeconds.HasValue
                    ? (uint)Math.Max(0, timeoutSeconds.Value * 1000L - clock.ElapsedMilliseconds)
                    : uint.MaxValue;
                wait = WaitForSingleObject(process.process, progress == null ? remaining : Math.Min(remaining, 30000u));
                if (wait != 258 || (timeoutSeconds.HasValue && clock.ElapsedMilliseconds >= timeoutSeconds.Value * 1000L)) break;
                progress?.Invoke(clock.Elapsed.TotalSeconds);
            } while (true);
            if (wait == 258)
            {
                result.TimedOut = true;
                if (!TerminateJobObject(job, 124) || WaitForSingleObject(process.process, 30000) != 0)
                    throw new Win32Exception();
            }
            else if (wait != 0) throw new Win32Exception();
            clock.Stop();
            if (!GetExitCodeProcess(process.process, out result.ExitCode)) throw new Win32Exception();
            if (!QueryInformationJobObject(job, 1, out Accounting accounting, Marshal.SizeOf<Accounting>(), IntPtr.Zero))
                throw new Win32Exception();
            if (!QueryLimits(job, 9, out ExtendedLimits measured, Marshal.SizeOf<ExtendedLimits>(), IntPtr.Zero))
                throw new Win32Exception();
            result.FinishedAt = DateTimeOffset.UtcNow.ToString("o");
            result.OuterWallSeconds = clock.Elapsed.TotalSeconds;
            result.ProcessTreeCpuSeconds = (accounting.user + accounting.kernel) / 10000000.0;
            result.TotalProcesses = accounting.totalProcesses;
            result.ActiveAtCommandExit = accounting.activeProcesses;
            result.PeakJobMemoryBytes = measured.peakJobMemory.ToUInt64();
            return result;
        }
        finally
        {
            try
            {
                if (!assigned && process.process != IntPtr.Zero)
                {
                    if (!TerminateProcess(process.process, 125)) throw new Win32Exception();
                }
            }
            finally
            {
                CloseHandle(job);
                if (process.thread != IntPtr.Zero) CloseHandle(process.thread);
                if (process.process != IntPtr.Zero) CloseHandle(process.process);
            }
        }
    }
}
