{ pkgs, ... }:
{
  tools = [ pkgs.python3Packages.flask ];
  src = ./.;
}
