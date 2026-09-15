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
    ## The index of the worktree, which the codegraph tools in every
    ## role's pi spawn from PATH (ADR-049). fabriek's own package rather
    ## than one of pkgs, because the catalogue is evaluated on the
    ## operator's host from plain nixpkgs (check.sh) as well as inside
    ## the machine.
    (import ../../../modules/codegraph { inherit pkgs; })
  ];
  skills = [
    skills.tool-missing
    skills.tdd
    skills.ddd
    skills.solid-fp
  ];
  prompt = ./PROMPT.md;
}
