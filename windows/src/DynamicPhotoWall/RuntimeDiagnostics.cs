using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows.Controls.Primitives;

namespace DynamicPhotoWall;

internal static class RuntimeDiagnostics
{
    // Check the published host without creating Application, windows or a tray icon.
    internal static int Run(string[] args)
    {
        var output = Program.Value(args, "--output") ?? throw new ArgumentException("--output is required");
        output = Path.GetFullPath(output);
        Directory.CreateDirectory(Path.GetDirectoryName(output)!);
        try
        {
            var gate = Program.Value(args, "--wait-for");
            if (gate != null)
            {
                File.WriteAllText(output + ".ready", "Waiting before loading popup dependencies.");
                if (!SpinWait.SpinUntil(() => File.Exists(gate), TimeSpan.FromSeconds(30)))
                    throw new TimeoutException("Runtime check gate did not open.");
            }
            var assemblies = LoadPopupDependencies();
            File.WriteAllText(output, JsonSerializer.Serialize(new { Success = true, AppContext.BaseDirectory, Environment.ProcessPath, Assemblies = assemblies }, new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        }
        catch (Exception error)
        {
            // Preserve the original failure even if a missing runtime assembly
            // also prevents the JSON serializer from initializing.
            File.WriteAllText(output + ".error.txt", error.ToString());
            File.WriteAllText(output, JsonSerializer.Serialize(new { Success = false, Error = error.ToString() }, new JsonSerializerOptions { WriteIndented = true }));
            return 1;
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    [System.Diagnostics.CodeAnalysis.UnconditionalSuppressMessage("SingleFile", "IL3000",
        Justification = "This diagnostic records whether the published assemblies have physical extracted paths.")]
    private static object[] LoadPopupDependencies()
    {
        var accessibility = Assembly.Load("Accessibility, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35");
        _ = accessibility.GetType("Accessibility.IAccessible", throwOnError: true);
        // Compile the exact bridge on the failing stack without opening a popup
        // or invoking accessibility APIs against the desktop.
        var helper = typeof(Popup).GetNestedType("PopupSecurityHelper", BindingFlags.NonPublic)
            ?? throw new MissingMemberException("WPF PopupSecurityHelper not found.");
        var bridge = helper.GetMethod("ForceMsaaToUiaBridge", BindingFlags.Instance | BindingFlags.NonPublic)
            ?? throw new MissingMethodException("WPF accessibility bridge not found.");
        RuntimeHelpers.PrepareMethod(bridge.MethodHandle);
        return new[] { accessibility, typeof(Popup).Assembly, typeof(System.Windows.Forms.AccessibleObject).Assembly }
            .Select(assembly => (object)new { assembly.FullName, assembly.Location }).ToArray();
    }
}
