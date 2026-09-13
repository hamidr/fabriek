## React on top of the frontend specialist: node, pnpm and tsserver come
## from there; React itself is a dependency of the project, never of the
## cage.
{ specialists, skills, ... }:
{
  extends = [ specialists.frontend ];
  skills = [ skills.react-component ];
  prompt = ./PROMPT.md;
}
