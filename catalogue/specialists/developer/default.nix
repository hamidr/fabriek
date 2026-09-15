## A builder: committer's kit and voice, and the disciplines a change is
## held to (test first, domain placement, one reason to change).
{ specialists, skills, ... }:
{
  extends = [ specialists.committer ];
  skills = [
    skills.tdd
    skills.ddd
    skills.solid-fp
    skills.debugging
    skills.proof-before-done
    skills.review-findings
  ];
  prompt = ./PROMPT.md;
}
