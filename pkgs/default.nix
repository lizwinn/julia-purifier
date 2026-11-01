# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The lock, interactive and register commands.
  julia-purifier = callPackage ./julia-purifier { };
}
