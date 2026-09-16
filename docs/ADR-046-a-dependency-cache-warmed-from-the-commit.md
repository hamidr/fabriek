---
id: ADR-046
title: A factory's dependency cache is warmed on the operator's host from the commit's lockfiles
status: proposed
date: 2026-09-14
status_date: 2026-09-16
summary: the host fetches the commit's lockfiles into the lower store at up; nothing fetches on a cage's word
depends_on: [ADR-031, ADR-037, ADR-042, ADR-057]
supersedes: []
superseded_by: []
---

## Context

A cage has no route off the machine (ADR-037), and the language
specialists (ADR-042) put build tools in cages that fetch over one: `sbt`
and Metals through coursier, Maven from central, `pnpm` from the npm
registry. On a project whose devShell carries no cache, the first `sbt
compile`, `mvn test` or `pnpm install` is a blocked outcome, and the
prompts say so. That is honest and it is the largest hole a role falls
into today.

The obvious fix, a cache on the machine that fetches upstream when a cage
asks, is not sound here. It would let a cage cause the machine to fetch
whatever its build file names, which is ADR-031's "an agent asks for a
tool and does not install one" reopened for every dependency, and it
would be a route off the machine by proxy, which ADR-037 argues against
by keeping egress to the model endpoints the operator allowed. A cage that
can edit `build.sbt` and have the machine fetch the result has a way out
it did not have.

What is sound is what Nix already does for the machine itself: fetch at
build time, from a pinned description, with the network the build has and
the cage does not. A lockfile at the commit is that description where one
exists.

## Decision

Re-decided 2026-09-16: this was written against ADR-040, where every
factory was a machine build with the host's network, and ADR-057 removed
the build. A build user on the machine has no route (ADR-025 point 5,
ADR-037), so a fixed-output derivation cannot be realised there, and the
evaluator, which has one, would fetch every artifact serially at render
on every fresh machine. What ADR-057 added is the place: the host's store
is the machine's lower store, and a path the host holds is valid on the
machine at boot. Point 1 changes; the rest stands.

**1. A dependency cache per factory, fetched on the operator's host at
`up` from the commit's lockfiles, and never after.** Before the machine
starts, `fabriek up` reads the repository at the pin, finds the lockfiles
it knows, and `nix build`s one fixed-output derivation per artifact they
name, on the host, with the host's network, rooted under the factory's
machine directory as the profiles are (ADR-057 point 5a). A fixed-output
path is named by its hash and not by the system that fetched it, so a
macOS host warms a Linux machine's cache. At render, the machine evaluates
the same derivations from the same clone and finds every one valid in
the lower store, fetches nothing, and builds the layout the tools read
from them with its own daemon, offline: `~/.cache/coursier/v1`,
`~/.m2/repository`, the pnpm store. The layout is a store path bound
read-only into every role session at the path each tool expects, with
the tool told to work offline (`sbt -Dsbt.offline=true`, `mvn -o`, `pnpm
install --offline`) through the environment the session already sets. An
artifact the host could not fetch stops `up` naming it, before any
machine boots, as point 4 asked of the build.

**2. Which lockfiles: the ones that are lockfiles.** `pnpm-lock.yaml` and
`package-lock.json` name every artifact with its integrity, so they are
complete. Maven and sbt have no lockfile by default; a project that wants
its JVM dependencies cached commits one from the plugin that writes it
(`sbt-dependency-lock`, `maven-lockfile`, or a resolved list the build
can read), and the specialists' skills say which. A project without one
is where it is today: the prompt says so and the outcome is blocked, with
the lockfile as the fix the reviewer names.

**3. Nothing fetches on a cage's word.** A dependency added to a build
file after the commit is not in the cache; the build fails offline; the
role reports blocked naming the artifact; the fix is a commit with the
lockfile updated, integrated by the operator, and `fabriek up --update`,
which rebuilds the machine and warms the cache again. That is ADR-031's
loop applied to dependencies, with the same cost and the same reason.

**4. The cache is an input of `up`, so its cost is visible.** A
fixed-output fetch per artifact, hashed from the lockfile, in the host's
store like everything else the machine is made of, and shared into it
the same way. A lockfile with an artifact the registry no longer serves
fails `up` naming it, before any cage starts.

**5. The declaration says nothing new.** Which lockfiles are read is
decided by which files the repository has at the commit; a factory cannot
opt a cage into fetching, and there is no key for it.

## Consequences

A role on a project with committed lockfiles builds and tests offline
from its first session. A role on a project without them is where it is
now, and the reviewer has a fix to name.

`up` gets longer by the fetch, once per lockfile change, and the host's
store grows by the dependencies of every factory started here. Neither is
new in kind: the appliance is fetched the same way. The lower store is a
snapshot of the host's db taken at boot (ADR-057), which is why the fetch
comes before the start and not beside it.

JVM projects need a lockfile they do not usually keep. That is a
convention this asks of a project, stated in the `java` and `scala`
prompts and skills, not something fabriek can supply.

Not decided here: how the fixed-output fetch is written per ecosystem
(`fetchurl` per artifact from the lockfile's integrity for npm; coursier's
and Maven's layouts), and whether Metals' own downloads (compiler bridges,
semanticdb) are in scope. Both are the implementation's, behind a
scenario each, and the roadmap carries them.

## Verification

Decision only; no code lands with this document. When implemented:

```bash
nix develop --command bats tests/command/vm_up.bats              # up builds a fetch per artifact of the fixture's lockfile, on the host, before the start
nix develop --command bats tests/command/render.bats             # render lays the cache out from paths the lower store holds and fetches nothing
nix develop --command bats tests/command/seam.bats               # the cache bound read-only, the offline environment on the line
```

On a machine: a role on the example repository, given a committed
`pnpm-lock.yaml`, runs `pnpm install --offline` to completion in its cage
with no route; the same role, with a dependency added and no new lock, is
blocked naming it. Recorded in this document when run.
