---
id: ADR-057
title: The machine is built once as an appliance, and a factory arrives as TOML at start
status: implemented
date: 2026-09-15
status_date: 2026-09-16
summary: one image per fabriek; the factory, caps and endpoints arrive as TOML credentials at boot; the daemon builds profiles
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

The machine today owns its store: the closure ships as a read-only disk
and builds land on `store.img` (`storeOnDisk`, `writableStoreOverlay`).
The host's store is invisible, so a toolchain the operator's host already
holds is fetched again per factory. microvm.nix's other mode shares the
host's `/nix/store` read-only into the guest under the same overlay
(`mounts.nix`), which is what a shared store costs nothing to reuse. What
made that mode wrong until now was the cage: nixcage binds the whole
store into every session, so a shared host store would put every
`*-source` of every repository the operator ever evaluated inside each
role's cage. nixcage ADR-014 closes that: a session without the daemon
sees the closure of its named roots and nothing else of the store.

## Decision

**1. One image per fabriek, guest system and host system, built once,
with no factory in it.** `nix build .#machine` produces the appliance
(the guest closure is one; the runner is built from the host's packages,
`vm.nix`, so a macOS host and a Linux host each get their own): the services (ADR-036,
ADR-037, ADR-038), nixcage, pi and the loops, the machine program, the
shipped catalogue's specialists already realised, and the daemon. Nothing
of a factory, an operator or a host is evaluated into it. The pool is
`fabriek`, the host name `fabriek`, the host id a constant, the bridge
`fabriek0`: one machine runs one factory, so none of these needed the
name. The image declares no network interface and no forwarded port, and
its two volumes are `autoCreate = false`. `lib.factory` and the generated
per-factory flake go.

**1a. The host's store is the machine's lower store.** `storeOnDisk =
false`; the host's `/nix/store` is a read-only share at `/nix/.ro-store`
(virtiofs on a Linux host, 9p on macOS) under the writable overlay on
`store.img`, which stays per factory. Nothing of the appliance's closure
is copied into a disk, and a path the host holds is never fetched by the
machine. The guest's nix must know the host's paths as valid, not only
present, or it substitutes them again: the guest daemon runs
`local-overlay-store` with the share as its lower store and the host's
`/nix/var/nix/db` shared read-only beside it, and that overlay is the
machine's default store (`nix.settings.store`), so the daemon, `nix
build` at prepare and nixcage's closure query for every session (nixcage
ADR-014, `nix-store --query --requisites`) all answer for a host path as
valid; with the default left at `local`, the query says "not valid" and
every role is refused at its own root. That feature is experimental in
the pinned nix (2.34.8) and the sqlite read over 9p is unproven; the
measurement plan checks both, and if either fails on a host the fallback
for that host is the host serving its store as a substituter over the
user-mode NIC, which reuses the same paths at a copy's cost. A virtiofs
share needs virtiofsd on the host: on a Linux host `up` starts the
appliance's `microvm-virtiofsd` for the share before the runner and
`down` stops it after, as nixcage's own CLI does for its VM; 9p is
qemu's own and starts nothing.

**2. The runner is the image's, and `up` computes the per-factory line.**
`fabriek up` runs the appliance's `microvm-run` in the factory's machine
directory. `extraArgsScript` is a store path baked into the runner, so it
is one script of fabriek's in the appliance, reading `runtime.json` from
the directory it is run in, which `up` writes from the operator's config
and the factory's directory; the script prints `-m` and `-smp` from the
clamped resources, a user-mode netdev with the ssh port
forwarded and its virtio-net device, and one `-fw_cfg` credential per
file of point 3. Before the first start `up` creates `store.img`
and `pool.img` at the sizes the caps allow. qemu takes the last `-m` and
`-smp` it is given, which the measurement plan below checks on the first
boot rather than assumes.

**3. A factory arrives as four credentials at boot, one per reader, in
TOML.** Under `/run/credentials/@system/`:

`fabriek.factory`, read by `factory-prepare`: the name, the host's
system, and the repository's remote and the rev to work (resolved from
`HEAD` as ADR-020 point 3a did, and moved only by `--update`).

```toml
name = "acme"
hostSystem = "aarch64-darwin"

