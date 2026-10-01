---
id: ADR-046
title: A factory's dependency cache is built on the operator's host from the commit's lockfiles
status: implementing
date: 2026-09-14
status_date: 2026-10-01
summary: render builds a read-only cache per lockfile on the host, from allowed registries only; nothing fetches on a cage's word
depends_on: [ADR-037, ADR-042, ADR-067, ADR-070]
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

Re-decided 2026-10-01, for ADR-070 and after a soundness review. ADR-057,
whose lower store the 2026-09-16 text below builds on, is superseded: a
factory now runs in a nixcage machine of its own whose guest sees the
host's store read-only, and every role's profile is already built by the
host's daemon at render, from the repository at the pin, and bound into
the cage as a store root (ADR-070 point 9, `docs/architecture.md`). The
cache takes the same road. Points 1a to 1e replace point 1 below, and
point 3 no longer leans on ADR-031, which is still proposed.

**1a. Built at render, on the host, like a profile.** Render reads the
lockfiles the clone has at the pin and builds, with the host's daemon,
one fixed-output fetch per artifact they name and one derivation that
lays them out as the tool's own read-only cache. The result is a store
path under the factory's directory beside the profiles, bound into every
role session read-only, with the tool told to resolve offline from it.
Nothing is fetched in the machine or in a cage, and nothing is fetched
outside render.

**1b. From allowed registries only.** A fixed-output hash checks what
came back, not where the request went: a lockfile naming
`https://attacker.example/<data>` would have the host send that request
before any hash is compared. So each ecosystem has a fixed list of
registry hosts (for npm, `registry.npmjs.org`), checked when the
derivations are generated; a lockfile entry outside it fails render
naming the entry and its host, and nothing of that lockfile is fetched.

**1c. The operator's commit is the gate.** A role writes lockfiles; the
host reads them only at the pin, which is the operator's checkout, moved
by the operator's merge and `fabriek up --update`. A dependency a role
adds reaches the cache only through that review. This is the rule point 3
states, decided here rather than borrowed from ADR-031.

**1d. A layout the tool reads and does not write.** The cache is the
tool's resolution source, not its working directory: anything the tool
writes (logs, temporary files, its own index) goes under the role's home.
Measured for npm on 2026-10-01: a cache seeded with `npm cache add` from
the tarballs and then made read-only lets `npm ci --offline` install a
registry-resolved dependency by its integrity, and an empty one fails
with "cache mode is 'only-if-cached'". So for npm the layout is that
cache, `npm_config_cache` points at it, `npm_config_offline` is set, and
`npm_config_logs_dir` is under the home.

**1e. npm first.** `package-lock.json` names every artifact with its
integrity and is JSON, so render reads it without running anything the
repository wrote. pnpm (YAML, its own store format), Maven and sbt (no
default lockfile) and Metals' downloads follow, each behind a scenario of
its own; until then they are where they are today.

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

The npm slice landed 2026-10-01 (`727f29d`): `modules/dependency-cache.sh`
reads the lockfile and refuses by entry, `modules/npm-cache.nix` builds the
cache, render links it at `cache/npm`, and every session names it as a
store root with npm told to resolve offline. `bats --recursive tests/`:
510 of 510, of them `dependency_cache.bats` (7, the allowlist),
`npm_cache.bats` (2, a cache built for real and installed from read-only
out of the store), `render.bats` (3 new) and `seam.bats` (1 new).

On `pc` the same day, `example` pinned at a commit whose
`package-lock.json` names `is-number` 7.0.0: render fetched it from
`registry.npmjs.org` under `--restrict-eval` and linked
`/nix/store/1yzzvvxb...-fabriek-npm-cache`; in the frontend's cage, whose
session carried `npm_config_cache`, `npm_config_offline=true` and
`npm_config_logs_dir=~/.npm/_logs`, `npm ci` added the package with no
route, and `npm install left-pad@1.3.0`, which the lockfile lacks, failed
`ENOTCACHED` naming it. pnpm, Maven, sbt and Metals are not built
(point 1e).

The checks, for the next slice:

```bash
nix develop --command bats tests/command/render.bats     # a cache per package-lock.json, built at render; an entry outside the allowlist refused by name
nix develop --command bats tests/command/seam.bats       # the cache bound read-only, npm told to resolve offline from it
```

