# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The julia-purifier command.
  julia-purifier = callPackage ./julia-purifier { };
}
