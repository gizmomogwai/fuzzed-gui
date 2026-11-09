module picker;

import fuzzed.model : Model;
import std.algorithm : min, max;

enum Navigation
{
    up,
    down,
    pageUp,
    pageDown,
    first,
    last
}

/// UI-independent state shared by keyboard, mouse and filtering.
final class Picker
{
    private Model model;
    private int highlighted = -1;
    private int firstVisible;
    private int pageSize = 1;
    string selection;
    bool chosen;
    bool closed;

    this(string[] lines)
    {
        model = new Model();
        model.setData(lines.dup);
        closed = lines.length == 0;
    }

    string query() const
    {
        return model.pattern;
    }

    int selected() const
    {
        return highlighted;
    }

    int scrollOffset() const
    {
        return firstVisible;
    }

    int visibleRows() const
    {
        return pageSize;
    }

    int count() const
    {
        return cast(int) model.matches.length;
    }

    string row(int index) const
    {
        return model.matches[index].value;
    }
    /// Matched grapheme positions supplied by fuzzed's search core.
    const(ulong)[] matchedPositions(int index) const
    {
        return model.matches[index].positions;
    }

    void filter(string query)
    {
        model.update(query);
        highlighted = -1;
        firstVisible = 0;
    }

    void resize(int rows)
    {
        pageSize = max(1, rows);
        firstVisible = min(firstVisible, max(0, count - pageSize));
    }

    void navigate(Navigation direction)
    {
        if (count == 0)
        {
            return;
        }
        final switch (direction)
        {
        case Navigation.down:
            highlighted = min(count - 1, highlighted + 1);
            break;
        case Navigation.up:
            highlighted = max(0, highlighted - 1);
            break;
        case Navigation.pageDown:
            highlighted = min(count - 1, max(0, highlighted) + pageSize);
            firstVisible = min(max(0, count - pageSize), firstVisible + pageSize);
            break;
        case Navigation.pageUp:
            highlighted = max(0, highlighted - pageSize);
            firstVisible = max(0, firstVisible - pageSize);
            break;
        case Navigation.first:
            highlighted = 0;
            break;
        case Navigation.last:
            highlighted = count - 1;
            break;
        }
        firstVisible = min(firstVisible, highlighted);
        if (highlighted >= firstVisible + pageSize)
        {
            firstVisible = highlighted - pageSize + 1;
        }
    }

    void scroll(int rows)
    {
        firstVisible = cast(int) min(max(0L, cast(long) firstVisible + rows),
                max(0, count - pageSize));
    }

    void choose(int index)
    {
        if (index < 0 || index >= count)
        {
            return;
        }
        selection = row(index);
        chosen = true;
        closed = true;
    }

    void accept()
    {
        choose(max(0, highlighted));
    }

    void escape()
    {
        if (query.length != 0)
        {
            filter("");
            return;
        }
        closed = true;
    }
}

unittest
{
    auto picker = new Picker(["banana", "CAFÉ", "  alpaca", "a\tb", ""]);
    picker.filter("an");
    assert(picker.row(0) == "banana");
    assert(picker.matchedPositions(0) == [1, 2]);
    picker.filter("aa");
    assert(picker.count == 2);
    foreach (index; 0 .. picker.count)
    {
        if (picker.row(index) == "banana")
        {
            assert(picker.matchedPositions(index) == [1, 3]);
        }
        else
        {
            assert(picker.row(index) == "  alpaca");
            assert(picker.matchedPositions(index) == [2, 5]);
        }
    }
    picker.filter("c é");
    assert(picker.count == 0);
    picker.filter("cé");
    assert(picker.row(0) == "CAFÉ" && picker.matchedPositions(0) == [0, 3]);
    picker.filter(" a b ");
    assert(picker.count == 0);
    picker.filter("a\tb");
    assert(picker.row(0) == "a\tb" && picker.matchedPositions(0) == [0, 1, 2]);
    picker.filter("");
    assert(picker.count == 5);
    foreach (index; 0 .. picker.count)
    {
        assert(picker.matchedPositions(index).length == 0);
    }
    picker.filter("café");
    picker.accept();
    assert(picker.selection == "CAFÉ");
}

unittest
{
    auto picker = new Picker(["a---b", "ab", "noe\u0308l", "noel"]);
    picker.filter("ab");
    assert(picker.row(0) == "a---b" && picker.row(1) == "ab");
    picker.filter("l");
    assert(picker.row(0) == "noe\u0308l" && picker.matchedPositions(0) == [3]);
    picker.filter("e");
    assert(picker.count == 1 && picker.row(0) == "noel");
    picker.filter("e\u0308");
    assert(picker.count == 1 && picker.row(0) == "noe\u0308l");
    assert(picker.matchedPositions(0) == [2]);
}

unittest
{
    import std.conv : to;

    string[] lines;
    foreach (number; 0 .. 10000)
    {
        lines ~= "line " ~ number.to!string;
    }
    auto picker = new Picker(lines);
    picker.resize(10);
    picker.navigate(Navigation.down);
    picker.navigate(Navigation.pageDown);
    assert(picker.selected == 10 && picker.scrollOffset == 10);
    picker.navigate(Navigation.pageUp);
    assert(picker.selected == 0 && picker.scrollOffset == 0);
    picker.navigate(Navigation.pageUp);
    assert(picker.selected == 0);
    picker.scroll(10000);
    assert(picker.scrollOffset == 9990);
    picker.resize(10001);
    assert(picker.scrollOffset == 0);
    picker.resize(10);
    picker.filter("27");
    assert(picker.row(0) == "line 27" && picker.scrollOffset == 0);
    picker.accept();
    assert(picker.chosen && picker.selection == "line 27");
}

unittest
{
    auto picker = new Picker(["alpha", "beta", "CAFÉ", ""]);
    picker.filter("café");
    assert(picker.count == 1 && picker.row(0) == "CAFÉ");
    picker.escape();
    assert(picker.query == "" && !picker.closed);
    picker.filter("zzz");
    picker.accept();
    assert(!picker.chosen && !picker.closed);
    picker.escape();
    picker.escape();
    assert(picker.closed && !picker.chosen);
    auto empty = new Picker([]);
    assert(empty.closed && !empty.chosen);
    auto blank = new Picker([""]);
    blank.accept();
    assert(blank.chosen && blank.selection == "");
}

unittest
{
    auto picker = new Picker(["alpha", "beta", "gamma", "delta"]);
    picker.resize(2);
    foreach (step; 0 .. 20)
    {
        picker.navigate(Navigation.pageDown);
    }
    assert(picker.selected == 3 && picker.scrollOffset == 2);
    picker.scroll(-10000);
    assert(picker.scrollOffset == 0);
    picker.choose(10000);
    assert(!picker.chosen);
    picker.choose(2);
    assert(picker.chosen && picker.selection == "gamma");
}
