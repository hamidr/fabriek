---
id: ADR-069
title: One NATS server on the host, and an account per factory, replaces a Valkey per factory
status: implemented
date: 2026-09-22
status_date: 2026-09-22
summary: the bus is one nats-server per host; a factory is an account with its own JetStream memory streams and limits
depends_on: [ADR-033, ADR-037, ADR-038, ADR-039, ADR-051, ADR-067]
supersedes: []
superseded_by: []
---

## Context

ADR-033 made the bus Valkey, control plane only: streams with ids, no
persistence, one ACL user per actor so that attribution is the ACL's and
not the message's. ADR-067 put one Valkey per factory on the host, in the
factory's slice, on its bridge (`modules/host/bus.nix`), with the ACL
applied at runtime from password files by `fabriek-container bus-acl`
(`modules/bus.sh`).

One instance per factory is the only isolation Valkey offers that holds.
Sharing one Valkey between factories was examined and refused: its key
space is flat (`mailbox:<role>` collides across factories), its executor
user holds `allcommands allkeys`, `ACL SETUSER` and `default off` are
instance-wide so the first factory's bootstrap locks the second out, and
nothing bounds one factory's memory, connections or command rate against
another's. Valkey 9.1's `db=` selector fixes the key space and nothing
else: "access isolation, not resource isolation".

NATS has what Valkey lacks for this: an account is a subject namespace of
its own with limits on connections, subscriptions and JetStream memory;
users belong to an account and carry publish and subscribe allow lists
per subject; JetStream memory streams give per-stream sequence numbers,
bounded length, replay from a sequence and blocking pulls. What it costs
is a client of ours (no runtime dependency, ADR-018's package rule), a
change in how users are made, and no `ACL DRYRUN`.

This document decides the switch. It is worth doing only for a host that
runs several factories, or for a bus that will carry more than a pointer
and a comment; a host with one factory gains nothing from it, and that is
said in the consequences.

## Decision

**1. One `nats-server` per host, JetStream enabled, memory store only.**
`services.fabriek` runs `nats.service` outside any factory's slice, with
`jetstream { store_dir = <host dataset> max_memory_store = <host cap>
max_file_store = 0 }`. `fabriek-<name>-bus` and `fabriek-<name>-bus-acl`
are removed. The server listens on every factory's bridge address and on
loopback; the host firewall opens its port on `fb-*` and `lo` alone, and
the forward chain still drops anything off a bridge (ADR-037).

**2. A factory is an account.** `accounts.<factory>` in the server's
configuration, with `jetstream { max_mem = <factory cap> }`, `limits {
max_connections, max_subscriptions }`, and no imports or exports: one
factory's subjects are unreachable from another's by construction, so
no stream name carries the factory. The caps are the operator's, fixed
at the host's build from `services.fabriek.factories.<name>`; the
declaration does not ask for bus resources, and nothing clamps.

**3. Users are rendered by prepare and loaded by reload.** The host's
configuration has, per factory, `include
"/var/lib/fabriek/<name>/nats-users.conf"`. `factory-prepare` writes
that file from the declaration: one user per role, `decider`, `executor`
and `probes`, each with a bcrypt hash of the password kept under the
factory's state as now (`fabriek_bus_ensure_password`), and its
permissions; then runs `nats-server --signal reload`. An absent file
is an account with no user, which is what a factory never brought up
looks like. The include is rendered under a flock on the file, checked
with `nats-server -t -c <config>` before the signal, so that one
factory's malformed file is that factory's failure and never a failed
reload for every other; the reload is idempotent.

**4. Permissions are ADR-033 point 3 in NATS's words.** Every JetStream
call is request-reply on a subject the user must be allowed to
subscribe, so each user's client sets `inbox_prefix` to `_INBOX.<user>`
and its subscribe list carries `_INBOX.<user>.>` and nothing of another
user's inbox. Reads are pulls with `ack_policy: none`, the reader keeps
its own position as it does today, so no `$JS.ACK` subject is granted.
Consumers are ephemeral with an `inactive_threshold`, so a role that
goes away leaves no state behind. Subjects keep today's names with `.`
for `:`, and a stream is named for its subject with `-`:

- role `r`: publish `control.r`, `findings.r`, `events.r`; JetStream
  API for its own reads alone: `$JS.API.CONSUMER.CREATE.mailbox-r.>`,
  `$JS.API.CONSUMER.MSG.NEXT.mailbox-r.*`, and the same on `findings`.
  Because `*` matches one whole token, a role's right to pull is bounded
  by the stream's name, never by a consumer's name.
- `decider`: `CONSUMER.CREATE` and `MSG.NEXT` on every stream in the
  account, publish `commands`.
- `executor`: publish and subscribe everything in the account, and the
  JetStream API for creating streams; it is the account's one manager.
- `probes`: publish `probes`.

A user cannot reach a subject its list omits; the server answers with a
permissions violation, which is what `NOPERM` was.

**5. Streams are the executor's to create, at every connect, one per
today's key.** Memory streams vanish with the server, as Valkey's did;
the executor creates `mailbox-<r>`, `control-<r>`, `events-<r>` per
role, and `findings` (subjects `findings.*`, read by every role),
`commands`, `operator`, `probes`, each with `max_msgs` at today's cap
(`STREAM_CAP`, `FABRIEK_PROBES_CAP`), on connect, idempotently, before
it reconciles (ADR-033 point 4). A stream per role rather than one
stream with a filter per role, because point 4's pull permission is
bounded by the stream's name and a shared stream would let a role pull
from a peer's consumer. A role that connects before the executor finds
no stream and retries, as it retries a bus that is away today.

**6. The client is ours.** `factory/src/bus` becomes a NATS client: the
text protocol (`INFO`, `CONNECT`, `PUB`, `HPUB`, `SUB`, `MSG`, `HMSG`,
`PING`) and the JetStream request-reply it needs (stream create, consumer
create, `MSG.NEXT` with `expires`, ack). Its interface to the rest of
the package stays the six verbs of `client.ts` with a stream sequence
where an id was; `messages.ts`, `thread.ts`, the extension, the executor
core, the relay's `tail.ts` and the TUI do not change shape. Shell
callers (`modules/bus.sh`, `probes.sh`, `operator.sh`,
`factory-render.sh`, `machine-plan.sh`, `tests/system/journey.sh`) use
`nats` (natscli) where they used `valkey-cli`; `tests/test_helper/stubs.bash`
stubs it.

**7. Ids and traces.** An entry's id is `<stream created>-<sequence>`,
the stream's creation time from its info and the message's sequence, so
that an id from before a restart and one from after never compare as
neighbours: Valkey's time-based ids gave that for free, and a bare
sequence, restarting at 1, would let a reader that held `5` read on from
`6` on a recreated stream and miss its first five entries. A reader
whose held id names a creation time other than the stream's reads the
stream from its start, which is what it did on Valkey's later ids.
ADR-051's trace is cut by the entry's timestamp, which JetStream stores
per message; `--from` on the relay takes an id or `0-0`.

**8. ADR-033 points 2 and 3 are amended** to name NATS and the account;
ADR-039 point 2's relay reads the account; ADR-067's `-bus` and
`-bus-acl` units are gone. Each notes it in its status.

## Consequences

One process per host instead of one per factory; a factory's bus is an
account with a memory cap, a connection cap and a namespace nothing
outside it can address. Prepare stops speaking to a live server to set
permissions; it writes a file and asks for a reload, which is the shape
ADR-067 wanted for everything a factory renders.

Two factories share the server's fate: a restart empties every factory's
streams at once, where today it empties one. Every actor already
re-announces on an empty bus, so the cost is a reconciliation per
factory, not a loss. The server leaves the factory's slice, so its CPU is
the host's in the probes' accounting; memory is bounded per account
instead.

The client is several times today's `client.ts` and `resp.ts` (210
lines) and is the largest piece of work here; the JetStream API is JSON
over request-reply and every reply must be checked. There is no
`ACL DRYRUN`: the journey's permission scenarios publish as the wrong
user and expect the violation.

