{
  pkgs,
  specialists,
  skills,
  ...
}:
{
  extends = [ specialists.python ];
  tools = [ pkgs.python3Packages.django ];
  skills = [ skills.django-migrate ];
  prompt = ./PROMPT.md;
}
