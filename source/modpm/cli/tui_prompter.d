module modpm.cli.tui_prompter;

import std.algorithm.comparison : max;
import std.algorithm.searching : startsWith;
import std.array : join, replicate;
import std.conv : to;
import std.format : format;
import std.utf : count;

import modpm.cli.console;
import modpm.cli.prompter;
import modpm.cli.terminal;

final class TuiPrompter : Prompter
{
    private enum clearLine = "\r\x1b[2K";
    private enum hideCursor = "\x1b[?25l";
    private enum showCursor = "\x1b[?25h";

    private Terminal terminal_;
    private Console console_;

    this(Terminal terminal, Console console)
    {
        terminal_ = terminal;
        console_ = console;
    }

    size_t select(string question, string[] labels)
    {
        return pick(question, labels, false)[0];
    }

    size_t[] multiSelect(string question, string[] labels)
    {
        return pick(question, labels, true);
    }

    string text(string question, string delegate(string) complete,
        string delegate(string) validate)
    {
        dchar[] buffer;
        size_t position;
        string error;
        immutable promptWidth = (question ~ ": ").count;
        immutable prompt = heading(question) ~ " ";

        terminal_.enterRaw();
        scope (exit)
            terminal_.leaveRaw();
        console_.write("\n\x1b[A");

        while (true)
        {
            immutable typed = buffer.to!string;
            immutable ghost = ghostFor(typed, position == buffer.length, complete);
            immutable column = promptWidth + position;
            console_.write(clearLine ~ prompt ~ typed ~ (ghost.length ? console_.grey(ghost) : "")
                    ~ "\n" ~ clearLine ~ console_.red(error) ~ "\x1b[A\r"
                    ~ (column > 0 ? format("\x1b[%dC", column) : ""));

            immutable press = terminal_.readKey();
            error = "";
            switch (press.key)
            {
            case Key.character:
                {
                    if (press.character >= ' ')
                    {
                        buffer = buffer[0 .. position] ~ press.character ~ buffer[position .. $];
                        position++;
                    }
                    break;
                }
            case Key.backspace:
                {
                    if (position > 0)
                    {
                        buffer = buffer[0 .. position - 1] ~ buffer[position .. $];
                        position--;
                    }
                    break;
                }
            case Key.delete_:
                {
                    if (position < buffer.length)
                        buffer = buffer[0 .. position] ~ buffer[position + 1 .. $];
                    break;
                }
            case Key.left:
                {
                    if (position > 0)
                        position--;
                    break;
                }
            case Key.right:
                {
                    if (position < buffer.length)
                        position++;
                    else if (ghost.length)
                    {
                        buffer = (typed ~ ghost).to!(dchar[]);
                        position = buffer.length;
                    }
                    break;
                }
            case Key.tab:
                {
                    if (ghost.length)
                    {
                        buffer = (typed ~ ghost).to!(dchar[]);
                        position = buffer.length;
                    }
                    break;
                }
            case Key.home:
                {
                    position = 0;
                    break;
                }
            case Key.end:
                {
                    position = buffer.length;
                    break;
                }
            case Key.clearLine:
                {
                    buffer = buffer[position .. $].dup;
                    position = 0;
                    break;
                }
            case Key.enter:
                {
                    immutable problem = validate is null ? "" : validate(typed);
                    if (problem.length)
                    {
                        error = problem;
                        break;
                    }
                    console_.write(clearLine ~ heading(question) ~ " "
                            ~ typed ~ "\n" ~ clearLine);
                    return typed;
                }
            case Key.interrupt:
                {
                    console_.write(clearLine ~ "\n" ~ clearLine);
                    throw new PromptAborted();
                }
            default:
                break;
            }
        }
    }

