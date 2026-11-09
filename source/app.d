import imgui : Sizes;
import picker;
import picker_window;
import settings : loadColorScheme;
import std.array : array;
import std.exception : enforce;
import std.stdio : stdin, stdout, stderr;

int main(string[] arguments)
{
    // Smaller than dimgui's default; must be set before the window creates its GUI.
    Sizes.fontSize = 26;
    Sizes.lineHeight = 44;
    Exception settingsFailure;
    try
    {
        loadColorScheme();
    }
    catch (Exception failure)
    {
        settingsFailure = failure;
    }
    try
    {
        enforce(arguments.length == 1, "Usage: fuzzed-gui");
        auto picker = new Picker(stdin.byLineCopy.array);
        if (!picker.closed)
        {
            auto window = new PickerWindow(picker);
            scope (exit)
            {
                window.dispose();
            }
            if (settingsFailure !is null)
            {
                window.showError("Could not load the settings", settingsFailure);
            }
            window.run();
        }
        if (!picker.chosen)
        {
            return 1;
        }
        stdout.writeln(picker.selection);
        return 0;
    }
    catch (Exception failure)
    {
        stderr.writeln("fuzzed-gui: ", failure.msg);
        return 2;
    }
}