A host that runs one factory pays this for no gain. The switch was made
because `pc` runs two, which is the condition this document set.

Valkey leaves the closure with `bus.nix`'s units, `modules/bus.sh`'s ACL
rules and the `valkey-cli` stubs.

## Measurement

Each gate runs against the nats-server nixpkgs pins (2.14.6 as run), on
this host for the journey and on a NixOS host with two factories for the
rest. What each answered is in the verification below; three are amended
there, in the words the server actually uses.

1. Attribution. As user `a-dev` in account `a`: `nats pub control.dev
   ...` delivered; `nats pub control.tester ...` answers `Permissions
   Violation for Publish`; a pull on `mailbox-tester`, on a consumer
   `a-tester` made, answers `Permissions Violation`; a subscribe on
   `_INBOX.a-tester.>` answers `Permissions Violation for
   Subscription`. Same as the journey's `DRYRUN` lines, one per rule in
   point 4.
2. Isolation. As `a-executor`: `nats stream ls` shows `a`'s seven
   streams alone; `nats pub` to any subject is invisible to a subscriber
   in account `b`; `nats server report accounts` shows two accounts with
   separate JetStream usage.
3. Limits. Account `a` with `max_mem = 8MB`: publishing past it answers
   `insufficient resources`; account `b` keeps accepting. Account `a`
   with `max_connections = 4`: the fifth connection is refused.
4. Reload. `fabriek up a` with a new role in the declaration: the user
   exists after prepare with no server restart; `nats server report
   connections` shows `b`'s connections uninterrupted. With `a`'s
   include made malformed by hand, `fabriek up a` fails naming the file
   and `fabriek up b` still adds `b`'s new role.
9. Restart and ids. `factory/src/relay/tail.test.ts`: a fake bus whose
   stream is recreated with a new creation time and ten entries while
   the relay is away; the relay prints all ten. The same against the
   extension's mailbox read.
