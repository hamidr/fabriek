---
id: PRD-001
title: A mailbox that lets project containers exchange messages
status: proposed
date: 2026-09-01
status_date: 2026-09-01
summary: give each project actor a durable mailbox so agents in separate containers can signal, delegate, and share findings
depends_on: []
supersedes: []
superseded_by: []
phases_total: 4
phases_done: 0
---

## Problem

nixcage isolates each project in its own container, and that isolation is the
point: an agent working in one project cannot read, write, or disturb another.
The cost is that the agents cannot talk either.

The person running several of these sessions absorbs that cost by hand. A
finding made in one container -- an upstream API changed, a flake input is
broken, a convention was agreed -- reaches the other containers only if the
human notices it, remembers it, and retypes it. Work that belongs in a second
project is either done badly from inside the first one, from a container that
does not have that project mounted, or parked in the human's head until they
open the other project and remember the request. Nothing survives the end of a
session: close the terminal and the pending request is gone.

The containers already share a machine, a store, and a state directory. What
they lack is a place to leave each other a message.

## Users

- **The operator.** One person running several nixcage sessions across their
  own projects, in parallel or in sequence. They are the only trust domain:
  every actor belongs to them. They decide what work happens and when.
- **The agent.** claude-code running inside a container, with the project at
  `/workspace` and no view of any other project. It is the reader and writer of
  messages, but never the scheduler: it acts when the operator enters the
  container.

## Goals

1. A finding made in one container is available to every other container
   without the operator relaying it.
2. Work that belongs to another project can be recorded against that project at
   the moment it is discovered, and is still there when someone opens it.
3. An operator entering a project can tell, in one command, what is waiting for
   that project and what it has already seen.
4. A request sent to another project can be answered, and the answer found by
   whoever asked.
5. The mailbox never executes. No message causes work to happen by itself; only
   a party outside the mailbox, under the operator's policy, can act on one.

## Non-goals

- **Dispatch.** The mailbox starts nothing. No process wakes on delivery, no
  session drains a mailbox, no daemon runs between sessions. A message is data
  that waits until something outside the mailbox acts on it, whether that is a
  human entering the project or the supervisor in PRD-002. This is deliberate:
  a channel that also executes turns a mail bug into unattended token spend, and
  keeping the two apart is what lets dispatch be governed on its own terms.
- **Ability transfer.** An actor cannot grant another actor a capability, tool,
  or skill it did not have. Messages carry information and requests, never
  executable authority. A grant model needs revocation and an ownership model,
  and neither is worth building before the message channel has been used.
- **Authentication between actors.** All actors belong to one operator on a
  personal machine. Attribution is a convenience, not a security boundary.
- **Multi-machine or multi-user delivery.** One host, one operator.
- **Message expiry, retention policy, or garbage collection.** Out of scope
  until the mailbox is large enough for it to matter.
- **A second agent-facing protocol.** No MCP server, no context injection, no
  push. The channel is reachable the same way a shell command is.

## Success criteria

- The operator can name a piece of knowledge they published from one container
  and read it from a different container in the same day, without having
  retyped it.
- Entering a project surfaces its pending items in one command, and that
  command distinguishes what is new from what has been seen.
- A request recorded against a project survives the sender's session ending,
  the receiver's machine rebooting, and a `nixcage rebuild`.
- Over a week of ordinary use, the operator stops keeping a scratch list of
  "things to tell the other project".
- No session is ever started by the mailbox itself.

## Requirements

### Addressing

- An actor is a project directory, or a role declared against one. A project
  worked by a single session addresses that project; a project assigned to a
  factory (PRD-003) has one actor per declared role instead. Both forms of
  address are stable across sessions and reboots, and both rest on the identity
  nixcage already uses to keep a project's home directory.
- An address is never derived from a worktree path. Roles hold worktrees and
  worktrees come and go, so an address that followed the path would not survive
  the role's tree being recreated.
- An address is an email address, because the message format is RFC 5322 and
  inventing a second naming scheme beside it would buy nothing.
- An operator can list the actors they can address without knowing how the
  address is derived.
- Two concurrent sessions of the same project are the same actor and share one
  mailbox. This is accepted, not solved.

### Sending

- An agent can address a message to one actor, or to every actor at once.
- A message carries a short subject and a body; the body may be long enough to
  hold a diff, a log excerpt, or a paragraph of reasoning.
- Sending never fails because the recipient is not running. There is no such
  thing as an unreachable actor among configured projects.
- Sending to an address that is not a project is refused at the point of
  sending, not silently accepted.

### Receiving

- An agent can see everything waiting for its actor, and can distinguish
  messages it has already read from ones it has not.
- Reading a message records that it was read, so the same item does not
  resurface every session.
- An agent can read the full history addressed to it, not only the unread part.

### Requests and answers

- A message can be marked as a request for work, and an answer can be recorded
  against it.
- The party that made a request can find the answer to it.
- A request and its answer can be read together as one exchange.
- An unanswered request stays unanswered forever and is not distinguishable
  from one that was seen and ignored. This is a known limitation of the
  request/reply pair; see open questions.

### Requests the operator must satisfy

- An agent can address a request to the operator for the things a cage cannot
  reach on its own: a tool in the shared container profile, a secret mapping, a
  new workspace root, VM sizing. Everything else it installs itself through its
  project's own flake or `.envrc`, which needs nothing from this system.
- Such a request is an ordinary message. The mailbox does not apply it, and
  neither does anything else automatically.

### Shared findings

