using System.ComponentModel;
using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace DspiSetup;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 2 && Guid.TryParseExact(args[1], "B", out Guid id))
        {
            try
            {
                var output = OutputSetup.ListOutputs().Single(item => item.Id == id);
                if (args[0] == "--apply")
                {
                    OutputSetup.ApplyAsync(output).GetAwaiter().GetResult();
                    OutputSetup.OpenConsoleAsync(output).GetAwaiter().GetResult();
                    return 0;
                }
                if (args[0] == "--open" && output.Attached)
                {
                    OutputSetup.OpenConsoleAsync(output).GetAwaiter().GetResult();
                    return 0;
                }
                if (args[0] is "--remove" or "--remove-and-restore-audio")
                {
                    if (output.Session == null) return 2;
                    return OutputSetup.RemoveAsync(output, args[0] == "--remove-and-restore-audio").GetAwaiter().GetResult();
                }
                return 2;
            }
            catch (Exception ex)
            {
                File.WriteAllText(Path.Combine(Path.GetTempPath(), "dspi-endpoint-setup-error.txt"), ex.Message);
                return 1;
            }
        }
        ApplicationConfiguration.Initialize();
        Application.Run(new SetupWindow());
        return 0;
    }
}

internal sealed record Output(Guid Id, string Name, bool CanAttach, bool Attached, string? Session)
{
    public string EndpointId => "{0.0.0.00000000}." + Id.ToString("B");
    public override string ToString() => Name;
}

internal sealed record Receipt(string Endpoint, string SessionId, string Operation, bool Installed, bool RolledBack,
    string? Error, string? RecoveryError);

