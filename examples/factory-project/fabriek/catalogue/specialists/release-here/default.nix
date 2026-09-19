## A specialist of this repository alone: how a release is cut here. It
## extends committer, the base every specialist reaches, and nothing more:
## a role composes it beside a language specialist from fabriek's
## catalogue, and what it adds is one skill and its prompt.
{ specialists, skills, ... }:
{
  extends = [ specialists.committer ];
  skills = [ skills.release-here ];
  prompt = ./PROMPT.md;
}
