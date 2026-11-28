module modpm.cli.pager;

import std.format : format;
import std.process : environment, pipeShell, wait, Redirect;
import std.stdio : stdout;

/**
 * Writes text through a pager, or directly to stdout otherwise.
 *
 * A custom pager can be set with the PAGER environment variable.
 * Paging is skipped when not attached to a terminal or when `noPager` is set.
 */
void page(string title, string text, bool noPager, bool isTerminal)
{
    if (noPager || !isTerminal)
    {
        stdout.write(text);
        stdout.flush();
        return;
    }

    immutable customPager = environment.get("PAGER");
    immutable pager = customPager.length ? customPager : "less";

    string[string] env;
    if (!environment.get("LESS").length)
        env["LESS"] = "FrPs" ~ title ~ " ?ltline %lt?e (END). (press h for help or q to quit)";

    auto pipes = pipeShell(pager, Redirect.stdin, env);
    pipes.stdin.write(text);
    pipes.stdin.close();
    immutable status = wait(pipes.pid);
    if (status != 0)
        throw new Exception(format("pager '%s' exited with status %s", pager, status));
}
