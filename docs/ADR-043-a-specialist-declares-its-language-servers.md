---
id: ADR-043
title: A specialist declares its language servers, and pi-lsp starts them
status: proposed
date: 2026-09-13
status_date: 2026-09-13
summary: language-server tools come from the pi-lsp extension in the floor, configured per role from what its specialists declare
depends_on: [ADR-029, ADR-030, ADR-031, ADR-042]
supersedes: []
superseded_by: []
---

## Context

A specialist has tools on `PATH` and a prompt (ADR-042). What it lacks is
what an editor gives a person: diagnostics as a file is written, the
definition of a symbol, its references. An agent without those reads the
compiler's output after the fact and greps for names.

pi in the closure (0.84.4) has no language-server support of its own, and
its changelog through 0.85.1 adds none. What exists is extensions.
`pi-lsp` (npm, MIT) is declarative: one `lsp.json` in the agent's
directory lists servers by id with the files each matches, the root
markers, the binary and its arguments; the extension starts one process
per server and root after the first write or edit of a matching file,
appends the diagnostics to that tool's result, and registers
`lsp_diagnostics`, `lsp_hover`, `lsp_definition`, `lsp_references` and
`lsp_symbols` for the model. It shuts the servers down with the session.
Servers are spawned as `bin` plus `args`, never through a shell.

That shape is the per-role pi directory ADR-042 already builds: a file
beside `APPEND_SYSTEM.md` and `skills/`, filled from what the role's
specialists declare, read by an extension in the same directory as the
loop. Writing a JSON-RPC client of our own would reproduce it.

Two facts measured before deciding. pi does not resolve an extension's
imports through a symlink: `extensions/pi-lsp -> <store>` fails with
`Cannot find module 'vscode-jsonrpc/node'`, while an `index.ts` that
re-exports the store path loads, which is how the loop is already put
there. And `pi-lsp` reads its global configuration from `PI_AGENT_DIR`,
not from `PI_CODING_AGENT_DIR`; a session has to set both to the same
directory.

## Decision

**1. Language-server tools are `pi-lsp`, carried in the floor.** The npm
package is built by fabriek (`modules/pi-lsp/`) from its tarball and a
lockfile of ours holding its two runtime dependencies; its peers are the pi
in the closure. It is loaded into every role's pi directory as
`extensions/pi-lsp/index.ts`, a re-export of the store path beside the
loop's. Nothing is fetched in a cage (ADR-031).

**2. A specialist declares its servers.** A catalogue entry gains one key,
`lsp`, a list of servers in `pi-lsp`'s own shape, with `bin` a path into a
package:

```nix
lsp = [
  {
    id = "jdtls";
    include = [ "**/*.java" ];
    rootMarkers = [ "pom.xml" "build.gradle" ];
    bin = "${pkgs.jdt-language-server}/bin/jdtls";
    languageIdByExtension = { ".java" = "java"; };
  }
];
```

`enabled`, `args`, `cwd` and the timeouts take `pi-lsp`'s defaults when
absent. The package is reachable from the cage through the read-only store
without being on `PATH`.

**3. A role's `lsp.json` is the union of its specialists' servers, by
id.** Composed with the rest (ADR-042 point 4): flattened order, each id
once, so a diamond declares its server once; the same id from two
unrelated specialists is a build failure naming both. Written to
`share/fabriek/specialist/lsp.json` in the composed derivation and linked
into the role's pi directory as `lsp.json`. A role whose specialists
declare none gets an empty server list, and `pi-lsp` does nothing.

**4. The session names the directory twice.** `PI_AGENT_DIR` joins
`PI_CODING_AGENT_DIR` on the actor line, both `/run/fabriek/pi`; `seam.bats`
asserts the word. Project-local `.pi/lsp.json` stays refused: `pi-lsp`
rejects it in a non-interactive session and the machine's settings trust
no project, so a repository cannot make a role start a binary its
specialists did not declare (ADR-034 invariant 1).

**5. The shipped catalogue declares three.** `java` runs
`jdt-language-server`, `python` runs `basedpyright`, `frontend` runs
`typescript-language-server`; `django`, `flask` and `springboot` inherit
theirs. The `developer` prompt says when to ask the tools: diagnostics
before reporting done, definition and references before renaming or
changing a signature.

**6. The extension is replaceable.** What fabriek depends on is the shape
of `lsp.json` and five tool names. If `pi-lsp` stops following pi, the
same file and the same names are what an extension of our own would read
and register, and no catalogue entry changes.

## Consequences

A role gets an editor's view of its language for one key per specialist
and one npm package in the image. The servers start when a matching file
is first written, so a role that never touches Java pays nothing for the
`java` specialist's server.

A third party's extension is in the seam. Its version is pinned here and
bumped by hand with a lock of ours; its tool names are in the prompts.
Point 6 is the exit, and it is cheap because the configuration is data.

The lockfile is ours, not the package's: the tarball ships none, and the
one generated here omits its dev dependencies and its peers. Bumping the
version regenerates it (`npm install --package-lock-only
--legacy-peer-deps` over a `package.json` without `devDependencies`).

Language servers are heavier than tools. `jdt-language-server` is a JVM
and a workspace directory; `basedpyright` is a node process. Both live
inside the cage's memory and the machine's `memory` ceiling; nothing here
sizes them, and a role with three servers up has three more processes the
kernel probes will see (ADR-038).

Two things this does not do. It does not start a server before a file is
written, so the first `lsp_definition` in a session on an untouched file
starts one then, with `startupTimeoutMs` to wait. And it gives the decider
nothing: its directory carries no `pi-lsp`, since it reads issues and not
source.

## Verification

```bash
nix develop --command bats tests/command/catalogue.bats
nix develop --command bats tests/command/machine_services.bats
nix develop --command bats -f "one invocation" tests/command/seam.bats
nix build --impure --no-link --expr 'import ./modules/pi-lsp { pkgs = (builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem}; }'
docmeta-check docs && docmeta-tracker --check docs
```

`catalogue.bats` builds a role from fixture specialists declaring servers
and reads `lsp.json` out of it: the union by id, the diamond once, the
duplicate refused. `machine_services.bats` asserts the per-role pi
directory's build links `lsp.json` and writes the `pi-lsp` re-export.
`seam.bats` asserts `PI_AGENT_DIR`.

On a machine, `tests/manual/specialist.sh` gains a scenario: in the
example's backend cage, write a Java file with an unused import and read
the diagnostics `pi-lsp` appended in the session transcript. Not run as of
this document's date.
