{ pkgs, ... }:
{
  tools = [ pkgs.async-profiler ];
  src = ./.;
}