    bool confirm(string question, bool defaultYes = true)
    {
        immutable hint = defaultYes ? "[Y/n]" : "[y/N]";

        terminal_.enterRaw();
        scope (exit)
            terminal_.leaveRaw();
        console_.write(clearLine ~ console_.green(console_.bold(question)) ~ " " ~ hint ~ ": ");

        while (true)
        {
            immutable press = terminal_.readKey();
            switch (press.key)
            {
            case Key.enter:
                return answered(question, defaultYes);
            case Key.character:
                {
                    if (press.character == 'y' || press.character == 'Y')
                        return answered(question, true);
                    if (press.character == 'n' || press.character == 'N')
                        return answered(question, false);
                    break;
                }
            case Key.interrupt:
                {
                    console_.write("\n");
                    throw new PromptAborted();
                }
            default:
                break;
            }
        }
    }

    private bool answered(string question, bool answer)
    {
        console_.write(clearLine ~ heading(question) ~ " "
                ~ (answer ? "Yes" : "No") ~ "\n");
        return answer;
    }

    private size_t[] pick(string question, string[] labels, bool multiple)
    {
        auto checked = new bool[labels.length];
        size_t cursor = 0;
        string status;
        immutable hint = multiple
            ? "↑/↓, Space to toggle, Enter to confirm" : "↑/↓, Enter to select";
        immutable lines = labels.length + (multiple ? 2 : 1);
        size_t labelWidth = 0;
        foreach (label; labels)
            labelWidth = max(labelWidth, label.count);

        terminal_.enterRaw();
        console_.write(hideCursor);
        scope (exit)
        {
            console_.write(showCursor);
            terminal_.leaveRaw();
        }

        bool firstDraw = true;
        while (true)
        {
            string block = clearLine ~ heading(question) ~ " " ~ console_.dim(hint) ~ "\n";
            foreach (i, label; labels)
            {
                immutable padding = " ".replicate(labelWidth - label.count);
                immutable mark = checked[i] ? "■" : "□";
                string row;
                if (i == cursor)
                    row = console_.highlight(" " ~ (multiple ? mark ~ " " : "") ~ label ~ padding ~ " ");
                else
                    row = " " ~ (multiple ? (checked[i] ? console_.green(mark) : mark) ~ " " : "")
                        ~ label ~ padding ~ " ";
                block ~= clearLine ~ "  " ~ row ~ "\n";
            }
            if (multiple)
                block ~= clearLine ~ console_.red(status) ~ "\n";
            console_.write((firstDraw ? "" : format("\x1b[%dA", lines)) ~ block);
            firstDraw = false;

            immutable press = terminal_.readKey();
            status = "";
            switch (press.key)
            {
            case Key.up:
                {
                    cursor = (cursor + labels.length - 1) % labels.length;
                    break;
                }
            case Key.down:
                {
                    cursor = (cursor + 1) % labels.length;
                    break;
                }
            case Key.home:
                {
                    cursor = 0;
                    break;
                }
            case Key.end:
                {
                    cursor = labels.length - 1;
                    break;
                }
            case Key.character:
                {
                    if (multiple && press.character == ' ')
                        checked[cursor] = !checked[cursor];
                    break;
                }
            case Key.enter:
                {
                    size_t[] chosen;
                    if (multiple)
                    {
                        foreach (i, isChecked; checked)
                            if (isChecked)
                                chosen ~= i;
                        if (chosen.length == 0)
                        {
                            status = "Select at least one option.";
                            break;
                        }
                    }
                    else
                        chosen = [cursor];

                    string[] names;
                    foreach (index; chosen)
                        names ~= labels[index];
                    console_.write(format("\x1b[%dA", lines) ~ "\x1b[J" ~ heading(question)
                            ~ " " ~ names.join(", ") ~ "\n");
                    return chosen;
                }
            case Key.interrupt:
                {
                    console_.write(format("\x1b[%dA", lines) ~ "\x1b[J");
                    throw new PromptAborted();
                }
            default:
                break;
            }
        }
    }

    private string heading(string question)
    {
        return console_.green(console_.bold(question ~ ":"));
    }

    private static string ghostFor(string typed, bool atEnd, string delegate(string) complete)
    {
        if (!atEnd || typed.length == 0 || complete is null)
            return "";
        immutable suggestion = complete(typed);
        if (suggestion.length > typed.length && suggestion.startsWith(typed))
            return suggestion[typed.length .. $];
        return "";
    }
}
