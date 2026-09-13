## Apalache, which `quint verify` drives, is not in nixpkgs and could not
## be fetched from a cage anyway; the skill stops at the simulator.
{ pkgs, ... }:
{
  tools = with pkgs; [
    quint
    alloy6
  ];
  src = ./.;
}
