module modpm.cli.program;

import cmd.help_command;
import cmd.program;

import modpm.cli.init_cmd;
import modpm.cli.install_cmd;
import modpm.cli.remove_cmd;

enum appVersion = "0.1.0";

final class ModpmProgram : Program
{
    this(InitCommand initCommand, InstallCommand installCommand, RemoveCommand removeCommand)
    {
        super("modpm");
        description("Package manager for Modrinth projects")
            .versionString(appVersion)
            .versionOption("--version", "Show version information")
            .helpOption("-h, --help", "Show help for command")
            .command(initCommand)
            .command(installCommand)
            .command(removeCommand)
            .command(new HelpCommand());
    }
}
