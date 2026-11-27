module modpm.cli.pager;

import std.process : environment, pipeProcess, wait, Redirect;
import std.stdio : stdout;
import std.string : split;

/**
 * Writes text through a pager, or directly to stdout otherwise.
 *
 * A custom pager can be set with the PAGER environment variable.
 * Paging is skipped when not attached to a terminal, when `noPager` is
 * set, or when the pager cannot be started.
 */
void page(string title, string text, bool noPager, bool isTerminal)
{
    if (noPager || !isTerminal)
    {
        stdout.write(text);
        stdout.flush();
        return;
    }

    string[] command = ["less"];
    immutable customPager = environment.get("PAGER");
    if (customPager.length)
        command = customPager.split();

    try
    {
        string[string] env;
        if (!environment.get("LESS").length)
            env["LESS"] = "FrPs" ~ title ~ " ?ltline %lt?e (END). (press h for help or q to quit)";

        auto pipes = pipeProcess(command, Redirect.stdin, env);
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