internal static class OutputSetup
{
    private static readonly string ConsoleDirectory = Path.Combine(AppContext.BaseDirectory, "Console");
    private const string Render = @"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render";
    private const string Effect = "{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7";
    private const string DspiClsid = "{e53f75ef-9901-4ec4-a8d1-2fe2606a7431}";
    private const string Speaker = "{dff21ce1-f70f-11d0-b917-00a0c9223196}";
    private static readonly string Reports = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "DSPi", "APO");
    private static readonly string Shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
        "WindowsPowerShell", "v1.0", "powershell.exe");
    private static readonly string Archive = Path.Combine(AppContext.BaseDirectory, "PowerShell-runtime.zip");
    private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };

    internal static IReadOnlyList<Output> ListOutputs()
    {
        using var root = Registry.LocalMachine.OpenSubKey(Render);
        if (root == null) return [];
        var sessions = ReadSessions();
        var outputs = new List<Output>();
        foreach (string name in root.GetSubKeyNames())
        {
            if (!Guid.TryParseExact(name, "B", out Guid id)) continue;
            using var key = root.OpenSubKey(name);
            if ((key?.GetValue("DeviceState") as int?) != 1) continue;
            using var properties = key!.OpenSubKey("Properties");
            if (properties == null) continue;
            string label = properties.GetValue("{a45c254e-df1c-4efd-8020-67d146a850e0},2") as string ?? "Playback device";
            string? adapter = properties.GetValue("{b3f8fa53-0004-438e-9003-51a46e139bfc},6") as string;
            string display = string.IsNullOrWhiteSpace(adapter) ? label : $"{label} ({adapter})";
            using var effects = key.OpenSubKey("FxProperties");
            bool attached = string.Equals(effects?.GetValue(Effect) as string, DspiClsid, StringComparison.OrdinalIgnoreCase);
            bool speaker = string.Equals(properties.GetValue("{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},8") as string, Speaker, StringComparison.OrdinalIgnoreCase);
            string endpoint = "{0.0.0.00000000}." + id.ToString("B");
            outputs.Add(new Output(id, display, speaker && effects == null, attached,
                attached ? sessions.GetValueOrDefault(endpoint) : null));
        }
        return outputs.OrderBy(output => output.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    private static Dictionary<string, string> ReadSessions()
    {
        var sessions = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!Directory.Exists(Reports)) return sessions;
        foreach (string file in Directory.EnumerateFiles(Reports, "setup-*.json").OrderBy(File.GetLastWriteTimeUtc))
        {
            try
            {
                var result = JsonSerializer.Deserialize<Receipt>(File.ReadAllText(file), Json);
                if (result is { Operation: "Install", Installed: true } &&
                    Guid.TryParseExact(result.SessionId, "N", out _))
                    sessions[result.Endpoint] = result.SessionId;
                else if (result is { Operation: "Remove", RolledBack: true } &&
                    sessions.GetValueOrDefault(result.Endpoint) == result.SessionId)
                    sessions.Remove(result.Endpoint);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { }
        }
        return sessions;
    }

    internal static async Task ApplyAsync(Output output)
    {
        if (!output.CanAttach || output.Attached)
            throw new InvalidOperationException("Choose an active speaker output with no existing effects.");
        if (!File.Exists(Path.Combine(ConsoleDirectory, "DSPiConsole.exe")))
            throw new InvalidOperationException("DSPi Console is missing from this setup folder.");
        await RunAsync(output, "Install", Guid.NewGuid().ToString("N"));
    }

    internal static async Task<int> RemoveAsync(Output output, bool restoreProtection)
    {
        if (!output.Attached || output.Session == null)
            throw new InvalidOperationException("This output has no attachment made by this installer.");
        return await RunAsync(output, "Remove", output.Session, restoreProtection);
    }

    private static async Task<int> RunAsync(Output output, string operation, string session, bool restoreProtection = false)
    {
        if (!File.Exists(Shell) || !File.Exists(Archive))
            throw new InvalidOperationException("Keep DSPi Setup with every file from its setup folder. Windows PowerShell and the bundled runtime are required.");
        var audioSetting = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Audio", "DisableProtectedAudioDG", null);
        if (operation == "Install" && audioSetting is not 1)
            throw new InvalidOperationException("This unsigned development build needs a PC already configured for local DSPi testing.");

        string operationId = Guid.NewGuid().ToString("N");
        string path = Directory.CreateTempSubdirectory("dspi-setup-").FullName;
        try
        {
            byte[] module = Resource("ProtectedStorage.psm1");
            byte[] worker = Resource("Worker.ps1");
            byte[] admin = Resource("Admin.ps1");
            byte[] shared = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(Resource("SharedComponent.psm1")) + "\n" +
                Encoding.UTF8.GetString(Resource("AudioProtection.psm1")).TrimStart('\uFEFF'));
            byte[] apo = Resource("Payload.Apo.dll");
            File.WriteAllBytes(Path.Combine(path, "ProtectedStorage.psm1"), module);
            File.WriteAllBytes(Path.Combine(path, "Worker.ps1"), worker);
            File.WriteAllBytes(Path.Combine(path, "SharedComponent.psm1"), shared);
            File.WriteAllBytes(Path.Combine(path, "dspi-apo.dll"), apo);
            File.WriteAllBytes(Path.Combine(path, "Admin.ps1"), admin);
            using var identity = WindowsIdentity.GetCurrent();
            string user = identity.User?.Value ?? throw new InvalidOperationException("The active Windows user could not be identified.");
            string script = $"$Operation={Quote(operation)}\n$OperationId='{operationId}'\n$SessionId={Quote(session)}\n" +
                $"$RestoreProtection='{(restoreProtection ? 1 : 0)}'\n$EndpointGuid='{output.Id:B}'\n$Payload={Quote(path)}\n$ExpectedUser={Quote(user)}\n" +
                $"$ModuleHash='{Convert.ToHexString(SHA256.HashData(module))}'\n$WorkerHash='{Convert.ToHexString(SHA256.HashData(worker))}'\n" +
                $"$ArchivePath={Quote(Archive)}\n$AdminHash='{Convert.ToHexString(SHA256.HashData(admin))}'\n" +
                $"$SharedHash='{Convert.ToHexString(SHA256.HashData(shared))}'\n$ApoHash='{Convert.ToHexString(SHA256.HashData(apo))}'\n" +
                Encoding.UTF8.GetString(Resource("Bootstrap.ps1")).TrimStart('\uFEFF');
            string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            var start = new ProcessStartInfo(Shell, "-NoLogo -NoProfile -NonInteractive -EncodedCommand " + encoded)
            {
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden
            };
            using var process = Process.Start(start) ?? throw new InvalidOperationException("Windows did not start the administrator helper.");
            using var timeLimit = new CancellationTokenSource(TimeSpan.FromMinutes(3));
            try { await process.WaitForExitAsync(timeLimit.Token); }
            catch (OperationCanceledException)
            {
                throw new InvalidOperationException("Setup is still running. Wait for Windows to finish before using this output again.");
            }

            string resultPath = Path.Combine(Reports, $"setup-{operationId}.json");
            if (!File.Exists(resultPath))
                throw new InvalidOperationException("Windows returned no setup result.");
            var report = JsonSerializer.Deserialize<Receipt>(File.ReadAllText(resultPath), Json)
                ?? throw new InvalidOperationException("Windows returned an unreadable setup result.");
            if (report.Endpoint != output.EndpointId || (operation == "Install" ? !report.Installed : !report.RolledBack))
                throw new InvalidOperationException(string.Join("\n", new[] { report.Error ?? "Setup could not be confirmed.", report.RecoveryError }.OfType<string>()));
            return process.ExitCode;
        }
        finally
        {
            foreach (string file in new[] { "ProtectedStorage.psm1", "Worker.ps1", "SharedComponent.psm1", "dspi-apo.dll", "Admin.ps1" })
                File.Delete(Path.Combine(path, file));
            Directory.Delete(path, recursive: false);
        }
    }

    internal static async Task OpenConsoleAsync(Output output)
    {
        string executable = Path.Combine(ConsoleDirectory, "DSPiConsole.exe");
        for (int attempt = 0; attempt < 2; attempt++)
        {
            var start = new ProcessStartInfo(executable) { UseShellExecute = false, WorkingDirectory = ConsoleDirectory };
            start.Environment["DSPI_SETUP_OUTPUT"] = output.EndpointId;
            using var console = Process.Start(start) ?? throw new InvalidOperationException("DSPi Console could not start.");
            for (int poll = 0; poll < 55; poll++)
            {
                await Task.Delay(120);
                console.Refresh();
                if (console.HasExited) break;
                if (poll >= 15 && console.MainWindowHandle != IntPtr.Zero) return;
            }
            if (!console.HasExited) break;
        }
        throw new InvalidOperationException("DSPi is attached, but its Console window did not open.");
    }

    private static string Quote(string value) => "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";

    private static byte[] Resource(string name)
    {
        var assembly = Assembly.GetExecutingAssembly();
        using var stream = assembly.GetManifestResourceStream(assembly.GetManifestResourceNames().Single(item => item.EndsWith("." + name, StringComparison.Ordinal)))!;
        using var data = new MemoryStream();
        stream.CopyTo(data);
        return data.ToArray();
    }
}

