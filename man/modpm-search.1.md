# modpm-search(1) -- Search Modrinth for packages

## SYNOPSIS

`modpm search` [<options>] <terms>...

## DESCRIPTION

Searches Modrinth for the given terms. Inside a scope, only compatible packages
are listed.

## OPTIONS

  * `--limit` <count>:
    Results per page, from 1 to 100. The default is 50.

  * `--page` <number>:
    The page to show. The default is 1.

  * `--sort` <criterion>:
    `relevance`, `downloads`, `follows`, `newest`, or `updated`. The default is
    `relevance`.

  * `--category` <name>:
    Only list packages in this category. Can be repeated or comma-separated;
    packages in any of the given categories are listed.

  * `--no-pager`:
    Print all results directly instead of through a pager.

## ENVIRONMENT

  * `MODPM_SEARCH_LIMIT`:
    The results per page, when `--limit` is not given.

  * `MODPM_SEARCH_SORT`:
    The sort order, when `--sort` is not given.

  * `PAGER`:
    The pager for long results. The default is `less`.

## SEE ALSO

modpm(1)
