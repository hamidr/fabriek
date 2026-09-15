{ specialists, skills, ... }:
{
  extends = [ specialists.committer ];
  skills = [ skills.discipline-review ];
  prompt = ./PROMPT.md;
}
