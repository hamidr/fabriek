---
id: ADR-057
title: The machine is built once as an appliance, and a factory arrives as JSON at start
status: proposed
date: 2026-09-15
status_date: 2026-09-15
summary: one image per fabriek; the declaration, caps and rev are handed over at up; the machine's daemon realises toolchains
depends_on: [ADR-019, ADR-020, ADR-025, ADR-032, ADR-037, ADR-042]
supersedes: [ADR-040, ADR-041]
superseded_by: []
---

## Context

ADR-040 made the declaration part of the machine's image: `fabriek up`
writes a flake per factory whose inputs are this fabriek and the worked
repository, and `lib.factory` (`modules/factory.nix`) evaluates the
declaration, validates and clamps it, composes each role's specialists,
resolves each role's devShell into a profile, and hands all of it to
`vm.nix` as part of one NixOS build. Every factory is a build, every
change to a role is a rebuild, and an operator cannot run a factory without
running Nix against the worked repository on their own host.

Most of that build renders files. The machine program reads
`/etc/fabriek/declaration.json` and evaluates nothing; the executor, the
decider and the relay read the same JSON; the bridge plan, the bus ACL and
the pi directory per role are functions of the declaration that a script
could write at boot. The validation and the clamp are already shell modules
run inside a derivation only so that they run once.

Two things are not files. A role's specialists are `pkgs` values composed
into a derivation (ADR-042), and a role's toolchain is the worked
repository's devShell realised into a profile (ADR-016, ADR-040 point 3),
because a cage has no daemon socket (ADR-037) and cannot realise one
itself. ADR-020 point 3 read the declaration at run time and ADR-040
withdrew it for exactly this reason: the toolchain had to be resolved
before the session, and the image was the only place that resolved
anything.

The machine already runs a nix daemon as root (ADR-025 point 5): it
substitutes from the cache and nothing else, because a build user's fetch
is dropped by the egress filter. The daemon that can realise a profile is
there; nothing asks it to.

The image also carries facts that are the host's or the factory's and not
the machine's: `microvm.mem`, `microvm.vcpu`, the ssh port in
`forwardPorts`, the volumes' `diskSize`, and the factory's name in the
pool, the host name, the host id and the bridge. The pinned microvm.nix
(`804cbac`) has what is needed to take these at run time: `extraArgsScript`
appends a line of hypervisor arguments the runner computes when it starts;
a volume with `autoCreate = false` is an image the caller made at the size
it chose; and `-fw_cfg name=opt/io.systemd.credentials/<name>,file=<path>`
is how `credentialFiles` hands systemd a credential the guest reads at
`/run/credentials/@system/<name>`, which the same runtime line can carry.

## Decision

**1. One image per fabriek and system, built once, with no factory in
it.** `nix build .#machine` produces the appliance: the services (ADR-036,
ADR-037, ADR-038), nixcage, pi and the loops, the machine program, the
shipped catalogue's specialists already realised, and the daemon. Nothing
of a factory, an operator or a host is evaluated into it. The pool is
`fabriek`, the host name `fabriek`, the host id a constant, the bridge
`fabriek0`: one machine runs one factory, so none of these needed the
name. The image declares no network interface and no forwarded port, and
its two volumes are `autoCreate = false`. `lib.factory` and the generated
per-factory flake go.

**2. The runner is the image's, and `up` computes the per-factory line.**
`fabriek up` runs the appliance's `microvm-run` in the factory's machine
directory with `extraArgsScript` pointing at a script of fabriek's that
prints, from the operator's config and the factory's directory: `-m` and
`-smp` from the clamped resources, a user-mode netdev with the ssh port
forwarded and its virtio-net device, and one `-fw_cfg` credential per file
the machine needs at boot. Before the first start `up` creates `store.img`
and `pool.img` at the sizes the caps allow. qemu takes the last `-m` and
`-smp` it is given, which the measurement plan below checks on the first
boot rather than assumes.

**3. A factory arrives as credentials at boot.** Two: `factory.json`, with
the factory's name, the operator's caps, which header carries which
endpoint's credential, the models, the repository's remote and the rev to
work (resolved from `HEAD` as ADR-020 point 3a did, and moved only by
`--update`); and `authorized_keys`, the operator's key. sshd reads the
second from `/run/credentials/@system/authorized_keys`, so the machine is
reachable before anything else runs. Neither is a secret and neither is
in the store (ADR-025 point 1 stands: the model credential still arrives
over ssh after boot).

**4. `factory-prepare` does at boot what the build did**, in this order,
each step idempotent because `up` runs after every restart: clone the
repository at the rev (ADR-032); read the declaration from the commit as
JSON with `nix eval --json --no-allow-import-from-derivation` against the
clone, as ADR-020 point 2 read it; validate and clamp it with the same
shell modules (`schema.sh`, `resources.sh`, `sizes.sh`,
`machine-spec.sh`); then write, under the state directory on the pool at
`/var/lib/fabriek/factory/`, the clamped `declaration.json`, the bridge
plan, the decider's policy from the clone, and one pi directory per role;
apply the bus ACL; render the bridge's per-role nftables rules and the
proxy's per-endpoint vhosts and reload both. Everything that read a file
under `/etc/fabriek` reads it under the state directory instead: the
machine program, the executor, `bridge.nix`, `proxy.nix`, `floor.nix`.
A bad declaration stops here with the message the build printed before,
and `up` prints it and reports the machine down.

