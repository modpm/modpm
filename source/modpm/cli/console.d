module modpm.cli.console;

import std.process : environment;
import std.stdio : stderr, stdout;

version (Windows)
{
    import core.sys.windows.windows;

    enum enableVirtualTerminalProcessing = 0x0004;
}
else version (Posix)
{
    import core.sys.posix.unistd : isatty;
}

final class Console
{
    private bool colors_;

    this()
    {
        colors_ = supportsColor();
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
        return colors_ ? "\x1b]8;;" ~ url ~ "\x1b\\" ~ text ~ "\x1b]8;;\x1b\\" : text;
    }

    private string paint(string code, string text) const
    {
        return colors_ ? "\x1b[" ~ code ~ "m" ~ text ~ "\x1b[39m" : text;
    }

    private static bool supportsColor()
    {
        if (environment.get("NO_COLOR").length)
            return false;

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
