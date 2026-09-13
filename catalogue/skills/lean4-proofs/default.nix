## Core Lean only: mathlib is fetched by lake, and a cage fetches nothing.
{ pkgs, ... }:
{
  tools = [ pkgs.lean4 ];
  src = ./.;
}
