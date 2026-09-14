---
id: ADR-046
title: A factory's dependency cache is warmed at the machine build from the commit's lockfiles
status: proposed
date: 2026-09-14
status_date: 2026-09-14
summary: build tools read a cache the machine build filled from the commit's lockfiles; nothing fetches on a cage's word
depends_on: [ADR-031, ADR-037, ADR-040, ADR-042]
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

**1. A dependency cache per factory, filled at the machine build from the
commit's lockfiles, and never after.** The build reads the repository at
the rev the machine's lock pins (ADR-040), finds the lockfiles it knows,
fetches every artifact they name as fixed-output derivations, and lays
them out as the caches the tools read: `~/.cache/coursier/v1`, `~/.m2/
repository`, the pnpm store. The result is a store path bound read-only
into every role session at the path each tool expects, with the tool told
to work offline (`sbt -Dsbt.offline=true`, `mvn -o`, `pnpm install
--offline`) through the environment the session already sets.

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

**4. The cache is a build input, so its cost is visible.** A fixed-output
fetch per artifact, hashed from the lockfile, cached in the host's store
like everything else the machine is made of. A lockfile with an artifact
the registry no longer serves fails the machine build naming it, before
any cage starts.

**5. The declaration says nothing new.** Which lockfiles are read is
decided by which files the repository has at the commit; a factory cannot
opt a cage into fetching, and there is no key for it.

## Consequences

A role on a project with committed lockfiles builds and tests offline
from its first session. A role on a project without them is where it is
now, and the reviewer has a fix to name.

The machine build gets longer by the fetch, once per lockfile change, and
the host's store grows by the dependencies of every factory built here.
Neither is new in kind: the machine's own closure is fetched the same
way.

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
nix develop --command bats tests/command/factory_flake.bats      # a cache derivation per lockfile the fixture repository has
nix develop --command bats tests/command/seam.bats               # the cache bound read-only, the offline environment on the line
```

On a machine: a role on the example repository, given a committed
`pnpm-lock.yaml`, runs `pnpm install --offline` to completion in its cage
with no route; the same role, with a dependency added and no new lock, is
blocked naming it. Recorded in this document when run.
