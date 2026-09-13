## A specialist of this repository alone: how a release is cut here. It
## extends nothing, because a role composes it beside a language specialist
## from fabriek's catalogue; what it adds is one skill and its prompt.
{ skills, ... }:
{
  skills = [ skills.release-here ];
  prompt = ./PROMPT.md;
}
