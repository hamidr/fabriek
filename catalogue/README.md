# The catalogue

What a role can be, one directory per entry. A specialist is who a role is:
a prompt, the tools it brings, and the skills it knows. A skill is one
written procedure in the Agent Skills format, with the tools that procedure
needs beside it. A role in a repository's `fabriek.toml` names specialists;
fabriek composes them at build and pi reads the result in the cage.

```
default.nix                     { fabriek }: fabriek.catalogue { version = 1; }
specialists/<name>/PROMPT.md    what this specialist is told
specialists/<name>/default.nix  { pkgs, specialists, skills, ... }:
                                { extends = [ specialists.python ]; tools = [ pkgs.ruff ];
                                  skills = [ skills.django-migrate ]; prompt = ./PROMPT.md; }
                                  lsp = [ { id = "jdtls"; include = [ "**/*.java" ]; ... } ]; }
skills/<name>/SKILL.md          frontmatter (name, description) and the procedure
skills/<name>/default.nix       { pkgs, ... }: { tools = [ pkgs.maven ]; src = ./.; }
```

A directory is a catalogue when its `default.nix` calls the constructor
fabriek hands it, at the protocol version this fabriek speaks (1); it may
name where `specialists` and `skills` live, and defaults to the two
directories beside it. A directory without that file, or one at another
version, is refused by name rather than read as an empty catalogue.

The directory name is the name. Each entry's `default.nix` is a function of `pkgs`
(fabriek's own pin), `specialists` and `skills` (every entry of every
catalogue, so one may extend another by value). A role's specialists and
everything they extend are flattened once per name, parents first, left to
right. A misspelt package or parent fails evaluation with Nix's own
message; a cycle is refused as the cycle.

`lsp` lists language servers in pi-lsp's shape, `bin` a path into a
package; a role's servers are the union of its specialists' by id, and the
same id from two specialists is refused. pi-lsp starts one after the first
write to a matching file and appends its diagnostics to the result.

Adding a specialist is adding a directory. Nothing else in fabriek lists
them.
