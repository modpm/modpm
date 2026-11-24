module modpm.cli.program;

import std.string : strip;

import cmd.help_command;
import cmd.program;

import modpm.cli.init_cmd;
import modpm.cli.install_cmd;

enum appVersion = import("VERSION").strip;

final class ModpmProgram : Program
{
    this(InitCommand initCommand, InstallCommand installCommand)
    {
        super("modpm");
        description("Package manager for Modrinth projects")
            .versionString(appVersion)
            .versionOption("--version", "Show version information")
            .helpOption("-h, --help", "Show help for command")
            .command(initCommand)
            .command(installCommand)
            .command(new HelpCommand());
    }
}
