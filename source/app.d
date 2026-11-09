import imgui.colorscheme : defaultColorScheme, zenburnColorScheme;
import picker;
import picker_window;
import std.array : array;
import std.exception : enforce;
import std.stdio : stderr, stdin, stdout;

int main(string[] arguments)
{
    defaultColorScheme = zenburnColorScheme;
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
