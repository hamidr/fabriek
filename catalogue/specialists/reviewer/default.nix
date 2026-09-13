{ specialists, skills, ... }:
{
  extends = [ specialists.developer ];
  skills = [ skills.discipline-review ];
  prompt = ./PROMPT.md;
}
