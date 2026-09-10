---
id: ADR-031
title: An agent asks for a tool and does not install one
status: proposed
date: 2026-09-10
status_date: 2026-09-10
summary: a tool reaches a cage through the flake a role enters, so wanting one is work for a role rather than a command
depends_on: [ADR-013, ADR-015, ADR-016, ADR-025, ADR-030]
supersedes: []
superseded_by: []
---

## Context

ADR-016 gives a role its toolchain through a devShell of the project's own
flake. ADR-030 puts a floor underneath it that no repository can omit. Neither
says what happens when an agent, mid-task, needs something neither provides.

The question is not hypothetical and the answer is not obvious, because a cage
is not short of the means. `nix` is on every session's `PATH`, `NIX_REMOTE` is
`daemon`, and the daemon socket is bound in. `nix profile install` would write
into the role's home, and a role's home persists between sessions, so a tool
installed once would be there next time.

What actually stops it today is not a refusal. ADR-025 drops egress on the
machine and lets exactly one uid out, and the daemon is not that uid, so
nothing can be substituted. That is a side effect standing in for a decision,
and it would evaporate the moment egress were widened for some good reason.
This document makes it a decision instead.

## Decision

**1. A tool reaches a cage through the flake and by no other route.** The
project's devShell for a specialist (ADR-016), its common list for everyone
(ADR-030 point 6), the machine's floor for what no repository may omit
(ADR-030 point 1). There is no fourth way, and an agent that finds one has
found a bug rather than a feature.

**2. An agent cannot change the flake it entered.** Not because it is forbidden
to edit a file -- it holds a worktree and commits to a branch, which is the
whole of ADR-010 -- but because the flake it is running under was resolved when
its session started. Editing `flake.nix` on its own branch changes what a later
session gets after that branch is integrated, and changes nothing about the one
it is sitting in.

**3. Wanting a tool is work, so it is a task.** Specifically a consult
(ADR-015): a leaf task the asker creates, owned by a role its stage is declared
to consult, resolved by whoever provides the capability that changing a
project's flake needs. The asker states what it needs and why in the task; the
role that takes it decides whether the project should carry it.

**4. The supervisor never reads the request.** It routes the consult by
capability, the way it routes everything, and reads no more of it than it reads
of any task. ADR-027's content-blindness is not weakened by this decision,
which is the reason for making a tool request a task rather than a message to
the supervisor: a supervisor that acted on "I need ripgrep" would be a
supervisor that parsed prose.

**5. The tool appears at the next session, not in this one.** A devShell is
resolved on entry. The consult is answered by a commit to the answering role's
branch, the supervisor integrates it (ADR-013), and the asker sees the tool the
next time a session of its starts. An agent blocked on a tool is blocked until
then, and saying so is better than implying otherwise.

**6. An ad hoc install is undeclared, unshared and unattributed, and that is
the argument rather than a mechanism.** Nothing here can prevent `nix profile
install`, because `nix` has to be present for `nix develop` to work at all.
What can be said is what such a tool is: invisible to every other role, absent
from the flake anything else reads, present in one role's home and no
manifest, and gone when that home is rebuilt. A factory whose toolchains drift
per role is one where no two roles agree what the project is.

## Consequences

**A role can be blocked by a tool it cannot get, and the loop that unblocks it
is not fast.** Consult, integrate, next session. That is the price of a
declared toolchain, and it is the same price a person pays on a project that
pins its dependencies.

**The loop terminates, and checking it found something else.** The worry was
that ADR-025 drops egress and a newly declared tool would be one the machine
could not fetch, leaving point 1's route ending in a failure at session start
that nobody inside could repair. Two things were wrong with it. The daemon runs
as root and root is one of the uids the filter lets out, so the premise was
false. And the machine could not resolve a name at all, for an unrelated
reason: `/etc/resolv.conf` pointed at systemd-resolved's stub, and that daemon
resolves under its own uid, which the filter drops. So the answer was no, but
not for the reason asked about, and the same fault had disabled the proxy
ADR-025 exists to build.

Fixed there rather than here. With it fixed the route works:

```
$ nix build --no-link --print-out-paths nixpkgs#ripgrep
copying path '/nix/store/...-ripgrep-15.2.0' from 'https://cache.nixos.org'...
/nix/store/l02znzqak7gnap7jh95d794gxcwbc2il-ripgrep-15.2.0
```

A role's own uid still resolves nothing, which is what makes point 6 more than
a norm: an agent cannot fetch what it was not given, whatever it runs.

**The capability that answers these has no name yet.** Point 3 says a consult
goes to whoever provides "the capability that changing a project's flake
needs", and no factory declares one. Naming it is a declaration's business, not
this document's, but a factory that declares none has no route and point 3 is
words.

**Point 6 is a norm, not a control.** Somebody will eventually find a role with
a tool nobody declared. The record will show a session that installed it, since
the kernel probes see every exec (ADR-027 point 9), which is the only reason
this is stated as a property worth having rather than a rule worth writing
down.

## Verification

```bash
nix develop --command bats --recursive tests/
docmeta-check docs && docmeta-tracker --check docs
```

Nothing here is a code change, and no test asserts a norm. What can be checked
is that the route exists in a declaration that uses it: a factory declaring a
stage that consults a role providing a tooling capability, and a consult
reaching that role. That is ADR-015's machinery unchanged, and its tests
already cover it.
