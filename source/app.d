module app;

import modpm.cli.console;
import modpm.cli.init_cmd;
import modpm.cli.init_wizard;
import modpm.cli.install_cmd;
import modpm.cli.install_flow;
import modpm.cli.program;
import modpm.cli.progress_view;
import modpm.cli.search_cmd;
import modpm.cli.stage_spinner;
import modpm.cli.step_printer;
import modpm.cli.terminal;
import modpm.cli.tui_prompter;
import modpm.detect;
import modpm.download;
import modpm.fsid;
import modpm.hash;
import modpm.loaders;
import modpm.modrinth;

enum userAgent = "modpm/" ~ appVersion;

void main(string[] args)
{
    auto console = new Console();
    auto api = new ModrinthClient(userAgent);
    auto registry = new LoaderRegistry();
    auto hasher = new FileHasher();
    auto prompter = new TuiPrompter(new Terminal(), console);
    auto wizard = new InitWizard(
        registry,
        api,
        prompter,
        console,
        new FilesystemChecker(),
        new Detector(api, hasher));
    auto downloader = new Downloader(userAgent, hasher, new ProgressView(console));
    auto installFlow = new InstallFlow(registry, api, downloader, hasher, prompter, console, new StepPrinter(console),
        new StageSpinner(console));

    new ModpmProgram(new InitCommand(wizard), new InstallCommand(installFlow),
        new SearchCommand(api, console, registry)).run(args);
}
