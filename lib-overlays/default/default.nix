# SPDX-License-Identifier: MIT
#
# The `julia-purifier` library namespace. It holds nothing: the builder
# needs a package set, so it is the package `buildJuliaProject` that the
# default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    julia-purifier = prev.julia-purifier or { };
  };

}
