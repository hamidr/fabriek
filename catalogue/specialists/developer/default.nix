## What every specialist here builds on: the tools an agent reaches for when
## reading a repository and scripting a check, and the prompt that says how
## work is done in a cage.
{ pkgs, skills, ... }:
{
  tools = with pkgs; [
    ripgrep
    fd
    jq
    python3
  ];
  skills = [ skills.tool-missing ];
  prompt = ./PROMPT.md;
}
