## What every specialist here builds on: whoever works in a worktree of a
## repository they did not write, with the tools for reading it and
## scripting a check, whatever they then do there. The builders extend
## developer; the roles that write no code extend this and nothing else.
{ pkgs, skills, ... }:
{
  tools = with pkgs; [
    ripgrep
    fd
    jq
    python3
    ## The index of the worktree, which the codegraph tools in every
    ## role's pi spawn from PATH. fabriek's own package rather than one
    ## of pkgs, because the catalogue is evaluated on the operator's
    ## host from plain nixpkgs (check.sh) as well as inside the machine.
    (import ../../../modules/codegraph { inherit pkgs; })
  ];
  skills = [ skills.tool-missing ];
  prompt = ./PROMPT.md;
}
