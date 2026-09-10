---
id: ADR-030
title: A cage carries a floor, whatever the repository it works declares
status: proposed
date: 2026-09-10
status_date: 2026-09-10
summary: the agent and the tools it needs are the machine to guarantee, not the repository the factory happens to work
depends_on: [ADR-016, ADR-018, ADR-020, ADR-029]
supersedes: []
superseded_by: []
---

## Context

ADR-029 point 4 put the agent in the project's own devShell, reasoning from
ADR-016: what a specialist has to hand is the project's business. That is right
about a specialist's toolchain and wrong about the agent.

A role session runs the agent. A repository whose flake does not provide it
declares a factory whose roles start and immediately fail, and the operator
cannot repair that without editing somebody else's repository. ADR-029 chose
one agent for this repository; leaving every project to independently comply
makes that choice advisory, and the failure it invites is the one nobody can
fix from where they are standing.

The tools are the same argument one layer down. `nixcage`'s base userland is
`bashInteractive`, `coreutils`, `nix`, `git`, `cacert`, `direnv` and `openssh`.
`coreutils` carries no `sed`, no `grep`, no `awk` and no `xargs`; those are
`gnused`, `gnugrep`, `gawk` and `findutils`. A project with a devShell does not
notice, because `mkShell` inherits stdenv and stdenv carries all four. ADR-005
makes a devShell optional, and a project without one gets a cage where an agent
cannot run the commands it was trained to reach for.

Two facts were measured rather than assumed, because the design turns on both.
`nix develop` preserves the caller's `PATH`: a marker placed on it outside the
shell is still resolvable inside. So anything in the base userland reaches every
session, devShell or not, and a floor set there is a floor everywhere. And
stdenv really does supply the four tools inside a devShell, which is why this
has never been noticed.

Nobody enters a cage by hand here. The occupant is an agent, so the floor is
sized for one.

## Decision

**1. A cage carries a floor: the agent, and the tools an agent reaches for.**
`pi`, plus `gnused`, `gnugrep`, `gawk` and `findutils`. Present whatever the
repository's flake declares, and present when it declares no devShell at all.

**2. ADR-016 keeps everything it had.** A devShell is still what gives a
specialist its toolchain, still named per role, and still the project's
business. The floor is underneath it and does not compete: `nix develop`
prepends, so a project shadowing any of these with its own build gets its own.

**3. The floor is declared by the machine, not by nixcage's own userland.**
nixcage has no opinion about coding agents and ADR-018 exists to keep it that
way. What it gains is one option -- a host-declared extension to the base
userland -- and cageworks' guest module declares `pi-coding-agent` into it
beside `nixcage.principalUidRange` and `nixcage.principalSubjects`. Mechanism
in nixcage, policy here.

**4. The shell tools go into nixcage's base userland rather than into that
option.** They are a gap in nixcage on its own terms: a session with no
devShell and no `grep` is a poor session before any factory exists. Fixing it
where it is wrong costs one line and spares every dependant the same
declaration.

**5. ADR-029 point 4 is withdrawn in its second half.** The example still
declares pi, because that is what makes the choice visible to somebody reading
it. It no longer needs to provide pi, and the sentence reasoning from ADR-016
that it should is wrong.

**6. There are three tiers, and only the first is cageworks'.** A cage carries
the floor, whatever anything declares. A repository composes what every one of
its roles gets, in its own flake. A role names the devShell of its speciality
(ADR-016). Only the first is a decision of this repository's; the second is a
list in somebody's `flake.nix` and the third is ADR-016 unchanged.

**7. The second tier is not a schema field, and asking for one is a trap.**
devShells do not compose: a role declaring `shell = "backend-jvm"` enters that
shell and nothing else, so a project that puts its common tools in `default`
alone finds them invisible to every specialist. The repair is concatenation in
the project's own flake. A `resources.packages` in the declaration would be
worse in three ways: it would be baked into the machine image, so adding a tool
would cost a rebuild where a devShell edit costs nothing; the names would
resolve against cageworks' nixpkgs rather than the project's, so a repository
would be asking for a tool from a pin it cannot see; and a floor a project can
declare is a floor a project can forget, which is the failure point 1 exists to
remove. The example demonstrates the composition instead.

## Consequences

**A factory can no longer be broken by a repository forgetting something.** The
class of failure this removes is the one where the fix is in a place the person
holding the error cannot reach.

**The agent's version is the machine's, not the project's.** ADR-029 point 2
said pi would be "pinned like every other input here" and I noted at the time
that it was not: it came from the project's devShell, which the project pinned.
Now it comes from the machine's, which cageworks pins, and that sentence
becomes true. A project wanting a different build of pi shadows it in its own
devShell, which point 2 above allows and nothing here prevents.

**The floor is sized for an agent, not for a person.** Nobody enters a cage by
hand today. If that changes, this list is the wrong length rather than the
wrong idea: a person wants a pager, an editor and a shell that is worth
sitting in, and none of that is here. Stated so the next reader knows which
question was answered.

**The trap in tier two is silent, and the example was in it.** Its `default`
shell was commented "What every role needs regardless of speciality" and no
specialist shell inherited a thing from it, so the `backend` role saw neither
the `jq` nor the agent sitting there. It got `git` and `bash` anyway, but only
because nixcage's base userland supplies them and `nix develop` preserves the
outer `PATH` -- not because anything in the project declared them. A reader
would have drawn exactly the wrong conclusion from the file, which is why the
example composes now and says why in the place somebody copying it will look.

**Four packages is a judgement and will be relitigated.** `sed`, `grep`, `awk`
and `xargs` are what an agent reaches for without thinking. There is no
measurement behind the list and there could not usefully be one; the argument
for stopping there is that stdenv stops there too, and stdenv is the floor
every Nix build has agreed on for twenty years.

**It is an interface change, so it is two commits in two repositories and a
lock bump** (ADR-018). Until nixcage carries the option, point 3 is a decision
and not a behaviour.

## Verification

```bash
nix develop --command bats --recursive tests/
nix eval --impure --expr '(builtins.getFlake (toString ./.)).lib.machine { system = "aarch64-linux"; factory = "acme"; sshPort = 22100; authorizedKey = "ssh-ed25519 AAAAtest x"; }' --apply 'm: m.config.nixcage.containerPackages'
docmeta-check docs && docmeta-tracker --check docs
```

On a machine, the floor is what a cage can run rather than what a module says
it declared:

```bash
CAGEWORKS_PROOF_DIR=/tmp/proof tests/manual/observe.sh floor
# in a cage of a project with no devShell: pi, sed, grep, awk and xargs resolve
```

That is the only assertion worth making. A test that the option contains four
names would pass on a machine where none of them is on `PATH`.
