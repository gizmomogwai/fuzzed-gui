module settings;

import imgui.colorscheme : ColorScheme, defaultColorScheme, zenburnColorScheme;
import std.file : exists, mkdirRecurse, readText, write;
import std.json : parseJSON;
import std.path : dirName, expandTilde;

immutable ColorScheme[string] colorSchemes = [
    "default": ColorScheme.init, "zenburn": zenburnColorScheme,
];

private string settingsPath()
{
    return expandTilde("~/.config/picker/settings.json");
}

/**
    Activates the color scheme named in the settings file; zenburn when the file or name is
    missing. Zenburn is active before anything can throw, so callers may carry on after a failure.
*/
void loadColorScheme()
{
    auto path = settingsPath;
    defaultColorScheme = zenburnColorScheme;
    try
    {
        if (!exists(path))
        {
            return;
        }
        auto settings = path.readText.parseJSON;
        if (auto name = "colorScheme" in settings.object)
        {
            if (auto scheme = name.str in colorSchemes)
            {
                defaultColorScheme = *scheme;
            }
        }
    }
    catch (Exception failure)
    {
        // Rethrowing the same object keeps its backtrace.
        failure.msg = path ~ ": " ~ failure.msg;
        throw failure;
    }
}

/// Stores the color scheme name, keeping other settings.
void saveColorScheme(string name)
{
    auto path = settingsPath;
    try
    {
        auto settings = (path.exists ? path.readText : "{}").parseJSON;
        settings["colorScheme"] = name;
        path.dirName.mkdirRecurse;
        write(path, settings.toPrettyString ~ "\n");
    }
    catch (Exception failure)
    {
        failure.msg = path ~ ": " ~ failure.msg;
        throw failure;
    }
}
