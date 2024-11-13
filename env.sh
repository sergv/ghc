#! /usr/bin/env bash
#
# File: env.sh
#
# Created: 18 December 2022
#

# source env.sh

function mk {
    if [[ "${RUNNING_UNDER_NIX:-0}" != 1 ]]; then
        nix --no-warn-dirty develop -c hadrian/build "${@}"
    else
        hadrian/build "${@}"
    fi
}
