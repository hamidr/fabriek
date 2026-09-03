---
id: ADR-016
title: A specialist role works in a devShell the project's own flake names
status: implemented
date: 2026-09-03
status_date: 2026-09-03
summary: a role declares which devShell of the assigned repository it enters, so specialists get different toolchains
depends_on: [ADR-005, ADR-010, ADR-015]
supersedes: []
superseded_by: []
---

## Context

A factory works one repository, and every role entering it got the same
environment: `devShells.default`, or the project's `.envrc`, or the base
container userland. That is right for a project one person opens, and wrong for
a team.

A team is specialists. A backend JVM specialist, a frontend specialist, a data
analyst and a DevOps engineer working one repository do not want the same tools
to hand, and they especially do not want a single shell holding the union of
all of them. ADR-015 gave a role a capability it provides, which says what work
it may take; nothing said what it has to work with, so `provides = "build"` and
`provides = "analysis"` produced identical shells.

The environment mechanism was already there and only its selection was fixed:
`nixcage_has_dev_shell` asked whether `devShells.default` existed and
`nix develop` entered it, with no way for the caller to name another.

## Decision

**1. A role declares the devShell it works in.** `roles.backend.shell =
"backend-jvm"` names one attribute of the assigned repository's own flake. The
session enters `devShells.<name>` for the guest system.

**2. The toolchain belongs to the repository, not to nixcage.** The declaration
carries a name across; what is in the shell is the project's to say, and
flake-parts is the idiomatic way to write several. The rule that a project
holds no nixcage-specific file is kept, because a devShell is not one: it is
what a person entering that repository on their own machine would use.

**3. A named shell wins over the project's `.envrc`.** ADR-006 gives an
`.envrc` precedence over the default-shell probe, because it is the project
saying what its environment is. A role naming a shell has said something more
specific, and one `.envrc` cannot answer several specialists at once.

**4. A missing named shell is refused, never substituted.** A role declared for
`devShells.data-analyst` in a project that has no such shell gets an error
naming the shells the project does offer. Falling back to the default would
hand a specialist somebody else's tools, and the run would fail later, far from
the cause.

**5. A role that names no shell behaves exactly as before.** The `.envrc`, then
the default shell, then the base userland. Nothing about a project or a
declaration written before this decision changes meaning.

**6. The name is validated where it is declared.** It reaches a flake
reference, so it is refused as a declaration mistake rather than as a syntax
error inside an evaluation.

## Consequences

A specialist becomes expressible: a role is a capability (ADR-015) plus a
toolchain, both declared, neither inferred. Adding a data analyst is adding a
role and a devShell, not editing nixcage.

The repository gains an interface it did not have. A factory declaring
`shell = "frontend"` depends on the project keeping `devShells.frontend`, and
renaming that shell breaks the role at its next run. The refusal names the
available shells, which makes the break a one-line fix rather than a hunt.

Each specialist's shell is a separate closure in the VM's store overlay, so a
factory of five specialists builds and keeps five environments where it
previously kept one. They overlap heavily, and the store does not deduplicate
them: microvm.nix asserts against store optimisation wherever a writable
overlay is used, which this module always sets. The overlay's existing
collection window is what bounds the growth.

Nothing here bounds what a shell may contain. A role's tools are as privileged
as the role, which is the point of the cage boundary being where it is.

## Verification

Driven in a real VM built from the shipped configuration template, against a
project whose flake defines three devShells through flake-parts.

Three roles were declared on one repository: `backend` naming
`devShells.backend-jvm`, `frontend` naming `devShells.frontend`, and `owner`
naming none. Entering each role and asking which tools were on `PATH`:

```
nixcage role probe backend  -- ...   jq present, ripgrep absent, hello absent
nixcage role probe frontend -- ...   ripgrep present, jq absent
nixcage role probe owner    -- ...   hello present, jq absent
```

Each specialist got its own tools and none of its peers'; the role naming no
shell got the project's default. The packages are stand-ins chosen to be small
and distinguishable, not toolchains.

A fourth role naming `devShells.data-analyst`, which the project does not
define, was refused:

```
nixcage: this role is declared to work in devShells.data-analyst, which
/workspace does not define; it offers:
  backend-jvm
  default
  frontend
```

Two defects were found by running it rather than by reasoning about it, and
both are fixed here. The list of offered shells arrives without a trailing
newline, so the last name was dropped by a plain read loop. And the refusal
formatted itself with `sed`, which the base container userland does not
contain: the message that exists to explain a misdeclaration failed on the
line that prints it. The same tool assumption was already present in the
direnv seed and is corrected with it.

One prerequisite defect was also found and is fixed in its own change. A role
works a linked worktree, and nix resolves a flake through libgit2, which opens
the worktree by the absolute path git recorded beside it. Bound at `/workspace`
alone, that path does not exist in the session, so every flake command in every
role session failed before this. The worktree is now bound at its own path as
well.
