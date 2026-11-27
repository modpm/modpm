# modpm-init(1) -- Create a modpm scope in the current directory

## SYNOPSIS

`modpm init` [<options>]

## DESCRIPTION

Creates a scope in the current directory. Values not given as options are
prompted for.

If the packages directory already contains files, modpm can identify and import
them, so they become managed packages. This is called adopting.

Fails if the current directory is already a scope. Inside another scope, asks
whether to create a nested one.

## OPTIONS

  * `--loader` <id>:
    A loader or platform. Can be repeated; all must be of the same kind. See
    [LOADERS][].

  * `--side` <side>:
    `client` or `server`, depending on the kind. See [LOADERS][].

  * `--game-version` <version>:
    The game version, e.g. `1.21.1`.

  * `--channel` <channel>:
    The least stable release channel allowed: `release`, `beta`, or `alpha`.

  * `--dir` <path>:
    The directory the packages are kept in. It must be on the same filesystem as
    the current directory.

  * `--adopt`:
    Identify and import the files already in the directory. Fails if a file's
    required dependencies are not in the directory, or if several files are the
    same project.

  * `--no-adopt`:
    Don't import the files already in the directory.

  * `--no-prompt`:
    Never prompt; fail if a value is missing. A nested scope is created without
    asking.

## LOADERS

  * Mods (`.jar`, client or server):
    `babric`, `bta-babric`, `fabric`, `forge`, `java-agent`, `legacy-fabric`,
    `liteloader`, `modloader`, `neoforge`, `nilloader`, `ornithe`, `quilt`,
    `rift`

  * Plugins (`.jar`, server):
    `bukkit`, `bungeecord`, `folia`, `geyser`, `paper`, `purpur`, `spigot`,
    `sponge`, `velocity`, `waterfall`

  * Data packs (`.zip`, server):
    `datapack`

  * Resource packs (`.zip`, client):
    `minecraft`

  * Shaders (`.zip`, client):
    `canvas`, `iris`, `optifine`, `vanilla`

## SEE ALSO

modpm(1)
