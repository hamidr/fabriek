{
  pkgs,
  specialists,
  skills,
  ...
}:
{
  extends = [ specialists.python ];
  tools = [ pkgs.python3Packages.flask ];
  skills = [ skills.flask-app ];
  prompt = ./PROMPT.md;
}
