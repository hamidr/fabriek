---
id: ADR-049
title: A role queries its worktree as a graph through codegraph, indexed before hand-over
status: implemented
date: 2026-09-15
status_date: 2026-09-15
summary: codegraph in the developer kit, pi-codegraph in every role pi, the worktree indexed before the role gets it
depends_on: [ADR-030, ADR-031, ADR-037, ADR-042, ADR-043]
supersedes: []
superseded_by: []
---

## Context

A role reads a repository it did not write. What it has for that is
`rg`, `fd`, and the file tools pi carries; `pi-lsp` (ADR-043) adds the
definition and the references of a symbol once a server is up. What none
of these answer in one call is the shape of an area: which symbols matter
for a question, who calls them, what a change to one reaches. A role
answers that today by reading file after file, and every file read is
tokens counted at the proxy (ADR-037).

codegraph is a tree-sitter graph of a tree's symbols, calls, imports and
files in one SQLite file under `.codegraph/`, with a CLI and an MCP server
over it, 33 languages, no model and no key. Its `codegraph_explore` returns
the relevant symbols' source with the call paths between them and a
blast-radius summary in one round trip. Measured on this host: `init -y`
on a tree writes `.codegraph/` with a `.gitignore` of its own that ignores
everything in it, and edits nothing else, so a worktree stays clean;
`serve --mcp --path <tree>` answers with no daemon running; queries
without the daemon read the index as it was, and `sync` or the daemon
bring it up to date.

pi has no MCP and says not to want one: "Build CLI tools with READMEs, or
build an extension that adds MCP support." `@vndv/pi-codegraph` (npm, MIT)
is that extension for codegraph: one file on pi's own extension API,
registering `codegraph_explore`, `codegraph_node`, `codegraph_search`,
`codegraph_files`, `codegraph_callers`, `codegraph_callees`,
`codegraph_impact` and `codegraph_status`, each answered by a
`codegraph serve --mcp --path <cwd>` it spawns from `PATH`. Its only
imports are `typebox` and pi's types, which pi hands every extension.

Two alternatives were weighed. Serena gives an agent symbol-level edits
and refactors over live language servers, but it installs those servers
itself at first use (`npm install` into its own cache, no path override),
which a cage with no route cannot do and ADR-031 forbids; it is MCP only,
so pi would need a second adapter; and its reads are what `pi-lsp`
already gives. codanna is the nearest graph tool, in Rust with a CLI, but
its embeddings need a model fetched at first run, which is the same
problem in another coat. Everything else in the field needs a model
server or a hosted key.

## Decision

**1. codegraph is in the developer kit.** `modules/codegraph/` builds it
from upstream's release tarball for the host platform (a vendored node
beside the bundle, patched on Linux), wrapped so that
`CODEGRAPH_TELEMETRY=0` and `CODEGRAPH_NO_UPDATE_CHECK=1` hold for every
call: a cage has no route off the machine, and a binary that tried anyway
would log a failure at every tool call. The `developer` specialist names
it in `tools`, so every role that extends `developer`, which is every
shipped one, has `codegraph` on `PATH`. The specialist imports fabriek's
package by path rather than `pkgs.codegraph`, because the catalogue is
evaluated on the operator's host from plain nixpkgs (`fabriek check`,
`ls`, `show`) as well as inside the machine.

**2. pi-codegraph is in every role's pi.** `modules/pi-codegraph/` is the
npm tarball, nothing built; `floor.nix` writes
`extensions/pi-codegraph/index.ts` beside the loop's and `pi-lsp`'s, a
re-export of the store path, for the reason ADR-043 measured: pi resolves
an extension's imports from where it found the file. A role without the
binary is told so by the tools themselves; nothing else is configured.

**3. The machine program indexes the worktree before it is handed over.**
`fabriek_role_worktree_ensure` runs `codegraph init -y <path>` when the
tree has no `.codegraph/`, after the worktree exists and before the
`chown` that hands it to the role's uid, so the index is the role's own
and no role's first session pays for a full index. With
`CODEGRAPH_NO_DAEMON=1`: the machine program starts nothing that
outlives it. An index that could not be built is one line on stderr and
not a failure: the role still has its tree and its tools, and
`codegraph_status` says the graph is missing. An existing `.codegraph/`
is left alone on the next entry.

**4. The daemon is the cage's.** Inside the cage the wrapper sets no
`CODEGRAPH_NO_DAEMON`; the first tool call starts codegraph's daemon,
which watches the tree and keeps the index current across the loop's
fresh pi processes, idles out on its own, and dies with the cage's cgroup
on `stop`. It runs as the role's uid and the kernel probes see it as the
role's (ADR-038).

**5. The developer prompt says when to ask.** `codegraph_explore` for a
symbol's source and call paths, `codegraph_impact` for what a change
reaches, before grepping or reading file by file.

**6. The extension is replaceable.** What fabriek depends on is a binary
named `codegraph` on the role's `PATH`, an index at `<tree>/.codegraph/`,
and eight tool names. An extension of our own would spawn the same
binary; no catalogue entry and no shell module would change.

## Consequences

A role gets the graph of its tree for one tool in one specialist and one
file in the pi directory; the decider gets nothing, since it reads issues
and not source.

Two third-party artifacts are pinned by hand: the codegraph release
(version and three platform hashes in `modules/codegraph/default.nix`)
and the extension tarball (`modules/pi-codegraph/default.nix`). The
extension is one file with no lockfile to regenerate. Point 6 is the
exit.

Indexing runs as root on the machine at worktree creation, on a tree that
is the machine's at that moment and the role's after. The time is paid
once per role, at `fabriek up` or the first `enter`, not in a session.

Each tool call is a fresh `codegraph serve --mcp` process, a node start
of a second or two, plus the daemon it talks to. The daemon is one more
process in the cage's memory ceiling and one more set of inotify watches
against the cage's limit; a tree wider than that limit gets
`CODEGRAPH_MAX_DIR_WATCHES` in the wrapper, not measured yet.

The binary is upstream's bundle with a vendored node, not a nixpkgs
build: `sourceProvenance` says so. A nixpkgs package, when one appears,
replaces `modules/codegraph/` and nothing else.

## Verification

```bash
nix develop --command bats -f codegraph tests/unit/role_worktree.bats
nix develop --command bats -f pi-codegraph tests/command/machine_services.bats
nix develop --command bats -f "show says" tests/command/catalogue_cli.bats
nix develop --command bats tests/command/package.bats
nix build --impure --no-link --expr 'import ./modules/codegraph { pkgs = (builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem}; }'
nix build --impure --no-link --expr 'import ./modules/pi-codegraph { pkgs = (builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem}; }'
docmeta-check docs && docmeta-tracker --check docs
```

`role_worktree.bats` stubs `codegraph` on `PATH` and asserts the one
line it is asked with (`init -y <path>`, no daemon), that a second entry
asks nothing, and that a failed index is reported on stderr with the
path still returned. `machine_services.bats` reads the per-role pi
directory's build command for the extension. `catalogue_cli.bats` shows a
shipped specialist and finds `codegraph` among its tools.
`tests/manual/specialist.sh` proves it on a machine: the index in the
role's tree, owned by the role, the binary answering in the cage, and
the extension beside the loop; `codegraph_explore` answering from the
index is gated on a model.
