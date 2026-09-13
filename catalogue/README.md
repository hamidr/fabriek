# The catalogue

What a role can be, one directory per entry. A specialist is who a role is:
a prompt, the tools it brings, and the skills it knows. A skill is one
written procedure in the Agent Skills format, with the tools that procedure
needs beside it. A role in a repository's `fabriek.nix` names specialists;
fabriek composes them at build and pi reads the result in the cage.

```
specialists/<name>/PROMPT.md    what this specialist is told
specialists/<name>/default.nix  { pkgs, specialists, skills, ... }:
                                { extends = [ specialists.python ]; tools = [ pkgs.ruff ];
                                  skills = [ skills.django-migrate ]; prompt = ./PROMPT.md; }
skills/<name>/SKILL.md          frontmatter (name, description) and the procedure
skills/<name>/default.nix       { pkgs, ... }: { tools = [ pkgs.maven ]; src = ./.; }
```

The directory name is the name. Each `default.nix` is a function of `pkgs`
(fabriek's own pin), `specialists` and `skills` (every entry of every
catalogue, so one may extend another by value). A role's specialists and
everything they extend are flattened once per name, parents first, left to
right. A misspelt package or parent fails evaluation with Nix's own
message; a cycle is infinite recursion.

Adding a specialist is adding a directory. Nothing else in fabriek lists
them.