**5. A role's profile is realised by the machine's daemon.** For each role,
an expression of fabriek's evaluated against
`git+file:///<clone>?rev=<sha>` takes the named devShell apart into its
inputs the way `profileOf` does today, unions them with the role's
specialists from the catalogues, and `nix build`s the result into the
store overlay, linked at `/var/lib/fabriek/factory/roles/<role>/profile`.
The cage is unchanged: `--no-nix-daemon`, the profile on
`NIXCAGE_PATH_PREFIX`, and `seam.bats` asserts the same line. A
repository's own catalogue (ADR-042 point 3) is evaluated by the same
daemon from the same clone. Prepare realises every role or reports the
first that fails and starts no session; the executor starts a role's
session only when its profile link exists.

**6. What the daemon may fetch is what it could fetch before.** ADR-025
point 5 stands: the evaluator and the substituter run as root and leave; a
build user does not. A devShell whose closure substitutes from the cache
realises; one that needs a derivation to fetch at build time fails at
prepare with nix's own message, and the role is refused with its name. A
flake input the repository names is fetched by the evaluator and is
allowed. Every evaluation on the machine runs with
`--no-allow-import-from-derivation`.

The qualifier ADR-025 did not need: the evaluator now evaluates the
worked repository's flake as root on the machine, where before it did so
on the operator's host. What a role commits to `flake.nix` reaches that
evaluator only at the rev the operator moved to with `--update`, which is
the same gate as before; what changes is that the process doing the
evaluating is on a machine built to be discarded rather than on the
operator's own host.

**7. A run's identity is the image plus the file.** Reproducing a run is
the image's store path, `factory.json`, and the store paths of the
profiles prepare realised, which prepare writes to
`/var/lib/fabriek/factory/profiles.json` and `fabriek show` prints.
ADR-040's lock under the machine directory goes; `--update` moves the rev
in the file.

**8. Of ADR-040, points 1 to 3 are withdrawn and 4 and 5 stand.**
Changing a role is still a restart (point 4), now of the machine with a
new file rather than a rebuild; the operator's caps file and the register
stand (point 5). ADR-041, which made each cage a `containers.<role>` of
the image on the premise that roles are known at build time, is withdrawn
with that premise.

**9. `fabriek check`, `ls` and `show` keep evaluating on the operator's
host.** They are evaluation only, need no machine, and are the one place
the CLI still runs Nix against the repository. That is a deliberate
exception, not a leftover: an operator wants to know whether a declaration
is good before paying for a boot.

## Consequences

An operator's host runs Nix once, to build or fetch the appliance, and
against the worked repository only for `check`. A factory on a second host
is the same image and a different file. `services.fabriek` (ADR-048)
renders `factory.json` per factory instead of a flake, and its unit starts
the runner with the file.

The first `up` of a factory is slower than a boot: the toolchain is
substituted on the machine over the user-mode NIC rather than on the
operator's host, and the repository's flake is evaluated in the machine's
memory, which is sized for the cages. It is substituted once: the store
overlay is `store.img`, a volume beside the pool and not on it, kept
across restarts and bounded by the size `up` gave it. A toolchain whose
closure does not fit is a role that does not start; the cap that bounds
the volume is the operator's to raise. A devShell that builds from source
on the operator's host and does not substitute is a role that does not
start, where it was a slow build before. That is a narrower toolchain than
ADR-040 offered, and it is the toolchain ADR-025 already allowed the
machine.

ADR-046, proposed, warms a dependency cache at the machine build with
fixed-output derivations. Under this record there is no machine build to
warm it at, and a build user's fetch is dropped on the machine. It has to
be re-decided: fetched by the evaluator as `builtins.fetchurl` from the
lockfile at prepare, or warmed on the operator's host and shipped as a
volume. It is not decided here.

`models/vm-lifecycle.qnt` models a generation applied by a rebuild.
Prepare is a step after boot that can fail or half-finish, and a role's
session must not start without its profile; the model gains a prepared
state and that invariant before the code, and stale becomes a running
machine whose `factory.json` is older than the file on the host.

`tests/command/factory_flake.bats`, which fails the build by an unknown
key's name and by a role naming a devShell the flake lacks, becomes a test
of `factory-prepare` refusing the same two declarations with the same two
messages, with `nix` stubbed on `PATH` as the CLI tests already stub it.
`tests/manual/isolation.sh` gains two probes: a fixed-output derivation
built in the machine fails, and a substitution succeeds, since point 6
leans on both.

## Measurement plan

Two claims. The runtime line takes effect, and a second `up` realises
nothing. On a machine with a factory whose roles name a devShell:

```bash
fabriek up example
ssh -p "$(cat ~/.local/share/fabriek/example/port)" root@localhost \
  'grep MemTotal /proc/meminfo; nproc; ls /run/credentials/@system'
                                              # the clamped memory, cores; factory.json authorized_keys
fabriek down example
fabriek up example 2>&1 | tee /tmp/second-up.log
grep -c "copying path" /tmp/second-up.log     # expected: 0
ssh -p "$(cat ~/.local/share/fabriek/example/port)" root@localhost \
  'cat /var/lib/fabriek/factory/profiles.json' # same paths as the first up
```

The first `up`'s wall time and the machine's peak memory during prepare,
against the last ADR-040 build's, are recorded beside the result in
`docs/roadmap.md`; the claim is only that it is once.
