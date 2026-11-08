import picker;
import picker_window;
import std.array : array;
import std.exception : enforce;
import std.stdio : stdin, stdout, stderr;

int main(string[] arguments)
{
    try
    {
        enforce(arguments.length == 1 ||
            (arguments.length == 2 && arguments[1] == "--native-check"),
            "Usage: fuzzed-gui [--native-check]");
        if (arguments.length == 2)
        {
            verifyNativePicker();
            return 0;
        }
        auto picker = new Picker(stdin.byLineCopy.array);
        if (!picker.closed)
        {
            auto window = new PickerWindow(picker);
            scope(exit) window.dispose();
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
