## Owns the language, the records and the overview of the product a
## factory works; brings no tool of its own, only the two procedures.
{ specialists, skills, ... }:
{
  extends = [ specialists.developer ];
  skills = [
    skills.decision-record
    skills.domain-overview
  ];
  prompt = ./PROMPT.md;
}
