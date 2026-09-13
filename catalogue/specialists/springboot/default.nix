{ specialists, skills, ... }:
{
  extends = [ specialists.java ];
  skills = [ skills.spring-boot-run ];
  prompt = ./PROMPT.md;
}
