{ pkgs, ... }:
{
  tools = [ pkgs.python3Packages.django ];
  src = ./.;
}