internal sealed class SetupWindow : Form
{
    private readonly ComboBox outputs = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Top };
    private readonly Label status = new() { AutoSize = false, Height = 70, Dock = DockStyle.Top, MaximumSize = new Size(480, 0) };
    private readonly Button install = new() { Text = "Attach and open Console", AutoSize = true };
    private readonly Button remove = new() { Text = "Remove DSPi", AutoSize = true };
    private readonly Button refresh = new() { Text = "Refresh outputs", AutoSize = true };
    private bool busy;

    internal SetupWindow()
    {
        Text = "DSPi Output Setup";
        ClientSize = new Size(525, 220);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        Font = new Font("Segoe UI", 10);
        var content = new Panel { Dock = DockStyle.Fill, Padding = new Padding(22) };
        var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 40, WrapContents = false };
        actions.Controls.AddRange([install, remove, refresh]);
        var title = new Label { Text = "Windows playback output", Dock = DockStyle.Top, Height = 30, Font = new Font(Font, FontStyle.Bold) };
        content.Controls.AddRange([actions, status, outputs, title]);
        Controls.Add(content);
        outputs.SelectedIndexChanged += (_, _) => UpdateStatus();
        refresh.Click += (_, _) => RefreshOutputs();
        install.Click += async (_, _) => await RunSelected(removeAttachment: false);
        remove.Click += async (_, _) => await RunSelected(removeAttachment: true);
        FormClosing += (_, e) => { if (busy) e.Cancel = true; };
        RefreshOutputs();
    }

    private void RefreshOutputs()
    {
        Guid? current = (outputs.SelectedItem as Output)?.Id;
        var choices = OutputSetup.ListOutputs();
        outputs.DataSource = choices.ToList();
        if (current.HasValue)
        {
            int index = choices.ToList().FindIndex(item => item.Id == current.Value);
            if (index >= 0) outputs.SelectedIndex = index;
        }
        UpdateStatus();
    }

    private void UpdateStatus()
    {
        var output = outputs.SelectedItem as Output;
        install.Text = output?.Attached == true ? "Open Console" : "Attach and open Console";
        install.Enabled = !busy && (output?.CanAttach == true || output?.Attached == true);
        remove.Enabled = !busy && output?.Session != null;
        refresh.Enabled = outputs.Enabled = !busy;
        if (!busy)
            status.Text = output switch
            {
                null => "No active Windows playback outputs found.",
                { Attached: true } => "DSPi is attached to this output.",
                { CanAttach: true } => "Setup restarts Windows Audio briefly. Your default playback output stays the same.",
                _ => "This output uses an existing effect or an unsupported speaker layout."
            };
    }

    private async Task RunSelected(bool removeAttachment)
    {
        if (busy || outputs.SelectedItem is not Output output) return;
        bool restoreProtection = false;
        if (removeAttachment)
        {
            var choice = MessageBox.Show(this,
                "Restore Windows protected audio after removing DSPi from the last attached output? This applies to all outputs.",
                "Remove DSPi", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);
            if (choice == DialogResult.Cancel) return;
            restoreProtection = choice == DialogResult.Yes;
        }
        busy = true;
        UpdateStatus();
        status.Text = removeAttachment ? "Removing DSPi and restarting Windows Audio…" :
            output.Attached ? "Opening the Console…" : "Attaching DSPi and restarting Windows Audio…";
        string result;
        try
        {
            if (removeAttachment)
            {
                int outcome = await OutputSetup.RemoveAsync(output, restoreProtection);
                result = outcome switch
                {
                    0 when restoreProtection => "DSPi was removed. Protected audio is enabled.",
                    0 => "DSPi was removed. Windows Audio restarted.",
                    4 => "DSPi was removed. Another output still uses DSPi, so the audio test setting remains on.",
                    6 => "DSPi was removed. Restart Windows to apply protected audio.",
                    _ => "DSPi was removed. Setup could not confirm protected audio."
                };
            }
            else
            {
                if (!output.Attached) await OutputSetup.ApplyAsync(output);
                await OutputSetup.OpenConsoleAsync(output);
                result = "DSPi Console opened for this output.";
            }
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223) { result = "Administrator approval was canceled."; }
        catch (Exception ex) { result = ex.Message; }
        busy = false;
        RefreshOutputs();
        status.Text = result;
    }
}

