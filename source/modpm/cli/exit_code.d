module modpm.cli.exit_code;

enum ExitCode : int
{
    ok = 0,
    failure = 1,
    declined = 3,
}
