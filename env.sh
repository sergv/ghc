#! /usr/bin/env bash
#
# File: env.sh
#
# Created: 18 December 2022
#

# source env.sh

function mk {
    if [[ -z "${IN_NIX_SHELL-}" ]]; then
        nix --no-warn-dirty develop -c hadrian/build "${@}"
    else
        hadrian/build "${@}"
    fi
}
