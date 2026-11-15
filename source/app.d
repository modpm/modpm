module app;

import modpm.cli.console;
import modpm.cli.init_cmd;
import modpm.cli.init_wizard;
import modpm.cli.program;
import modpm.cli.terminal;
import modpm.cli.tui_prompter;
import modpm.detect;
import modpm.fsid;
import modpm.hash;
import modpm.loaders;
import modpm.modrinth;

enum userAgent = "modpm/" ~ appVersion;

void main(string[] args)
{
    auto console = new Console();
    auto api = new ModrinthClient(userAgent);
    auto wizard = new InitWizard(
        new LoaderRegistry(),
        api,
        new TuiPrompter(new Terminal(), console),
        console,
        new FilesystemChecker(),
        new Detector(api, new FileHasher()));

    new ModpmProgram(new InitCommand(wizard)).run(args);
}
