module picker_window;

import picker;
import imgui : ImGui, MouseInfo, Editor, Sizes, LineLayout, TextAlign, TextSpan, Enabled;
import imgui.api : addGlobalAlpha, toPackedRGBA;
import imgui.colorscheme : RGBA, defaultColorScheme;
import imgui.renderer.opengl33 : Opengl33;
import bindbc.glfw;
import bindbc.opengl;
import std.algorithm : min, max;
import std.conv : to;
import std.exception : enforce;
import std.file : thisExePath, exists, isFile;
import std.path : buildPath, dirName, expandTilde;
import std.string : fromStringz;
import std.uni : byCodePoint, byGrapheme;
import std.utf : codeLength;

private enum matchColor = RGBA(255, 200, 90);

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
        auto highlighted = matchedIndex < matchedPositions.length &&
            matchedPositions[matchedIndex] == graphemeIndex;
        if (highlighted)
        {
            ++matchedIndex;
        }
        if (byteOffset != 0 && highlighted != runHighlighted)
        {
            spans ~= TextSpan(text[runStart .. byteOffset],
                runHighlighted ? matchColor : defaultColorScheme.item.text);
            runStart = byteOffset;
        }
        runHighlighted = highlighted;
        foreach (character; grapheme[])
        {
            byteOffset += codeLength!char(character);
        }
        ++graphemeIndex;
    }
    spans ~= TextSpan(text[runStart .. $],
        runHighlighted ? matchColor : defaultColorScheme.item.text);
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
    private double scrollRemainder = 0;
    private LineLayout layout;
    private int width, height;
    private enum headerHeight = Sizes.LINE_HEIGHT + Sizes.DEFAULT_SPACING * 2;
    private enum rowHeight = Sizes.LINE_HEIGHT + Sizes.DEFAULT_SPACING;

    this(Picker picker)
    {
        this.picker = picker;
        scope(failure) dispose();
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
                glfwSetWindowPos(handle, max(0, (mode.width - 640) / 2),
                    max(0, (mode.height - 420) / 2));
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
        return MouseInfo(cast(int) (horizontal * width / max(1, logicalWidth)),
            height - cast(int) (vertical * height / max(1, logicalHeight)),
            cast(ubyte) (glfwGetMouseButton(handle, GLFW_MOUSE_BUTTON_LEFT) == GLFW_PRESS ? 1 : 0),
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
        render(currentMouse);
    }

    private void render(MouseInfo currentMouse, ubyte[] diagnosticPixels = null)
    {
        picker.resize(max(1, (height - headerHeight) / rowHeight));
        glClearColor(0.12, 0.13, 0.15, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glDisable(GL_DEPTH_TEST);
        dchar unicode;
        gui.frame(currentMouse, width, height, unicode, () {
            addGlobalAlpha(gui.commands, 1);
            gui.state.insideCurrentScroll = currentMouse.y >= 0 &&
                currentMouse.y < height - headerHeight;
            gui.state.widgetX = Sizes.DEFAULT_SPACING;
            gui.state.widgetY = height - Sizes.DEFAULT_SPACING;
            gui.state.widgetW = width - 2 * Sizes.DEFAULT_SPACING;
            auto textX = gui.state.widgetX + Sizes.DEFAULT_SPACING * 2;
            auto textBaseline = gui.state.widgetY - Sizes.LINE_HEIGHT / 2 -
                Sizes.TEXT_HEIGHT / 2 + Sizes.TEXT_BASELINE;
            gui.textInput("", editor, true);
            if (editor.buffer.length == 0)
            {
                gui.drawText(textX, textBaseline,
                    TextAlign.left, "Search", RGBA(100, 100, 100, 255));
            }
            gui.pushLayout(layout);
            scope(exit) gui.popLayout();
            auto last = min(picker.count, picker.scrollOffset + picker.visibleRows);
            foreach (index; picker.scrollOffset .. last)
            {
                if (index == picker.selected)
                {
                    gui.drawRect(gui.state.widgetX, gui.state.widgetY - Sizes.LINE_HEIGHT,
                        gui.state.widgetW, Sizes.LINE_HEIGHT, RGBA(65, 100, 145, 255));
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
                auto top = cast(int) (cast(long) (availableHeight - thumbHeight) *
                    picker.scrollOffset / (picker.count - picker.visibleRows));
                gui.drawRect(width - 5, availableHeight - top - thumbHeight, 4, thumbHeight,
                    RGBA(160, 160, 160, 255));
            }
        });
        gui.render();
        if (diagnosticPixels.length != 0)
        {
            glReadBuffer(GL_BACK);
            glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, diagnosticPixels.ptr);
        }
        enforce(glGetError() == GL_NO_ERROR, "OpenGL failed to draw the dimgui picker");
        glfwSwapBuffers(handle);
    }

    unittest
    {
        auto spans = highlightedText("CAFÉ\tbar", [0, 3, 5]);
        assert(spans == [TextSpan("C", matchColor),
            TextSpan("AF", defaultColorScheme.item.text), TextSpan("É", matchColor),
            TextSpan("\t", defaultColorScheme.item.text), TextSpan("b", matchColor),
            TextSpan("ar", defaultColorScheme.item.text)]);
        assert(highlightedText("aa", [0, 1]) == [TextSpan("aa", matchColor)]);
        assert(highlightedText("plain", []) ==
            [TextSpan("plain", defaultColorScheme.item.text)]);
        assert(highlightedText("", []) == [TextSpan("", defaultColorScheme.item.text)]);
        assert(highlightedText("noe\u0308l", [2]) ==
            [TextSpan("no", defaultColorScheme.item.text),
            TextSpan("e\u0308", matchColor), TextSpan("l", defaultColorScheme.item.text)]);
        assert(highlightedText("noe\u0308l", [3]) ==
            [TextSpan("noe\u0308", defaultColorScheme.item.text), TextSpan("l", matchColor)]);
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
            case GLFW_KEY_UP: picker.navigate(Navigation.up); break;
            case GLFW_KEY_DOWN: picker.navigate(Navigation.down); break;
            case GLFW_KEY_PAGE_UP: picker.navigate(Navigation.pageUp); break;
            case GLFW_KEY_PAGE_DOWN: picker.navigate(Navigation.pageDown); break;
            case GLFW_KEY_ENTER:
            case GLFW_KEY_KP_ENTER: picker.accept(); break;
            case GLFW_KEY_ESCAPE:
                picker.escape();
                editor = Editor.from(picker.query);
                replaceQuery = false;
                break;
            case GLFW_KEY_LEFT: editor.moveLeft(); break;
            case GLFW_KEY_RIGHT: editor.moveRight(); break;
            case GLFW_KEY_HOME: editor.cursor = 0; break;
            case GLFW_KEY_END: editor.cursor = editor.codePoints.length; break;
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
            default: break;
        }
    }

    private static PickerWindow owner(GLFWwindow* window) nothrow
    {
        return cast(PickerWindow) glfwGetWindowUserPointer(window);
    }

    private extern(C) static void charCallback(GLFWwindow* window, uint character) nothrow
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

    private extern(C) static void keyCallback(GLFWwindow* window, int key, int scanCode,
        int action, int modifiers) nothrow
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

    private extern(C) static void scrollCallback(GLFWwindow* window, double horizontal,
        double vertical) nothrow
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
    import std.file : tempDir, mkdir, write, remove, rmdir;
    import std.uuid : randomUUID;
    import std.exception : assertThrown;

    auto directory = buildPath(tempDir, "dimgui-picker-font-" ~ randomUUID().to!string);
    mkdir(directory);
    scope(exit) rmdir(directory);
    auto customFont = buildPath(directory, "font.ttf");
    auto defaultFont = buildPath(directory, "DroidSans.ttf");
    assert(pickerFont(customFont, defaultFont) == defaultFont);
    write(customFont, "font selection fixture");
    scope(exit) remove(customFont);
    assert(pickerFont(customFont, defaultFont) == customFont);
    assertThrown!Exception(pickerFont(directory, defaultFont));
}

