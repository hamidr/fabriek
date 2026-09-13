{ pkgs, ... }:
{
  tools = [ pkgs.maven ];
  src = ./.;
}
