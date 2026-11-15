module modpm.cli.program;

import cmd.help_command;
import cmd.program;

import modpm.cli.init_cmd;

enum appVersion = "0.1.0";

final class ModpmProgram : Program
{
    this(InitCommand initCommand)
    {
        super("modpm");
        description("Package manager for Modrinth projects")
            .versionString(appVersion)
            .versionOption("--version", "Show version information")
            .helpOption("-h, --help", "Show help for command")
            .command(initCommand)
            .command(new HelpCommand());
    }
}
