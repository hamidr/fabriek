{ pkgs, specialists, ... }:
{
  extends = [ specialists.developer ];
  tools = with pkgs; [
    ruff
    uv
    python3Packages.pytest
  ];
  prompt = ./PROMPT.md;
}
