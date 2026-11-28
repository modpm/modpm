module modpm.cli.program;

import std.string : strip;

import cmd.completion_command;
import cmd.help_command;
import cmd.program;

import modpm.cli.init_cmd;
import modpm.cli.install_cmd;
import modpm.cli.remove_cmd;
import modpm.cli.search_cmd;

enum appVersion = import("VERSION").strip;

final class ModpmProgram : Program
{
    this(InitCommand initCommand, InstallCommand installCommand, RemoveCommand removeCommand, SearchCommand searchCommand)
    {
        super("modpm");
        description("Package manager for Modrinth projects")
            .versionString(appVersion)
            .versionOption("--version", "Show version information")
            .helpOption("-h, --help", "Show help for command")
            .command(initCommand)
            .command(installCommand)
            .command(removeCommand)
            .command(searchCommand)
            .command(new CompletionCommand())
            .command(new HelpCommand());
    }
}