5. Restart. `systemctl restart nats.service`: every executor recreates
   its streams and reconciles; every actor re-announces; no assignment
   is created from an answer (`tests/system/journey.sh` restart
   scenario).
6. Journey. `tests/system/journey.sh` from filed goal to mirrored record
   on nats-server on this Mac, the same scenarios as on Valkey.
7. Memory. `systemctl show -p MemoryCurrent nats.service` idle with two
   factories, against the sum of the two `fabriek-<name>-bus.service`
   values on the commit before; recorded, not promised.
8. The seam. `tests/command/seam.bats`: the enter line changes in
   `FABRIEK_BUS`'s value alone, or not at all.

## Verification

Implemented 2026-09-22 in five commits from `ad3e26e` (the client) to
`96618ca` (the users checked before they are put in place), on the NixOS
host `pc` with the factories `example` and `widgets` declared. The
condition this document set for doing the work at all is met: `pc` runs
two factories.

On this host, by the suites:

- `factory/src/bus`: `proto.test.ts` reads the server's frames and writes
  the client's; `subjects.test.ts` is where a Valkey name lands and what
  an id is made of; `client.test.ts` drives the six verbs against a
  server standing in for nats-server, JetStream API and pull replies
  included. 218 of 218 node scenarios pass.
- `tests/unit/bus.bats`: the account's users as prepare writes them, one
  scenario per rule of point 4, the hash and never the password, a user
  whose password is not written yet left out, the file checked before it
  is put in place, and the reload asked only after the configuration
  reads.
- `tests/command/host_module.bats`: one `nats.service` in no factory's
  slice, JetStream with `max_file_store: 0`, an account per factory with
  its bounds and its include, the tmpfiles rules that put the
  configuration where the includes resolve from, and no
  `fabriek-<name>-bus` unit of any kind. 458 of 458 bats scenarios pass.
- `tests/command/seam.bats`: the enter line moves in `FABRIEK_BUS`'s
  value alone, which is gate 8.

On this host, `tests/system/journey.sh`, every check, from a filed goal
to a mirrored record on nats-server:

- Gate 1, amended: there is no `ACL DRYRUN` here, so what a user may not
  do is asked by doing it as that user and reading the refusal. A role
  publishing another's control subject, another's mailbox, or a pull on
  another's mailbox is answered `Permissions Violation for Publish`; a
  subscribe on another's inbox `Permissions Violation for Subscription`;
  the decider publishing a mailbox and the probes publishing anything but
  their own stream, the same. A login the server does not know is refused
  with `Authorization Violation`, once there are users at all: an account
  with none takes anyone, which is what a factory never brought up is.
- Gates 5 and 6: the journey's own scenarios, and a restart of the server
  as one of them. The streams are made again, a goal filed after the
  restart is opened and assigned, and no assignment is made from an
  actor's answer.
- Gate 9: `relay/tail.test.ts` and the extension's mailbox read against a
  stream recreated with a later creation time; both read it from its
  start rather than skipping what they never saw.

On the host, `tests/manual/bus-account.sh` with `A=example B=widgets`,
every check (transcript `bus-account.txt`):

- Gate 2: `nats stream ls` as a factory's executor shows its own streams
  and no name the other factory holds one under; a publish in one
  account reaches no subscriber in the other, on a subject both have.
- Gate 3, amended: the account's memory is its own and stops at the
  bound the host set, 128 MiB here, while the other account stays where
  it was. What a stream at that bound does is discard its oldest rather
  than refuse, because every stream here is `discard: old`, so the
  publisher is answered and not told `insufficient resources`. The
  connection bound is in the configuration and was not exercised: it
  wants sixty-five clients at once, which this proof does not spend.
- Gate 4, amended: prepare writes a factory's users and asks for a
  reload, and the server is not restarted while another factory keeps
  speaking. One server reads one configuration, so a file it cannot read
  is not one factory's failure but every factory's reload: what a factory
  writes is therefore checked on its own before it is put in place, and
  the file in place stays as it was. A file made malformed by hand is
  refused at the next reload with a message naming the configuration and
  not the factory that asked, and the owning factory's next prepare
  repairs it.
- Gate 7, the memory: `nats.service` idle with two factories prepared is
  23101440 bytes, 22 MiB, once for the host, against the two
  `fabriek-<name>-bus.service` units it replaces. Those were Valkey with
  no persistence, inside each factory's slice, and are gone with this
  change; what can be said of the slices is ADR-068's number and this
  one's: `fabriek-example.slice` was 454332416 bytes under ADR-067 with
  its own board and bus, 351588352 with the board moved out, and
  274722816 with the bus moved out as well. Numbers measured once on this
  host, not promised.

What the host found, and the tree carries the fix for: JetStream delivers
a pull's messages under the message's own subject rather than the inbox
they were asked on, so a caller's answers are told apart by the
subscription its request made, one per request and ended with it; a
consumer's name belongs in its config and the server refuses it beside
it; and the entries a reader is handed carry the stream's creation time,
which it must ask the stream for when it has published nothing itself.
