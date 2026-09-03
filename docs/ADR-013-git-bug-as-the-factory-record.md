---
id: ADR-013
title: The factory's shared record is git-bug, carried in the repository it works
status: proposed
date: 2026-09-03
status_date: 2026-09-03
summary: issues and comments live in git-bug under refs/bugs, so roles collaborate through git rather than a shared database
depends_on: [ADR-011, ADR-014]
supersedes: []
superseded_by: []
---

## Context

A factory needs a record that roles and the operator share: what a task is for,
what a role concluded, what someone asked, and what happened. Tasks alone do not
carry it. A task has one owner and a lifecycle; a discussion has neither.

Building that record means writing comments, attribution, identities, merge and
sync. Every one of those is a solved problem, and the version we would write
would be worse.

The alternative that presents itself is a shared database every role can reach,
and following it exposes why it is the wrong shape here. SQLite has no users
and no row-level security, so a role with write access to the file can change
any row: another role's state, its attempt count, its thread. The supervisor
stops being the arbiter of state and becomes a convention, and the invariant
that no cage originates a dispatch becomes unenforceable. PostgreSQL would fix
that properly, with a database user per role and peer authentication over a
unix socket so no secret enters a cage. It would also add a stateful service to
a design that runs no daemon at all today, in the VM on macOS and on the host
on Linux.

Both options answer the wrong question. Roles do not need shared access to one
store. They need to reach each other's work, and they already do that through
git, which ADR-011 made the way work moves between a role's clone and the
operator's checkout.

## Decision

The factory's shared record is git-bug, stored in the repository the factory
works.

**1. Issues and comments are git objects.** git-bug keeps them under
`refs/bugs/`, so the record lives in the same repository as the work and
travels the same way.

**2. The supervisor is the only writer, acting as each role in turn.** git-bug
keeps the acting identity in a repository-local git config key, with no
per-invocation flag and no environment variable, so in the one clone roles
share there is exactly one acting identity at a time. The supervisor sets it to
the role's full identity id before each write. This is not a workaround bolted
on: comments already reach the supervisor as files at the end of a turn, so it
was already the writer, and this makes attribution correct rather than adding a
step.

**3. Each role has an identity.** `git-bug user new` gives a role a name and an
address, and the supervisor adopts it before writing on that role's behalf, so
every comment is attributed to whoever wrote it.

**4. Syncing is `git-bug pull` and `git-bug push`, never a bare refspec.**
git-bug entities are operation logs that merge; moving `refs/bugs/*` with plain
git only works while nothing has diverged, and silently discards one side when
it has. That was measured, not reasoned about.

**5. Bodies never reach a command line.** git-bug takes a message from standard
input, which is the rule already applied to briefs and prompts, applied here.

**6. Mentions are labels, never prose.** A role adds a label naming the role it
wants, and the supervisor lists by label. This is not a convenience: parsing a
mention out of a comment body would mean the uncaged supervisor reading
agent-authored text, which PRD-002 names as its top risk. Metadata in, metadata
out.

**7. The supervisor narrates.** Each transition it already makes is appended as
a comment: an attempt started, no outcome was recorded, work settled and moved
to the next stage. Read top to bottom, an issue becomes the story of the work.

**8. Task state stays ours.** git-bug knows open and closed. The eight task
states, the stages, the attempts and the caps remain in the supervisor's own
store, which ADR-014 keeps as files.

## Consequences

The question of how every role reaches one database disappears rather than
being answered. That is the main result, and it is worth more than the features
git-bug brings.

The ref partition of ADR-010 does not cover `refs/bugs/`, and granting it means
every role can write every bug ref. There is no per-role namespace to partition
by, because an issue belongs to the work rather than to a role. The control
becomes attribution rather than permission: git-bug entities are append-only
operation logs, so a role editing another's comment produces a new operation
attributed to itself rather than a silent change. That is weaker than the
branch partition and it is the price of a distributed record.

A mention only arrives when the mentioned role next runs. Nothing is
dispatched by a label, deliberately, so a question asked of an idle role waits
until that role has other work. The guidance a role receives has to say this,
or roles will assume otherwise. Consults are what turn a mention into work, and
they are not this decision.

Two behaviours were measured and both shape usage. Taking a message from
standard input makes the first line the title, so a title cannot also be passed
separately. And a label value containing a colon breaks git-bug's own query
parser, so labels are written `needs-architect` rather than `needs:architect`.

Read markers, which say what a role has already seen, are not git-bug's and
belong in the supervisor's store beside the task state.

git-bug joins the container profile and its version is pinned by the flake like
everything else. The record's format is then its format, and a change in it is
a change to the factory.

## Verification

Driven headlessly in a scratch repository against git-bug 0.10.1:

```
git-bug user new --non-interactive --name builder --email builder@factory.invalid
printf '...' | git-bug bug new --non-interactive -F -
printf '...' | git-bug bug comment new --non-interactive -F - <id>
git-bug bug show --format json <id>
git-bug bug label new <id> needs-architect
git-bug bug 'label:needs-architect' --format id
```

Every command runs without a terminal. The JSON carries the title, the status,
the author of each comment and the comment bodies. The label query returns the
issue by label alone, with nothing reading a body. `git for-each-ref` shows the
data under `refs/bugs/<id>`, which is what makes it travel with the work.

Both open questions were then measured in the VM, and one answer overturned an
assumption in this decision as first written.

Bug and identity refs do survive a plain push from the factory clone on ext to
the operator's checkout on the 9p share: `refs/bugs/<id>` and both
`refs/identities/<id>` appear there, and the operator reads the issue with
git-bug on their own machine.

Divergence is where a bare refspec fails. With a comment written on each side,
`git fetch 'refs/bugs/*:refs/bugs/*'` reported success and the operator's
comment was simply absent afterwards. `git-bug pull <remote>` merged the same
divergence correctly: both comments survive, renumbered, and all three
participants are listed. So the supervisor syncs the record with git-bug's own
pull and push, and never by moving those refs itself.

Identity is a repository-local git config key holding a full identity id.
Setting `git config user.name` does not change it, and a truncated id fails
silently, which is how the first attempt attributed a builder's comment to the
architect. The supervisor sets the full id before each write.

Two operational details. git-bug builds an index under `.git/git-bug`, and a
partial one left by an interrupted run makes later invocations fail with
`cannot create new index, path already exists`; it is safe to delete and is
rebuilt on demand. And git-bug has no `-C` flag: it acts on the repository it
is run in, so every call is made from a subshell that has moved there. Passing
`-C` fails with `unknown shorthand flag`, which is a clearer failure than most
of the ones in this document.