- An agent can publish a finding to every actor at once.
- Each actor sees a published finding once, independently of the others: one
  actor reading it does not consume it for the rest.

### Operator access from outside a container

- The operator can read and send from the host, without entering a container,
  on both supported platforms.

### Durability

- Messages and read state survive session exit, container removal, host reboot,
  and rebuild of the VM or host configuration.
- Concurrent writers do not lose or corrupt messages.

## Constraints

- Projects stay free of nixcage-specific files. No mailbox state lives in a
  project directory or in the shared host mount.
- The message store lives in nixcage's own state, on a real Linux filesystem
  inside the VM on macOS and on the host state directory on Linux.
- The store is one Maildir per actor and messages are RFC 5322. Nothing here is
  invented where a format already solves it: atomic delivery under concurrent
  writers, unread versus read, a request and its answer read as one exchange,
  and a broadcast whose read state is per recipient are properties of Maildir
  and of message threading rather than of code this project would write and
  then have to get right.
- No mail transfer agent. Delivery is the sender writing into the recipient's
  Maildir directly. An MTA is a daemon that runs between sessions, and its
  delivery hooks execute on arrival, which is precisely what "the mailbox never
  executes" exists to prevent. The cost is no SMTP, which only matters off this
  machine, and one machine is already the scope.
- The tooling that reads and writes a Maildir joins the container profile
  through the flake, never a host installation.
- The channel reaches the agent as an ordinary command, so it works from a
  shell, from a script, and from any agent that can run one.
- Whatever the store requires is added to the container userland profile
  through the flake, never installed on a host.

## Risks

- **Cross-actor reads, where uids do not separate actors.** Between the roles
  of a factory the separation is real: ADR-010 gives each role its own uid, so
  an actor's Maildir can be readable only by its owner while remaining writable
  by every other role, and one actor cannot read another's mail. Between two
  ordinary project actors it is not: ADR-004 maps both onto the operator's uid,
  so they are the same principal and each can read the other's mailbox.
  Accepted for a single operator, and it still makes the tool unsuitable for a
  shared host.
- **Forged attribution, on the same split.** A delivered message file is owned
  by the uid that wrote it, so where roles have distinct uids the recipient can
  check the real sender against the `From` header and the header stops being a
  hint. Where actors share a uid it remains one, and the documentation has to
  say which case a reader is in rather than implying provenance in both.
- **Mailbox as an instruction channel.** An agent that reads a message is
  reading text written by another agent. Treating that text as an instruction
  rather than as data is the obvious failure mode, and the guidance the agent
  receives has to address it.
- **Silent drop.** Because the mailbox starts nothing, a message to a project
  that nobody and nothing opens is never seen. The design accepts this; the operator
  needs a way to notice it.

## Open questions

- How does the operator learn that a project has mail without entering it?
  A host-side listing of every actor's unread count is the minimum. A terminal
  multiplexer showing every session at once is the likely answer, and herdr
  0.8.0 exposes a command for externally reported per-pane state, but it
  refuses its own required `--source` flag as shipped, so that route is not
  currently available and an unread count would have to live somewhere else.
  Whether the unread count belongs there or in a plain listing is still open.
- Should a request carry a status beyond answered/unanswered? The
  request/reply pair was chosen for simplicity, and the cost is that "not
  looked at" and "refused" look identical. Revisit after real use.
- Does a broadcast finding need any grouping (topic, project, tag), or is a
  flat stream with subjects enough at the volume one operator produces?
- Roles within a project are wanted, and PRD-003 settles that they are declared
  and long-lived rather than one per worktree. What stays open is whether a
  project can hold both forms at once: an actor for the project itself and
  actors for its roles, with the project address meaning "whoever is working
  this" and the role addresses meaning specific workers. A flat rule of one or
  the other is simpler and may lose a useful broadcast target.

## Phases

1. **A message reaches another container.** One actor sends, another lists and
   reads, read state persists. Establishes identity, the store, and durability.
2. **Exchanges and findings.** Requests, answers read as one exchange, and
   broadcast findings with per-actor read state.
3. **Host-side access.** The operator sends and reads from the host on both
   platforms, without entering a container.
4. **Discovery and guidance.** Listing addressable actors, and the written
   guidance that tells an agent when to check mail, how to address an actor,
   and that message bodies are data rather than instructions.

## Design gates

The message store spans more than one entity (messages, read state, and the
reply relation between messages), which is a cross-entity invariant and fires
the Formal Modeling Gate. Maildir and RFC 5322 supply the mechanics and none of
the invariants: the format will happily carry a reply to a message that does
not exist. Before implementation, a structural model under `models/` must be
written and run, checking at minimum: no answer without the request it answers,
no answer to a broadcast finding, a broadcast has no single recipient, no cycle
in the reply relation, and no read state recorded for a message the reader
could not see.

That model is not written, and skipping it is a decision rather than an
oversight. The reason is that the mailbox is cheap to reverse: it is a
directory of files that starts nothing, nothing depends on it since PRD-003 was
narrowed off it, and a store that turns out to be wrong is replaced by moving
files rather than by unwinding anything that ran. That is the one escape the
gate allows, and it is taken here explicitly.

The invariants above therefore go unchecked, and every one of them is a way
this can be wrong in practice: an answer whose request does not exist, an
answer to a broadcast, a reply relation that closes into a loop, a read receipt
for a message the reader was never a recipient of. They fall to tests at
implementation time, which is a weaker check than a counterexample and is being
accepted knowingly. If the mailbox ever gains a party that acts on a message
without a human, this decision is revisited first.
