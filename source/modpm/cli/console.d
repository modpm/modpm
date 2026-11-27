module modpm.cli.console;

import std.conv : to;
import std.process : environment;
import std.stdio : stderr, stdout;

version (Windows)
{
    import core.sys.windows.windows;

    enum enableVirtualTerminalProcessing = 0x0004;
}
else version (Posix)
{
    import core.sys.posix.sys.ioctl : TIOCGWINSZ, ioctl, winsize;
    import core.sys.posix.unistd : isatty;
}

final class Console
{
    private bool colors_;
    private bool escapes_;
    private bool terminal_;

    this()
    {
        version (Windows)
            SetConsoleOutputCP(65001);
        terminal_ = isTerminal();
        escapes_ = supportsEscapes();
        colors_ = escapes_ && environment.get("NO_COLOR").length == 0;
    }

    @property bool terminal() const
    {
        return terminal_;
    }

    @property size_t height() const
    {
        version (Posix)
        {
            winsize size;
            if (ioctl(1, TIOCGWINSZ, &size) == 0 && size.ws_row > 0)
                return size.ws_row;
        }
        else version (Windows)
        {
            CONSOLE_SCREEN_BUFFER_INFO info;
            if (GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &info))
                return cast(size_t)(info.srWindow.Bottom - info.srWindow.Top + 1);
        }

        immutable lines = environment.get("LINES");
        if (lines.length)
        {
            try
                return lines.to!size_t;
            catch (Exception)
            {
            }
        }
        return 24;
    }

    @property size_t width() const
    {
        version (Posix)
        {
            winsize size;
            if (ioctl(1, TIOCGWINSZ, &size) == 0 && size.ws_col > 0)
                return size.ws_col;
        }
        else version (Windows)
        {
            CONSOLE_SCREEN_BUFFER_INFO info;
            if (GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &info))
                return cast(size_t)(info.srWindow.Right - info.srWindow.Left + 1);
        }

        immutable columns = environment.get("COLUMNS");
        if (columns.length)
        {
            try
                return columns.to!size_t;
            catch (Exception)
            {
            }
        }
        return 80;
    }

    void write(string text)
    {
        stdout.write(text);
        stdout.flush();
    }

    void line(string text = "")
    {
        stdout.writeln(text);
    }

    void errorLine(string text)
    {
        stderr.writeln(text);
    }

    string bold(string text) const
    {
        return "\x1b[1m" ~ text ~ "\x1b[22m";
    }

    string dim(string text) const
    {
        return "\x1b[2m" ~ text ~ "\x1b[22m";
    }

    string grey(string text) const
    {
        return colors_ ? "\x1b[90m" ~ text ~ "\x1b[39m" : "\x1b[2m" ~ text ~ "\x1b[22m";
    }

    string red(string text) const
    {
        return paint("31", text);
    }

    string green(string text) const
    {
        return paint("32", text);
    }

    string yellow(string text) const
    {
        return paint("33", text);
    }

    string highlight(string text) const
    {
        return colors_ ? "\x1b[30;42m" ~ text ~ "\x1b[39;49m" : "\x1b[7m" ~ text ~ "\x1b[27m";
    }

    string link(string url, string text) const
    {
        return escapes_ ? "\x1b]8;;" ~ url ~ "\x1b\\" ~ text ~ "\x1b]8;;\x1b\\" : text;
    }

    private string paint(string code, string text) const
    {
        return colors_ ? "\x1b[" ~ code ~ "m" ~ text ~ "\x1b[39m" : text;
    }

    private static bool isTerminal()
    {
        version (Posix)
        {
            return isatty(1) != 0;
        }
        else version (Windows)
        {
            DWORD mode;
            return GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &mode) != 0;
        }
        else
            return false;
    }

    private static bool supportsEscapes()
    {
        version (Posix)
        {
            return isatty(1) != 0;
        }
        else version (Windows)
        {
            HANDLE handle = GetStdHandle(STD_OUTPUT_HANDLE);
            DWORD mode;
            if (!GetConsoleMode(handle, &mode))
                return false;
            return SetConsoleMode(handle, mode | enableVirtualTerminalProcessing) != 0;
        }
        else
            return false;
    }
}
