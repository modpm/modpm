# modpm(1) -- Package manager for Modrinth projects

## SYNOPSIS

`modpm` [`-h`|`--help`] [`--version`]<br>
`modpm` <command> [<options>] [<arguments>]<br>
`modpm help` [<command>...]

## DESCRIPTION

**modpm** manages Modrinth projects in a _scope_: a directory with its own
configuration of loaders, game version, environment, and release channels. A
scope is created with modpm-init(1) and found by looking in the current
directory and then in its parents.

## COMMANDS

  * `init`:
    Create a modpm scope in the current directory.

  * `install`:
    Install packages and their dependencies.

  * `remove`:
    Remove packages and the dependencies nothing else uses.

  * `search`:
    Search Modrinth for packages.

  * `help` [<command>...]:
    Show help for a command.

## OPTIONS

  * `-h`, `--help`:
    Show help for the command.

  * `--version`:
    Show the version.

## ENVIRONMENT

  * `NO_COLOR`:
    Disables colors when set to a non-empty value.

  * `LINES`, `COLUMNS`:
    The terminal height and width, when they can't be queried. They default to
    24 and 80.

## FILES

  * `.modpm`:
    Created by modpm-init(1) in the scope directory. It holds the configuration
    of the scope and its installed packages.

## EXIT STATUS

  * `0`:
    Success.

  * `1`:
    Failure.

  * `2`:
    Invalid command line.

  * `3`:
    Declined at a confirmation prompt.

## SEE ALSO

modpm-init(1), modpm-install(1), modpm-remove(1), modpm-search(1)
