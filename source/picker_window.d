module picker_window;

import imgui : Editor, ImGui, LineLayout, MouseInfo, Sizes, TextAlign, TextSpan;
import imgui.api : addGlobalAlpha;
import imgui.colorscheme : ColorScheme, defaultColorScheme, RGBA, zenburnColorScheme;
import picker;
import imgui.renderer.opengl33 : Opengl33;
import bindbc.glfw;
import bindbc.opengl;
import std.algorithm : max, min;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, isFile, thisExePath;
import std.path : buildPath, dirName, expandTilde;
import std.string : fromStringz;
import std.uni : byCodePoint, byGrapheme;
import std.utf : codeLength;

private RGBA matchColor()
{
    return defaultColorScheme.item.textMatch;
}

private struct NamedColorScheme
{
    string name;
    ColorScheme colors;
}

private immutable colorSchemes = [
    NamedColorScheme("default", ColorScheme.init),
    NamedColorScheme("zenburn", zenburnColorScheme)
];

private TextSpan[] highlightedText(string text, const(ulong)[] matchedPositions)
{
    TextSpan[] spans;
    size_t graphemeIndex;
    size_t byteOffset;
    size_t matchedIndex;
    size_t runStart;
    bool runHighlighted;
    foreach (grapheme; text.byGrapheme)
    {
        auto highlighted = matchedIndex < matchedPositions.length
            && matchedPositions[matchedIndex] == graphemeIndex;
        if (highlighted)
        {
            ++matchedIndex;
        }
        if (byteOffset != 0 && highlighted != runHighlighted)
        {
            spans ~= TextSpan(text[runStart .. byteOffset], runHighlighted
                    ? matchColor : defaultColorScheme.item.text);
            runStart = byteOffset;
        }
        runHighlighted = highlighted;
        foreach (character; grapheme[])
        {
            byteOffset += codeLength!char(character);
        }
        ++graphemeIndex;
    }
    spans ~= TextSpan(text[runStart .. $], runHighlighted ? matchColor
            : defaultColorScheme.item.text);
    return spans;
}

private string pickerFont(string customFont, string defaultFont)
{
    if (!exists(customFont))
    {
        return defaultFont;
    }
    enforce(isFile(customFont), "The custom picker font is not a regular file: " ~ customFont);
    return customFont;
}

final class PickerWindow
{
    private GLFWwindow* handle;
    private ImGui!Opengl33 gui;
    private Picker picker;
    private Editor editor;
    private Exception callbackFailure;
    private bool initialized;
    private bool replaceQuery;
    private bool choosingColorScheme;
    private double scrollRemainder = 0;
    private LineLayout layout;
    private int width, height;
    private enum headerHeight = Sizes.LINE_HEIGHT + Sizes.DEFAULT_SPACING * 2;
    private enum rowHeight = Sizes.LINE_HEIGHT + Sizes.DEFAULT_SPACING;