[repository]
remote = "git@github.com:acme/acme.git"
rev = "3f1c2ab9e0d4b6c7f8a9e1d2c3b4a5f6e7d8c9b0"
```

`fabriek.caps`, read by the clamp: the operator's `[caps]` table, byte
for byte, so `schema.sh` refuses on the machine exactly what it refuses
on the host.

```toml
memory = "16G"
cores = 8
roleQuota = "50G"
recordQuota = "8G"
tokens = 5000000
concurrency = 4
egress = ["api.anthropic.com"]
```

`fabriek.endpoints`, read by the proxy's renderer and the floor's
`models.json`: which header carries which endpoint's credential, never a
value (ADR-025 point 1 stands: the model credential still arrives over
ssh after boot), the models, and the embedder's URL when the host runs
one (ADR-056 point 3; its vhost is rendered at prepare like the
endpoints').

```toml
embedder = "http://10.0.2.2:8080"

[credentials]
"api.anthropic.com" = "x-api-key"

[models]
"api.anthropic.com" = "claude-opus-5"
```

`fabriek.authorized_keys`, read by sshd and nothing else, so the machine
is reachable before anything else runs.

TOML because these are the operator's `config.toml` split by who reads
it, and a person reading one beside the other should see the same
spelling; the reader is the one `operator-config.sh` already has
(`builtins.fromTOML` through `nix eval`), sourced on the machine as on
the host, so there is one parser and one set of refusals. What the
machine writes for its own programs (`declaration.json`, `bridge.json`,
`profiles.json`) stays JSON, as does `runtime.json` on the host, which
the runner's script reads with `jq`: those are program to program.
Splitting by reader means the proxy's unit never sees the repository's
remote and sshd sees only the key, each with `LoadCredential=` of its
own; a change to the caps rerenders the clamp's outputs and nothing
else.

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
The cage's line gains `--store-root` for the profile and for the role's
pi directory (nixcage ADR-014), so the session sees those two closures
and nothing else of a store that now holds the operator's whole history;
`seam.bats` asserts the line with them. A repository's own catalogue
(ADR-042 point 3) is evaluated by the same daemon from the same clone.
Prepare realises every role or reports the first that fails and starts
no session; the executor starts a role's session only when its profile
link exists.

**5a. `up` roots on the host what the machine uses of the host.** After
prepare, `up` reads `profiles.json` over ssh and registers a gc root under
the factory's machine directory for each path the host's store holds,
and one for the appliance itself. A host garbage collection while a
factory runs then removes nothing under a running cage; `down` leaves
the roots, `rm` of the factory removes them.

**6. What the daemon may fetch is what it could fetch before.** ADR-025
point 5 stands: the evaluator and the substituter run as root and leave; a
build user does not. A devShell whose closure substitutes from the cache
realises; one that needs a derivation to fetch at build time fails at
prepare with nix's own message, and the role is refused with its name. A
flake input the repository names is fetched by the evaluator and is
allowed. Every evaluation on the machine runs with
`--no-allow-import-from-derivation` and `--restrict-eval`, with
`allowed-uris` naming the clone and the flake's locked inputs: with the
host's store as the lower layer, an unrestricted evaluation could read
every path of it (pure evaluation permits store paths) and carry what it
read out in a URL, which is every repository the operator ever
evaluated, authored by the roles after `--update`. The restriction is
what keeps point 1a from widening point 6.

The qualifier ADR-025 did not need: the evaluator now evaluates the
worked repository's flake as root on the machine, where before it did so
on the operator's host. What a role commits to `flake.nix` reaches that
evaluator only at the rev the operator moved to with `--update`, which is
the same gate as before; what changes is that the process doing the
evaluating is on a machine built to be discarded rather than on the
operator's own host.

**7. A run's identity is the image plus the file.** Reproducing a run is
the image's store path, the four credentials, and the store paths of the
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
is the same image and a different file. `services.fabriek` (ADR-048) is
unchanged: its unit runs `fabriek up`, which writes the credential and
starts the runner, so a NixOS host declares nothing new.

The first `up` of a factory is slower than a boot: the toolchain is
substituted on the machine over the user-mode NIC rather than on the
operator's host, and the repository's flake is evaluated in the machine's
memory, which is sized for the cages. What the host holds is not
substituted at all; what it does not is substituted once into
`store.img`, the overlay's upper layer, a volume beside the pool and not
on it, kept across restarts and bounded by the size `up` gave it. A
toolchain whose closure does not fit is a role that does not start; the
cap that bounds the volume is the operator's to raise. On a macOS host
the lower store holds Linux paths only where a Linux builder put them, so
the reuse there is the appliance and little else, and 9p is slower than
virtiofs on a store's many small files; the measurement plan records the
cost. The machine's root now reads the operator's whole store, which is
the operator's own history on the operator's own machine and not a
widening; the cages do not, by ADR-014, and that is the line this design
keeps. A devShell that builds from source
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

`models/vm-lifecycle.qnt` is redrawn for this design (2026-09-16): no
build, credentials per boot, prepare as a step that realises one role's
profile at a time and can fail between two, sessions only on a profile
made for this boot's credentials, stale as a running machine whose
credentials are older than the host's. `quint run --invariant=allInvariants
--max-steps=60 --max-samples=5000` finds no violation; every witness
(stale, current again after stale, half prepared, recovered from half,
lost to an abrupt host stop) is reached. It found one thing: the flag the
executor waits on, `/var/lib/nixcage/prepared` today
(`modules/machine/executor.nix`, `fabriek-container`), is on the pool and
survives a reboot, so a machine booted with new credentials would start
the executor on last boot's profiles before prepare ran. Under this
record the flag is per boot, under `/run`, and prepare writes it last;
with the flag kept across boots the model violates in under a second.

`tests/command/factory_flake.bats`, which fails the build by an unknown
key's name and by a role naming a devShell the flake lacks, becomes a test
of `factory-prepare` refusing the same two declarations with the same two
messages, with `nix` stubbed on `PATH` as the CLI tests already stub it.
`machine_services.bats` asserts the appliance's `nix.settings.store` is
the overlay and that no `environment.etc` entry carries a factory.
`tests/manual/isolation.sh` gains two probes: a fixed-output derivation
built in the machine fails, and a substitution succeeds, since point 6
leans on both.

## Measurement plan

Three claims. The runtime line takes effect; a second `up` realises
nothing; a first `up` fetches nothing the host holds. On a Linux host and
on macOS, with a factory whose roles name a devShell the host has already
realised:

```bash
fabriek up example
ssh -p "$(cat ~/.local/share/fabriek/example/port)" root@localhost \
  'grep MemTotal /proc/meminfo; nproc; ls /run/credentials/@system'
                                              # the clamped memory, cores; the four fabriek.* credentials
