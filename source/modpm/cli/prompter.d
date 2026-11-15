module modpm.cli.prompter;

class PromptAborted : Exception
{
    this(string msg = "aborted", string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

interface Prompter
{
    size_t select(string question, string[] labels);

    size_t[] multiSelect(string question, string[] labels);

    string text(string question, string delegate(string) complete, string delegate(string) validate);

    bool confirm(string question, bool defaultYes = true);
}
