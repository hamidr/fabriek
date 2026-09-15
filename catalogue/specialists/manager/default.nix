## Owns how the factory works rather than what it builds: the decider's
## policy, the guidance in every brief, and the repository's own catalogue
## of skills and script tools. Splits a goal into tasks the decider files;
## assigns nothing, because assignment is the decider's and nothing else's.
{ specialists, skills, ... }:
{
  extends = [ specialists.committer ];
  skills = [ skills.workflow-tuning ];
  prompt = ./PROMPT.md;
}