fabriek down example
fabriek up example 2>&1 | tee /tmp/second-up.log
grep -c "copying path" /tmp/second-up.log     # expected: 0
ssh -p "$(cat ~/.local/share/fabriek/example/port)" root@localhost \
  'cat /var/lib/fabriek/factory/profiles.json' # same paths as the first up
fabriek rm example; fabriek up example 2>&1 | grep -c "copying path"
                                              # expected: 0 on Linux; on macOS, the paths the host lacks
ssh -p "$(cat ~/.local/share/fabriek/example/port)" root@localhost \
  'nix-store --query --requisites /run/current-system | head -1'
                                              # the default store answers for a host path,
                                              # which is what nixcage's closure query asks
```

The first `up`'s wall time and the machine's peak memory during prepare,
against the last ADR-040 build's, and the time of `ls -R` over a
thousand-path closure on `/nix/.ro-store` per share protocol, are
recorded beside the result in `docs/roadmap.md`; the claim is only that
it is once, and that 9p is bearable where virtiofs is absent.

## Verification

Implemented 2026-09-16, in nine commits from `a01189d` (the lifecycle
model) to the record. On this host: `models/vm-lifecycle.qnt` green
(`quint run --invariant=allInvariants --max-steps=60 --max-samples=5000`)
with every witness reached; `machine_services.bats` (16) evaluates
`lib.appliance` and runs the runtime args script; `factory_render.bats`
(9) and `credential.bats` (3) drive the renderers and the credential
writer; `render.bats` (11) drives `factory-render` end to end with `nix
build`, `nft`, `systemctl` and `nixcage-container` stubbed and the real
TOML reader; `vm_up.bats` (23) drives `up`, `-u`, `show -f` and the
order on the wire; `prepare.bats` and `seam.bats` follow the mark under
`/run` and the floor as a root; `bus_acl.bats` the verb before a
declaration. `lib.factory`, `modules/factory.nix`, the per-factory flake
and `factory_flake.bats` are gone.

Measured 2026-09-16 on a NixOS host (x86_64-linux, nix 2.34.8, 62G, 20
cores), the example factory (six roles, two of them replicas) with the
operator's caps at 16G/8 cores clamped to the declaration's 8G/4. The
first `up` on a Linux host found eleven things, each fixed with a
scenario in the same commit, from `227d708` to `776a196`:

- The runtime line does not simply win: with a virtiofs share the runner
  backs the image's memory with one shared memfd NUMA node of the image's
  size, and qemu refuses a `-m` the nodes do not sum to. The script adds
  a second shared node for the rest. After it: `MemTotal` 8134396 kB,
  `nproc` 4.
- `store.img` was an empty file with no filesystem; the initrd formats it
  once, by serial, before the check and the mount, with e2fsprogs.
- `local-overlay-store` holds, with two amendments. nix's check of the
  overlay mount reads `/proc/self/mounts`, where a mount from the initrd
  records its layers under `/sysroot`, so `check-mount=false`. And a store
  opened read-only is opened immutable, which ignores sqlite's write-ahead
  log, while the host's daemon checkpoints every 40000 pages: the newest
  paths, the appliance's own system among them, were "not valid". The
  host's db is shared aside and `VACUUM INTO` takes a checkpointed copy
  onto `store.img` at every boot (3s for a 200MB db), bound where the
  lower store reads. A host path made after the boot is not in it; `up`
  runs after every restart, so the snapshot is as old as the boot. The
  overlay's own state, its db of what the machine built, moved onto
  `store.img` too: on the root tmpfs a second boot rebuilt every profile.
- The image set `FABRIEK_FLOOR` and not `FABRIEK_SELF`, `FABRIEK_SYSTEM`;
  and `environment.variables` reach a login shell and not a unit, so the
  executor's unit is told every `FABRIEK_` variable itself.
- The profile build did `getFlake` on fabriek, which fetches every input
  fabriek locks; fabriek and its nixpkgs are two store paths the image
  names, on the evaluator's search path. `allowed-uris` needed the lock's
  entries as nix asks for them: with the narHash as a query, `/` kept and
  `=` encoded, and the clone spelled twice, for `getFlake` and for
  `fetchGit`. `or` and `pathExists` swallowed the refusals as "devShell
  not defined"; they are asked with `?` and `readDir` now.
- The share daemons: `up` read supervisord's event listener as one and ran
  a python script as bash. The host key: a pool made anew answers as a new
  host, so `up` forgets the old one with it.

Point 3's four credentials are two in the code: one `fabriek.toml`
carrying `[factory]`, `[repository]`, `[pin]`, `[caps]`, `[credentials]`,
`[models]`, and the key. The split by reader did not happen; a `[credentials]`
table carries header names and no value, so nothing is widened. The
record stands corrected here rather than the code.

The plan's numbers: first `up` of a fresh factory (new images, the
example's flake evaluated and every profile built on the machine) 1:34
wall, `copying path` 0; second `up` 2:11 wall with the appliance
rebuilt on the host, `copying path` 0, `profiles.json` identical; a
fresh factory after `rm` of both images, `copying path` 0.
`nix-store --query --requisites /run/current-system` on the machine's
default store answers 688 paths in 0.09s, the first a host path. `ls -R`
over that closure on `/nix/.ro-host` over virtiofs: 273868 entries, 19.6s
cold, 12.8s warm. 9p is not timed: no macOS host here. Peak memory during
prepare was not captured; `free` after it showed 730M used of 7943M.
`tests/manual/isolation.sh`'s two daemon probes pass: a fixed-output
derivation does not build on the machine, and a second render substitutes
nothing.
