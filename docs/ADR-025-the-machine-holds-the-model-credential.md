---
id: ADR-025
title: The machine holds the model credential and injects it at egress
status: accepted
date: 2026-09-06
status_date: 2026-09-06
summary: the model credential lives on the factory's machine and is injected at egress; a cage reaches it and nothing else
depends_on: [ADR-019, ADR-021]
supersedes: [ADR-009]
superseded_by: []
---

## Context

ADR-009 decided that a supervised run holds no forwarded agent, signs with a
key belonging to its role, and "cannot push, pull a private repository, or
authenticate anywhere". That last clause was true, was the point, and is now
unreachable. ADR-021 makes a role's agent a loop that runs a model, and running
a model is authenticating somewhere. The decision has to be reopened because
the world it described no longer contains the thing the factory is for.

The spike that drove ADR-024 could not run a single real turn on this machine
for exactly this reason: no provider credential exists here, and every turn ran
against a stub. That is not a gap in the spike. It is the decision arriving.

Four ways to close it were considered.

**Bind the credential into the cage.** Simplest, and it discards the property
ADR-009 bought. A cage that holds a credential which reaches a host can reach
that host, and an agent's whole job is to write and run code. The key is
readable by the thing most able to exfiltrate it.

**Forward it per turn, in the environment.** The same thing with a shorter
lifetime and a worse audit story. It is in the cage while the turn runs, which
is when the agent is executing.

**Run a local model only.** The one option that leaves ADR-009 literally true,
and it constrains what the factory can do to what fits on the machine. Worth
keeping available and wrong as the only answer.

**Keep the credential out of the cage and put it on the path.** ADR-019 gives
every factory a machine of its own, and that machine is ours: its firewall, its
services and its network are things this repository configures. A credential
held there is outside every cage while still being on the way to the model.

The fourth is available because of two facts about what is already built, not
because of anything new. nixcage's `enter` passes no `--private-network`, so a
cage shares the machine's network namespace; and `--private-users=<uid>:1` maps
the session onto the role's allocated uid, so a role's processes carry that uid
on the machine's own network stack. A firewall rule keyed on the uid that
`nixcage-container uid` already allocated is therefore exact, and needs nothing
from nixcage. Reaching for a per-cage network would have meant changing the
interface upstream first, which is the right thing to avoid needing.

## Decision

**1. The model credential is held by the factory's machine and by no cage.** It
is never bound in, never set in a session's environment, and never written to a
path a role can read. `nixcage-container enter` gains no flag for it, because
there is nothing to pass.

**2. The machine runs one egress proxy, and the credential lives there.** The
proxy runs uncaged under a uid of its own, holds the credential, and adds it to
requests on their way out. An agent is configured to talk to the proxy and
holds nothing that would authenticate to anything beyond it.

**3. The machine drops egress and names the exceptions.** The filter matches
the uid a process carries and never a host, because it cannot resolve a name
and the allowlist is names. Loopback is open, so a role reaches the proxy
without leaving. Root is accepted, because the daemon has to substitute. The
proxy's own uid is accepted. Everything else is dropped, which is every role
and every build user.

A role therefore needs no rule of its own: it is denied by there being no rule
for it, which is the only kind of denial that stays true when a role is added.
That works because a role's session runs under its allocated uid on the
machine's own network stack, which is what makes this expressible without
asking nixcage for anything.

Which hosts may be reached is enforced by the proxy rather than by the filter,
since the proxy is the thing that resolves them.

**4. The allowlist is part of the factory's declaration, under the operator's
ceiling.** Which model endpoints a factory may reach is declared in the
repository it works (ADR-020) and clamped by the operator's config in the same
way memory and cores already are. A factory cannot widen its own reach by
declaring more, and an operator who wants a factory reaching nothing sets the
ceiling to nothing.

**4a. An operator who has named no endpoints allows none.** Every other field
a factory declares is a resource, and a resource with no ceiling is left as the
factory asked for it, because a ceiling nobody set is not one. That default is
wrong here and would undo point 4: a factory that names an endpoint on a host
whose operator has said nothing about endpoints would have widened its own
reach by declaring it. So the allowlist is the one field in that table which
meets an absent ceiling as an empty one.

The cost is a factory that reaches nothing on a host whose operator has not
thought about it yet, which looks like a broken factory. What is dropped is
therefore named as it is dropped, so the operator is told which endpoint their
config did not allow rather than finding out from a timeout.

**5. A cage still needs no network for its toolchain, and the daemon that
gives it one is held to the substituter.** nixcage binds
`/nix/var/nix/daemon-socket` into every session, so a role's `nix build` is
performed by the machine's daemon and the substituter is fetched outside the
cage. Denying a role everything but the proxy does not cost it its devShell.

That socket is also a second way out, and this document did not see it until
the firewall was being written. A fixed-output derivation names the URL it
fetches, so a cage that can reach the daemon can make the daemon fetch, and
that fetch never goes near the proxy. The request carries whatever the
derivation's author put in it, and a fetch that fails on its hash has already
been made.

Holding the daemon to the substituter by firewall is not available, and saying
so was a mistake in an earlier draft of this document. A packet filter matches
addresses and the allowlist is names; resolving them when the machine is built
produces a list of addresses that have moved by the time it boots. That is why
the filter matches uids and the names are the proxy's business, and it is why
the daemon, which runs as root and has to substitute, is not filtered at all.

