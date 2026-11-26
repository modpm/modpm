module modpm.cli.pager;

import std.process : environment, pipeProcess, wait, Redirect;
import std.stdio : stdout;
import std.string : split;

/**
 * Writes text through a pager when it is likely to overflow the screen,
 * or directly to stdout otherwise.
 *
 * A custom pager can be set with the PAGER environment variable.
 * Paging is skipped when not attached to a terminal, when `noPager` is
 * set, when the text fits on the screen, or when the pager cannot be
 * started.
 */
void page(string text, bool noPager, bool isTerminal, size_t height)
{
    if (noPager || !isTerminal || fitsOnScreen(text, height))
    {
        stdout.write(text);
        stdout.flush();
        return;
    }

    string[] command = ["less", "-r"];
    immutable customPager = environment.get("PAGER");
    if (customPager.length)
        command = customPager.split();

    try
    {
        auto pipes = pipeProcess(command, Redirect.stdin);
        pipes.stdin.write(text);
        pipes.stdin.close();
        wait(pipes.pid);
    }
    catch (Exception)
    {
        stdout.write(text);
        stdout.flush();
    }
}

private bool fitsOnScreen(string text, size_t height)
{
    size_t lines = 0;
    foreach (ch; text)
        if (ch == '\n')
            lines++;
    if (text.length && text[$ - 1] != '\n')
        lines++;
    return lines <= height;
}
