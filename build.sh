#! /usr/bin/env bash
#
# File: build.sh
#
# Created:  4 December 2022
#

# treat undefined variable substitutions as errors
set -u
# propagate errors from all parts of pipes
set -o pipefail

source env.sh

# nix develop -c ./boot

# mk -j --bignum=native --flavour=quick+no_profiled_libs

builddir_to_use="_build"

# builddir="/tmp/ghc-build-$(cat VERSION)"
#
# mkdir -p "$builddir"
#
# ln -s "$builddir" "$builddir_to_use"

    # # --skip-depends \
# #--freeze1
# mk \
#     --build-root="$builddir_to_use" \
#     -j16 \
#     --digest \
#     --docs=none \
#     --bignum=native \
#     --flavour=quick+no_profiled_libs \
#     --progress-info=brief \
#     "${@}"


do_build () {
    mk \
        --build-root="$builddir_to_use" \
        -j16 \
        --digest \
        --docs=none \
        --bignum=native \
        --flavour=quick+no_profiled_libs \
        --progress-info=brief \
        "${@}"
    # --freeze1 \
}

#     # --skip-depends \
# #--freeze1
# if [[ "$#" = 0 ]]; then
#     do_build "$builddir_to_use/stage1/bin/"{ghc,ghc-pkg}
#     # do_build "$builddir_to_use/stage2/bin/"{ghc,ghc-pkg}
# else
# fi

    do_build "${@}"


# \
#     --share=/tmp/ghc-build-cache
# \
#     "$builddir_to_use/stage1/bin/"{ghc,ghc-pkg}

    # _build/stage2/bin/{ghc,ghc-pkg}

# --share <- TODO

    # stage1:exe:check-exact \
    # stage1:exe:check-ppr \
    # stage1:exe:compareSizes \
    # stage1:exe:count-deps \
    # stage1:exe:deriveConstants \
    # stage1:exe:genapply \
    # stage1:exe:genprimopcode \
    # stage1:exe:ghc-bin \
    # stage1:exe:ghc-config \
    # stage1:exe:ghc-pkg \
    # stage1:exe:ghci-wrapper \
    # stage1:exe:haddock \
    # stage1:exe:hp2ps \
    # stage1:exe:hpc-bin \
    # stage1:exe:hsc2hs \
    # stage1:exe:iserv \
    # stage1:exe:lint-commit-msg \
    # stage1:exe:lint-notes \
    # stage1:exe:lint-submodule-refs \
    # stage1:exe:lint-whitespace \
    # stage1:exe:runghc \
    # stage1:exe:timeout \
    # stage1:exe:touchy \
    # stage1:exe:unlit


    # --prefix=/home/sergey/projects/haskell/ghc/ghc-9.4.3-redundant-libffi-linking-investigation \
    # install

exit 0

