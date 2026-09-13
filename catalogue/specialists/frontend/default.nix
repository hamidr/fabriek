{ pkgs, specialists, ... }:
{
  extends = [ specialists.developer ];
  tools = with pkgs; [
    nodejs_22
    pnpm
  ];
  prompt = ./PROMPT.md;
}
