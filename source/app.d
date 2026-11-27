module app;

import modpm.cli.console;
import modpm.cli.init_cmd;
import modpm.cli.install_cmd;
import modpm.cli.remove_cmd;
import modpm.cli.program;
import modpm.cli.progress_view;
import modpm.cli.search_cmd;
import modpm.cli.stage_spinner;
import modpm.cli.step_printer;
import modpm.cli.transaction_executor;
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
    auto downloader = new Downloader(userAgent, hasher, new ProgressView(console));
    auto steps = new StepPrinter(console);
    auto executor = new TransactionExecutor(registry, api, downloader, hasher, prompter, console,
        steps);

    new ModpmProgram(new InitCommand(registry, api, prompter, console, new FilesystemChecker(),
        new Detector(api, hasher)), new InstallCommand(executor, api, new StageSpinner(console)),
        new RemoveCommand(executor), new SearchCommand(api, console, registry)).run(args);
}
