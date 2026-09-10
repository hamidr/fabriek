---
id: ADR-032
title: A factory clones the repository's origin, and the operator's checkout leaves the design
status: proposed
date: 2026-09-10
status_date: 2026-09-10
summary: two clients of one remote need nothing joining them, so the machine clones origin and the supervisor pushes there
depends_on: [ADR-009, ADR-011, ADR-019, ADR-025]
supersedes: []
superseded_by: []
---

## Context

ADR-011 put the factory's clone on nixcage's storage and gave the supervisor
both directions: fetch the operator's checkout into the clone, push role
branches back out to it. That was right for the arrangement it was written in.
A factory lived in nixcage's shared VM, the operator's workspace was already
mounted there for reasons that had nothing to do with factories, and reaching
it cost nothing.

ADR-019 ended that arrangement. A factory has a machine of its own, nothing of
the operator's is mounted in it, and the only thing joining the two is an ssh
port cageworks allocated. Under those conditions ADR-011 point 3 stops being
free and becomes a mechanism to build: either the operator's checkout is shared
into the VM, or the operator pushes into the machine, or something syncs on a
schedule. Each is a way of making two directories on two machines agree.

The reason none of them is needed: the repository already has a remote, and
both sides can reach it. The operator's checkout and the factory's clone are
two clients of one origin, which is a solved problem with no cageworks in it.

Nothing had ever run in a factory's machine when this was decided. There was no
clone, no worktree and no task on one, so the arrangement being replaced was
the arrangement on paper rather than one anybody had used.

## Decision

**1. The machine clones origin.** `git clone <remote>` on the factory's own
pool, from the repository's own remote. Not from the operator's checkout, and
not through a share.

The URL is read off the checkout the register already names, with
`git remote get-url origin`, rather than declared a second time. Two places
naming the same remote is two places that can disagree, and the checkout is
open in front of `cageworks up` anyway for point 3's reason.

**2. Role branches go back to origin.** The supervisor pushes them there. The
operator sees them by fetching, the way they would see a colleague's branch,
because that is what they are.

**3. The operator's checkout stops being the factory's source of code, and
stays where a declaration is read.** ADR-011 points 3 and 4 are withdrawn:
nothing fetches code from it and nothing pushes branches to it. It keeps the
one job ADR-020 gave it, which has nothing to do with either -- `cageworks up`
reads the committed `cageworks.nix` out of it to learn what machine to build,
locally and before any machine exists. A first draft of this document said the
checkout left the design entirely; that was written without looking at what
`machine_spec` does, and it is wrong.

ADR-011 points 1, 2 and 5 stand: one clone per factory on storage that carries
ownership, ADR-010 one layer in, and the clone still not a thing a person
edits.

**4. The credential is the machine's, and arrives the way the model credential
does.** ADR-025 already puts a secret on the machine, readable by one uid,
never in the store and never in a build log. A forge credential is the same
object with a different consumer, and it is delivered by the same route.

**5. Roles still hold nothing.** ADR-009 stands unchanged. A role's session
gets no agent socket and no credential, commits locally to its own branch in
its own worktree, and the supervisor is what pushes. The thing a role cannot do
is exactly the thing it could not do before.

**6. The forge is not a declared endpoint.** ADR-025's allowlist constrains the
proxy, and the proxy is for the model API. The supervisor runs as root, root is
already accepted by the packet filter, and git talks to a forge rather than to
an HTTP proxy. Declaring `github.com` in `resources.egress` would add a
location to the proxy that nothing uses.

## Consequences

**A factory can only work a repository that has a reachable remote.** One that
exists on a laptop and nowhere else cannot be worked by a factory now. That is
a real narrowing and it is the price of deleting the sync: the alternative was
a mechanism whose only job was to make a local directory reachable, and every
version of it cost more than it returned.

**Root's egress is now load-bearing rather than incidental.** ADR-025 accepts
uid 0 because the nix daemon has to substitute. This decision leans on the same
rule for git. Anything running as root on the machine can reach any host, and
the host allowlist constrains only the proxy path. That was already true and is
now depended upon, which is a different thing and worth saying.

**The operator stops being able to hand a factory uncommitted work.** Under
ADR-011 the supervisor fetched a checkout, so whatever was committed there
reached the factory. Now the factory sees what origin has. Work in progress
reaches it by being pushed, which is the same rule everybody else on the
repository already lives under.

**And a declaration can be ahead of the code the factory works.** The
declaration is read from the checkout at `cageworks up`; the code is fetched
from origin. Committing a change to `cageworks.nix` without pushing it builds a
machine for a factory whose repository does not yet have that commit. The two
were one thing while both came from the checkout, and this decision separates
them.

**Two credentials are on the machine where there was one.** The model
credential and the forge credential, each readable by one uid. The second is
new surface, and what limits it is that a role can read neither.

## Verification

```bash
nix develop --command bats --recursive tests/
nix develop --command bats tests/command/seam.bats
docmeta-check docs && docmeta-tracker --check docs
```

The claim worth checking is not that a clone appears. It is that a role session
runs in a cage on a factory's machine, working a worktree of that clone, and
that the recorded role-session invocation is the one `seam.bats` already
asserts. That is PRD-004 phase 3's exit condition, and nothing here is done
until it holds on a machine:

```bash
CAGEWORKS_PROOF_DIR=/tmp/proof tests/manual/moves-in.sh
# clone from origin, a worktree per role, a session that runs in one
```
