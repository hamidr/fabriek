{ pkgs, ... }:
{
  tools = with pkgs; [
    sbt
    scalafmt
  ];
  src = ./.;
}