    this(Picker picker)
    {
        this.picker = picker;
        scope (failure)
        {
            dispose();
        }
        enforce(loadGLFW() == glfwSupport, "Could not load the GLFW library");
        enforce(glfwInit() != 0, "Could not initialize GLFW");
        initialized = true;
        glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE);
        glfwWindowHint(GLFW_DECORATED, GLFW_FALSE);
        glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
        glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
        glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GLFW_TRUE);
        glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
        handle = glfwCreateWindow(640, 420, "fuzzed", null, null);
        enforce(handle !is null, "Could not create the dimgui OpenGL window");
        glfwSetWindowAttrib(handle, GLFW_RESIZABLE, GLFW_TRUE);
        glfwSetWindowSizeLimits(handle, 240, 140, GLFW_DONT_CARE, GLFW_DONT_CARE);
        glfwSetWindowUserPointer(handle, cast(void*) this);
        glfwSetKeyCallback(handle, &keyCallback);
        glfwSetCharCallback(handle, &charCallback);
        glfwSetScrollCallback(handle, &scrollCallback);
        glfwMakeContextCurrent(handle);
        enforce(loadOpenGL() == GLSupport.gl33, "The picker needs OpenGL 3.3");
        glfwSwapInterval(1);
        gui = new ImGui!Opengl33(pickerFont(expandTilde("~/.config/picker/font.ttf"),
                buildPath(thisExePath.dirName, "DroidSans.ttf")));
        layout = new LineLayout();
        auto monitor = glfwGetPrimaryMonitor();
        if (monitor !is null)
        {
            auto mode = glfwGetVideoMode(monitor);
            if (mode !is null)
            {
                glfwSetWindowPos(handle, max(0, (mode.width - 640) / 2), max(0,
                        (mode.height - 420) / 2));
            }
        }
    }

    void dispose()
    {
        if (handle !is null)
        {
            glfwMakeContextCurrent(handle);
            if (gui !is null)
            {
                // dimgui's driver is GC-managed; finalize it before destroying its context.
                destroy(gui.implementation);
                gui = null;
            }
            glfwDestroyWindow(handle);
            handle = null;
        }
        if (initialized)
        {
            glfwTerminate();
            initialized = false;
        }
    }

    void run()
    {
        glfwShowWindow(handle);
        while (!picker.closed && glfwWindowShouldClose(handle) == 0)
        {
            render();
            glfwWaitEventsTimeout(0.05);
            checkCallbacks();
        }
        checkCallbacks();
    }

    private void checkCallbacks()
    {
        if (callbackFailure !is null)
        {
            throw callbackFailure;
        }
    }

    private MouseInfo mouse()
    {
        int logicalWidth, logicalHeight;
        glfwGetWindowSize(handle, &logicalWidth, &logicalHeight);
        double horizontal, vertical;
        glfwGetCursorPos(handle, &horizontal, &vertical);
        return MouseInfo(cast(int)(horizontal * width / max(1, logicalWidth)),
                height - cast(int)(vertical * height / max(1, logicalHeight)),
                cast(ubyte)(glfwGetMouseButton(handle, GLFW_MOUSE_BUTTON_LEFT) == GLFW_PRESS ? 1 : 0),
                0, 0);
    }

    private void render()
    {
        glfwGetFramebufferSize(handle, &width, &height);
        if (width <= 0 || height <= 0)
        {
            return;
        }
        auto currentMouse = mouse();
        picker.resize(max(1, (height - headerHeight) / rowHeight));
        auto background = defaultColorScheme.generic.background;
        glClearColor(background.r / 255.0, background.g / 255.0, background.b / 255.0, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDisable(GL_DEPTH_TEST);
        dchar unicode;
        gui.frame(currentMouse, width, height, unicode, () {
            addGlobalAlpha(gui.commands, 1);
            gui.state.insideCurrentScroll = currentMouse.y >= 0
                && currentMouse.y < height - headerHeight;
            gui.state.widgetX = Sizes.DEFAULT_SPACING;
            gui.state.widgetY = height - Sizes.DEFAULT_SPACING;
            // Leave room for the gear button right of the search input.
            gui.state.widgetW = width - 2 * Sizes.DEFAULT_SPACING - Sizes.LINE_HEIGHT;
            auto textX = gui.state.widgetX + Sizes.LINE_HEIGHT / 2;
            auto textBaseline = gui.state.widgetY - Sizes.LINE_HEIGHT / 2
                - Sizes.TEXT_HEIGHT / 2 + Sizes.TEXT_BASELINE;
            if (gearButton(width - Sizes.DEFAULT_SPACING - Sizes.LINE_HEIGHT,
                gui.state.widgetY - Sizes.LINE_HEIGHT))
            {
                choosingColorScheme = !choosingColorScheme;
            }
            gui.textInput("", editor, true);
            gui.state.widgetW = width - 2 * Sizes.DEFAULT_SPACING;
            if (editor.buffer.length == 0)
            {
                gui.drawText(textX, textBaseline, TextAlign.left, "Search",
                    defaultColorScheme.textInput.textDisabled);
            }
            gui.pushLayout(layout);
            scope (exit)
            {
                gui.popLayout();
            }
            if (choosingColorScheme)
            {
                foreach (scheme; colorSchemes)
                {
                    if (scheme.colors == defaultColorScheme)
                    {
                        gui.drawRect(gui.state.widgetX, gui.state.widgetY - Sizes.LINE_HEIGHT,
                            gui.state.widgetW, Sizes.LINE_HEIGHT, defaultColorScheme.generic.rect);
                    }
                    if (gui.item(scheme.name))
                    {
                        defaultColorScheme = scheme.colors;
                        choosingColorScheme = false;
                    }
                }
                return;
            }
            auto last = min(picker.count, picker.scrollOffset + picker.visibleRows);
            foreach (index; picker.scrollOffset .. last)
            {
                if (index == picker.selected)
                {
                    gui.drawRect(gui.state.widgetX, gui.state.widgetY - Sizes.LINE_HEIGHT,
                        gui.state.widgetW, Sizes.LINE_HEIGHT, defaultColorScheme.generic.rect);
                }
                if (gui.item(highlightedText(picker.row(index), picker.matchedPositions(index))))
                {
                    picker.choose(index);
                }
            }
            if (picker.count > picker.visibleRows)
            {
                auto availableHeight = height - headerHeight;
                auto thumbHeight = max(12, availableHeight * picker.visibleRows / picker.count);
                auto top = cast(int)(cast(long)(availableHeight - thumbHeight) * picker.scrollOffset / (
                    picker.count - picker.visibleRows));
                gui.drawRect(width - 5, availableHeight - top - thumbHeight, 4,
                    thumbHeight, defaultColorScheme.generic.line);
            }
        });
        gui.render();
        enforce(glGetError() == GL_NO_ERROR, "OpenGL failed to draw the dimgui picker");
        glfwSwapBuffers(handle);
    }

    private bool gearButton(int x, int y)
    {
        gui.state.widgetId++;
        const id = (gui.state.areaId << 16) | gui.state.widgetId;
        enum size = Sizes.LINE_HEIGHT;
        const clicked = gui.state.buttonLogic(id, gui.state.inRect(x, y, size, size, false));
        auto color = gui.state.isIdHot(id) || choosingColorScheme
            ? defaultColorScheme.button.textHover : defaultColorScheme.button.text;
        gui.drawText(x + size / 2, y + size / 2 - Sizes.TEXT_HEIGHT / 2 + Sizes.TEXT_BASELINE,
                TextAlign.center, "\u2699", color);
        return clicked;
    }

    unittest
    {
        auto spans = highlightedText("CAFÉ\tbar", [0, 3, 5]);
        assert(spans == [
            TextSpan("C", matchColor),
            TextSpan("AF", defaultColorScheme.item.text),
            TextSpan("É", matchColor),
            TextSpan("\t", defaultColorScheme.item.text),
            TextSpan("b", matchColor),
            TextSpan("ar", defaultColorScheme.item.text)
        ]);
        assert(highlightedText("aa", [0, 1]) == [TextSpan("aa", matchColor)]);
        assert(highlightedText("plain", []) == [
            TextSpan("plain", defaultColorScheme.item.text)
        ]);
        assert(highlightedText("", []) == [
            TextSpan("", defaultColorScheme.item.text)
        ]);
        assert(highlightedText("noe\u0308l", [2]) == [
            TextSpan("no", defaultColorScheme.item.text),
            TextSpan("e\u0308", matchColor),
            TextSpan("l", defaultColorScheme.item.text)
        ]);
        assert(highlightedText("noe\u0308l", [3]) == [
            TextSpan("noe\u0308", defaultColorScheme.item.text),
            TextSpan("l", matchColor)
        ]);
    }

    private void typeCharacter(dchar character)
    {
        if (character < ' ')
        {
            return;
        }
        if (replaceQuery)
        {
            editor = Editor.init;
            replaceQuery = false;
        }
        editor.insert(character);
        picker.filter(editor.buffer);
    }

    private void key(int key, int modifiers)
    {
        auto command = (modifiers & (GLFW_MOD_CONTROL | GLFW_MOD_SUPER)) != 0;
        if (command && key == GLFW_KEY_Q)
        {
            picker.closed = true;
            return;
        }
        if (command && key == GLFW_KEY_A)
        {
            replaceQuery = true;
            return;
        }
        if (command && key == GLFW_KEY_V)
        {
            auto clipboard = glfwGetClipboardString(handle);
            if (clipboard !is null)
            {
                foreach (character; fromStringz(clipboard).byCodePoint)
                {
                    if (character >= ' ')
                    {
                        typeCharacter(character);
                    }
                }
            }
            return;
        }
        switch (key)
        {
        case GLFW_KEY_UP:
            picker.navigate(Navigation.up);
            break;
        case GLFW_KEY_DOWN:
            picker.navigate(Navigation.down);
            break;
        case GLFW_KEY_PAGE_UP:
            picker.navigate(Navigation.pageUp);
            break;
        case GLFW_KEY_PAGE_DOWN:
            picker.navigate(Navigation.pageDown);
            break;
        case GLFW_KEY_ENTER:
        case GLFW_KEY_KP_ENTER:
            picker.accept();
            break;
        case GLFW_KEY_ESCAPE:
            if (choosingColorScheme)
            {
                choosingColorScheme = false;
                break;
            }
            picker.escape();
            editor = Editor.from(picker.query);
            replaceQuery = false;
            break;
        case GLFW_KEY_LEFT:
            editor.moveLeft();
            break;
        case GLFW_KEY_RIGHT:
            editor.moveRight();
            break;
        case GLFW_KEY_HOME:
            editor.cursor = 0;
            break;
        case GLFW_KEY_END:
            editor.cursor = editor.codePoints.length;
            break;
        case GLFW_KEY_BACKSPACE:
            if (replaceQuery)
            {
                editor = Editor.init;
                replaceQuery = false;
            }
            else
            {
                editor.backspace();
            }
            picker.filter(editor.buffer);
            break;
        case GLFW_KEY_DELETE:
            if (replaceQuery)
            {
                editor = Editor.init;
                replaceQuery = false;
            }
            else if (editor.cursor < editor.codePoints.length)
            {
                editor.moveRight();
                editor.backspace();
            }
            picker.filter(editor.buffer);
            break;
        default:
            break;
        }
    }

    private static PickerWindow owner(GLFWwindow* window) nothrow
    {
        return cast(PickerWindow) glfwGetWindowUserPointer(window);
    }

    private extern (C) static void charCallback(GLFWwindow* window, uint character) nothrow
    {
        auto instance = owner(window);
        try
        {
            instance.typeCharacter(cast(dchar) character);
        }
        catch (Exception failure)
        {
            instance.callbackFailure = failure;
        }
    }

    private extern (C) static void keyCallback(GLFWwindow* window, int key,
            int scanCode, int action, int modifiers) nothrow
    {
        if (action == GLFW_RELEASE)
        {
            return;
        }
        auto instance = owner(window);
        try
        {
            instance.key(key, modifiers);
        }
        catch (Exception failure)
        {
            instance.callbackFailure = failure;
        }
    }

    private extern (C) static void scrollCallback(GLFWwindow* window,
            double horizontal, double vertical) nothrow
    {
        auto instance = owner(window);
        try
        {
            instance.scrollRemainder -= vertical * 3;
            auto rows = cast(int) instance.scrollRemainder;
            instance.scrollRemainder -= rows;
            instance.picker.scroll(rows);
        }
        catch (Exception failure)
        {
            instance.callbackFailure = failure;
        }
    }
}

unittest
{
    import std.exception : assertThrown;
    import std.file : mkdir, remove, rmdir, tempDir, write;
    import std.uuid : randomUUID;

    auto directory = buildPath(tempDir, "dimgui-picker-font-" ~ randomUUID().to!string);
    mkdir(directory);
    scope (exit)
    {
        rmdir(directory);
    }
    auto customFont = buildPath(directory, "font.ttf");
    auto defaultFont = buildPath(directory, "DroidSans.ttf");
    assert(pickerFont(customFont, defaultFont) == defaultFont);
    write(customFont, "font selection fixture");
    scope (exit)
    {
        remove(customFont);
    }
    assert(pickerFont(customFont, defaultFont) == customFont);
    assertThrown!Exception(pickerFont(directory, defaultFont));
}
