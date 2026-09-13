{
  pkgs,
  specialists,
  skills,
  ...
}:
{
  extends = [ specialists.developer ];
  tools = with pkgs; [
    jdk21
    maven
  ];
  skills = [ skills.jvm-profile ];
  prompt = ./PROMPT.md;
}
