using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

namespace M365Workbench
{
    public static class Launcher
    {
        [STAThread]
        public static int Main(string[] args)
        {
            try
            {
                if (args == null || args.Length != 1)
                {
                    throw new InvalidOperationException("The Intune Device Workbench script path was not supplied.");
                }

                string scriptPath = Path.GetFullPath(args[0]);
                if (!File.Exists(scriptPath))
                {
                    throw new FileNotFoundException("Intune Device Workbench could not be found.", scriptPath);
                }

                string powerShellPath = ResolvePowerShell();

                var startInfo = new ProcessStartInfo
                {
                    FileName = powerShellPath,
                    Arguments = "-NoLogo -NoProfile -STA -WindowStyle Hidden -File " + Quote(scriptPath),
                    WorkingDirectory = Path.GetDirectoryName(scriptPath),
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };

                Process.Start(startInfo);
                return 0;
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    exception.Message,
                    "Intune Device Workbench",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return 1;
            }
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static string ResolvePowerShell()
        {
            // Prefer the machine installation; the Store alias is not the only
            // supported way to install PowerShell 7.
            var directories = new List<string> {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps")
            };
            directories.AddRange((Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator));
            return FindPowerShell(directories);
        }

        private static string FindPowerShell(IEnumerable<string> directories)
        {
            foreach (string entry in directories)
            {
                string directory = entry.Trim().Trim('"');
                try
                {
                    // An absolute drive or UNC root has at least three characters.
                    // A single separator or a bare drive letter depends on the working directory.
                    string root = Path.GetPathRoot(directory);
                    if (String.IsNullOrEmpty(root) || root.Length < 3) continue;
                    string candidate = Path.Combine(directory, "pwsh.exe");
                    if (File.Exists(candidate)) return candidate;
                }
                catch (ArgumentException) { }
                catch (NotSupportedException) { }
                catch (PathTooLongException) { }
            }
            throw new FileNotFoundException("PowerShell 7.4 or newer is required. Install PowerShell, then open Intune Device Workbench again.");
        }
    }
}
