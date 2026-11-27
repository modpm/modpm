# modpm-install(1) -- Install packages and their dependencies

## SYNOPSIS

`modpm install` [<options>] <package>...

## DESCRIPTION

Installs packages and the dependencies they require. Each <package> is a project
slug or ID, optionally followed by `@`<version> to install a specific version.
Modpacks are not supported.

## OPTIONS

  * `--skip-unavailable`:
    Skip packages that can't be installed instead of failing.

  * `--install-suggests`:
    Also install the optional dependencies that are suggested.

  * `-y`, `--yes`:
    Don't ask for confirmation.

## SEE ALSO

modpm(1)