What closes the fixed-output channel is narrower and better. A derivation's
fetch is made by the build user, not by the daemon, and the build user is
dropped like every other uid that is not the proxy. So the channel is closed
rather than narrowed, and what it costs is real: a derivation that fetches from
the network at build time does not build on this machine, and the substituter
is the only source of anything.

What is left is that root leaves this machine for anywhere, and a role's
packets can ride that. A role's decisions cannot: what it can ask the daemon
for is a store path, and a store path is a hash rather than a URL.

**6. The proxy is where spend is counted.** It sees every request, so the
factory's budget is enforced on the path rather than by asking the agent what
it has spent. An agent's own accounting stays useful to the agent and stops
being the thing a ceiling depends on.

**7. What ADR-009 decided and this document keeps, unchanged.** A supervised
run holds no forwarded agent. It signs with a per-role key at
`/run/nixcage/signing-key`, generated by the container script rather than by
the agent, and `--signing-key` and `--auth-sock` remain mutually exclusive. A
role commits under its own name and email and an `allowed_signers` entry binds
its key to its address, so revoking a role is deleting a key and a line. An
interactive session a person entered still forwards their agent, so ADR-008
stands for that path.

What changes is one clause. A role can no longer be described as unable to
authenticate anywhere: it can reach one listener on its own machine, which
holds a credential it cannot read, for a set of destinations it cannot widen.

## Consequences

Prompts and diffs leave the cage. They always had to for a hosted model to see
them, and the proxy makes the moment explicit rather than creating it. A
factory that must not send its repository anywhere is a factory that runs a
local model, which decision 4's ceiling can require by naming no remote
endpoint.

The proxy is content-bearing, and the supervisor's content-blindness is not
affected by that. The two invariants that hold the design up are about the
supervisor reading declarations and metadata rather than task bodies, and about
nothing a role writes reaching a command line. A proxy that forwards bytes it
does not interpret breaks neither, and it is not the supervisor.

Compromising the proxy is total. It holds the one credential and sees every
request, so it is now the thing most worth attacking on the machine, where
before there was nothing to attack. It is small, it is not a cage, and no role
can write to it, and that is the whole of the mitigation.

A role can still exfiltrate to the model endpoint. It reaches the proxy, the
proxy reaches the allowlist, and a request body is a place to put data. The
firewall bounds where a cage can send things, never what it sends. Narrowing
the allowlist narrows the blast radius and nothing narrows it to zero while a
hosted model is in use.

The Formal Modeling Gate fires on a shape it names: a permission model, of
which principals may reach which destinations holding which credentials. It is
structural rather than temporal, so Alloy rather than Quint.
`models/egress-authority.als` is written and run before the implementation.

Ten checks come back UNSAT at scope 10. The design's claims are about what a
role can decide rather than about what its packets can touch, and the model
separates the two: a role reaches the daemon's socket and the daemon reaches
the substituter, so a role's traffic gets to a host it never chose. Asking
whether a role can reach a git remote answers yes and is the wrong question.

So: no role holds a credential that opens anything; no role reaches the model
API or the substituter directly; a role decides no destination outside the
allowlist, and in particular decides no git remote and no other host; any model
call a role decides on transits the proxy; nobody but the proxy can present the
key; a build cannot fetch from the network at all; and ADR-009's property
survives in the form that outlives it.

Six runs come back SAT, so the design is not safe by being empty: a role does
reach the proxy, the proxy does reach the model, several roles hold their own
distinct keys, a role does reach a host without the proxy seeing it, that host
is one it did not choose, and root does leave for anywhere.

Those last three runs are the point of it. What the design gives up is stated
as something the model produces rather than something a fact rules out, because
a model whose facts say a role reaches only the proxy is one that has assumed
the daemon away. Both of the facts that carry the safety were checked by
breaking them: letting a role choose freely turns four checks into
counterexamples, and letting a build user out turns the fifth.

The first draft of that model proved nothing, and how it failed is worth
recording, because it is the same failure ADR-024 was written about. It carried
a fact saying that nothing reaches a destination it holds no credential for.
That is the property, written as an assumption, and with it in place the
firewall could be deleted and every check still passed. Reaching a host is not
authenticating to it: a cage with a route can post anything to a listener that
asks for nothing, and a rejected request has already delivered its body. With
the assumption removed, relaxing the firewall turns five of the seven checks
into counterexamples, and letting the credential into a cage turns the other
two. Both decisions are load-bearing, which is what the checks now say.

`models/factory-structure.als` does not change. What a role may write in the
repository is untouched by this document, which is about what it may reach.

The model says nothing about how the allowlist is arrived at, which is where
point 4a lives. It has one `Proxy.edge in ModelApi` and no notion of a
declaration meeting a ceiling, so what it checks is the shape of the authority
rather than the arithmetic that produces it. That arithmetic is a set
intersection with a fail-closed default, which is cheap to test and was.

## Verification

```bash
nix develop --command shellcheck -x cageworks cageworks-container modules/*.sh
nix develop --command bats --recursive tests/
docmeta-check docs && docmeta-tracker --check docs
alloy6 exec -f models/egress-authority.als
```

The firewall is asserted on the machine rather than in a unit test, because a
rule that is not loaded is not a rule: a role uid reaching anything but the
proxy is a failure, and the proxy reaching anything outside the allowlist is a
failure. `tests/manual/` is where that lives, beside the stop-and-start proof,
since it needs a real machine.