void verifyNativePicker()
{
    string[] lines;
    foreach (number; 0 .. 10000)
    {
        lines ~= "line " ~ number.to!string;
    }
    auto picker = new Picker(lines);
    auto window = new PickerWindow(picker);
    scope(exit) window.dispose();
    enforce(glfwGetWindowAttrib(window.handle, GLFW_DECORATED) == GLFW_FALSE,
        "The picker must not have a native title bar or window buttons");
    enforce(glfwGetWindowAttrib(window.handle, GLFW_RESIZABLE) == GLFW_TRUE,
        "The borderless picker must remain resizable");
    glfwShowWindow(window.handle);
    glfwPollEvents();
    window.render();
    int[2] searchPosition()
    {
        foreach (command; window.gui.commands[])
        {
            if (command.type == typeof(command.type).TEXT && command.text.text == "Search")
            {
                return [command.text.x, command.text.y];
            }
        }
        enforce(false, "The search text was not drawn");
        return [0, 0];
    }
    auto placeholderPosition = searchPosition();
    foreach (character; "Search")
    {
        PickerWindow.charCallback(window.handle, character);
    }
    window.render();
    auto enteredPosition = searchPosition();
    enforce(placeholderPosition == enteredPosition,
        "Search placeholder and entered text have different positions: " ~
        placeholderPosition.to!string ~ " versus " ~ enteredPosition.to!string);
    window.key(GLFW_KEY_ESCAPE, 0);
    window.render();
    auto pixels = new ubyte[cast(size_t) window.width * window.height * 4];
    window.render(window.mouse(), pixels);
    enforce(glGetError() == GL_NO_ERROR, "Could not read the native dimgui drawable");
    size_t brightPixels;
    foreach (index; 0 .. pixels.length / 4)
    {
        if (pixels[index * 4] > 100)
        {
            ++brightPixels;
        }
    }
    enforce(brightPixels > 100, "The native dimgui window is blank");
    window.key(GLFW_KEY_DOWN, 0);
    window.key(GLFW_KEY_PAGE_DOWN, 0);
    enforce(picker.scrollOffset > 0, "Page Down did not scroll");
    window.key(GLFW_KEY_PAGE_UP, 0);
    enforce(picker.scrollOffset == 0, "Page Up did not return");
    foreach (step; 0 .. 4)
    {
        PickerWindow.scrollCallback(window.handle, 0, -0.1);
    }
    enforce(picker.scrollOffset == 1, "Fractional trackpad scrolling was lost");
    PickerWindow.scrollCallback(window.handle, 0, -10000);
    enforce(picker.scrollOffset == picker.count - picker.visibleRows,
        "Wheel scrolling did not reach the last result");
    PickerWindow.charCallback(window.handle, '2');
    PickerWindow.charCallback(window.handle, '7');
    window.checkCallbacks();
    enforce(picker.row(0) == "line 27" && picker.scrollOffset == 0, "Fuzzy filtering failed");
    glfwSetWindowSize(window.handle, 480, 320);
    glfwPollEvents();
    window.render();
    int logicalWidth, logicalHeight;
    glfwGetWindowSize(window.handle, &logicalWidth, &logicalHeight);
    enforce(logicalWidth == 480 && logicalHeight == 320,
        "The picker window did not resize");
    enforce(picker.query == "27", "Resize lost the query");
    bool matchedRowDrawn;
    foreach (command; window.gui.commands[])
    {
        if (command.type == typeof(command.type).TEXT && command.text.text == "line 27")
        {
            auto normalColor = defaultColorScheme.item.text.toPackedRGBA();
            enforce(command.text.characterColors == [normalColor, normalColor,
                normalColor, normalColor, normalColor, matchColor.toPackedRGBA(),
                matchColor.toPackedRGBA()], "The filtered row highlights the wrong characters");
            matchedRowDrawn = true;
        }
    }
    enforce(matchedRowDrawn, "The highlighted result was not drawn after resizing");
    auto highlightedPixels = new ubyte[cast(size_t) window.width * window.height * 4];
    window.render(window.mouse(), highlightedPixels);
    enforce(glGetError() == GL_NO_ERROR, "Could not read highlighted text pixels");
    size_t coloredPixels;
    foreach (index; 0 .. highlightedPixels.length / 4)
    {
        if (highlightedPixels[index * 4] > 180 &&
            highlightedPixels[index * 4 + 1] > 130 &&
            highlightedPixels[index * 4 + 1] < 230 &&
            highlightedPixels[index * 4 + 2] < 120)
        {
            ++coloredPixels;
        }
    }
    enforce(coloredPixels > 5, "Matched characters are not visibly highlighted");
    auto headerMouse = MouseInfo(40, window.height - 20, 0, 0, 0);
    window.render(headerMouse);
    headerMouse.buttons = 1;
    window.render(headerMouse);
    headerMouse.buttons = 0;
    window.render(headerMouse);
    enforce(!picker.chosen, "The fixed search header selected a result");
    window.key(GLFW_KEY_HOME, 0);
    window.key(GLFW_KEY_DELETE, 0);
    enforce(picker.query == "7", "Delete did not edit the query at the cursor");
    window.key(GLFW_KEY_BACKSPACE, 0);
    enforce(picker.query == "7", "Backspace at the start changed the query");
    window.key(GLFW_KEY_ESCAPE, 0);
    enforce(!picker.closed && picker.query == "", "Escape did not clear the query");
    window.render();
    foreach (command; window.gui.commands[])
    {
        if (command.type == typeof(command.type).TEXT)
        {
            foreach (color; command.text.characterColors)
            {
                enforce(color != matchColor.toPackedRGBA(),
                    "Clearing the query left stale match highlights");
            }
        }
    }
    PickerWindow.charCallback(window.handle, '2');
    PickerWindow.charCallback(window.handle, '7');
    window.render();
    auto rowMouse = MouseInfo(40, window.height - PickerWindow.headerHeight - 20, 0, 0, 0);
    window.render(rowMouse);
    rowMouse.buttons = 1;
    window.render(rowMouse);
    rowMouse.buttons = 0;
    window.render(rowMouse);
    enforce(picker.chosen && picker.selection == "line 27", "Click did not select the filtered row");
    auto keyboardPicker = new Picker(["alpha", "beta"]);
    window.picker = keyboardPicker;
    window.editor = Editor.init;
    foreach (character; "beta")
    {
        PickerWindow.charCallback(window.handle, character);
    }
    window.key(GLFW_KEY_ENTER, 0);
    enforce(keyboardPicker.chosen && keyboardPicker.selection == "beta",
        "Enter did not accept the filtered line");
    auto cancelledPicker = new Picker(["alpha", "beta"]);
    window.picker = cancelledPicker;
    window.key(GLFW_KEY_ESCAPE, 0);
    enforce(cancelledPicker.closed && !cancelledPicker.chosen, "Escape did not cancel");

    ubyte[] itemPixels(bool styled)
    {
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        window.gui.state.hotToBe = 0;
        window.gui.state.active = 0;
        dchar unicode;
        window.gui.frame(MouseInfo(-1, -1, 0, 0, 0), window.width, window.height,
            unicode, () {
                addGlobalAlpha(window.gui.commands, 1);
                window.gui.state.widgetX = 20;
                window.gui.state.widgetY = window.height - 20;
                window.gui.state.widgetW = window.width - 40;
                window.gui.pushLayout(window.layout);
                scope(exit) window.gui.popLayout();
                auto white = RGBA(255, 255, 255);
                if (styled)
                {
                    window.gui.item([TextSpan(" A", white), TextSpan("é", matchColor),
                        TextSpan("\t", white), TextSpan("B", matchColor)]);
                }
                else
                {
                    auto colorScheme = defaultColorScheme;
                    colorScheme.item.text = white;
                    window.gui.item(" Aé\tB", Enabled.yes, colorScheme);
                }
            });
        window.gui.render();
        auto pixels = new ubyte[cast(size_t) window.width * window.height * 4];
        glReadPixels(0, 0, window.width, window.height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.ptr);
        enforce(glGetError() == GL_NO_ERROR, "Could not read styled item geometry");
        return pixels;
    }
    auto plainPixels = itemPixels(false);
    auto styledPixels = itemPixels(true);
    bool colorChanged;
    foreach (index; 0 .. plainPixels.length / 4)
    {
        enforce(plainPixels[index * 4] == styledPixels[index * 4],
            "Colored spans changed glyph positions or tab stops");
        colorChanged |= plainPixels[index * 4 + 1] != styledPixels[index * 4 + 1];
    }
    enforce(colorChanged, "Styled item spans did not change rendered text colors");
}
