---
id: ADR-013
title: The factory's shared record is git-bug, carried in the repository it works
status: proposed
date: 2026-09-03
status_date: 2026-09-03
summary: issues and comments live in git-bug under refs/bugs, so roles collaborate through git rather than a shared database
depends_on: [ADR-011, ADR-012]
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

**2. Roles write in their own clone.** Nothing is shared and nothing is locked.
The supervisor already moves refs between a role's clone, the factory clone and
the operator's checkout; bug refs ride the same path. There is no shared
database, so there is nothing for roles to contend over and no server to run.

**3. Each role has an identity.** `git-bug user new` gives a role a name and an
address, so every comment is attributed to whoever wrote it.

**4. Bodies never reach a command line.** git-bug takes a message from standard
input, which is the rule already applied to briefs and prompts, applied here.

**5. Mentions are labels, never prose.** A role adds a label naming the role it
wants, and the supervisor lists by label. This is not a convenience: parsing a
mention out of a comment body would mean the uncaged supervisor reading
agent-authored text, which PRD-002 names as its top risk. Metadata in, metadata
out.

**6. The supervisor narrates.** Each transition it already makes is appended as
a comment: an attempt started, no outcome was recorded, work settled and moved
to the next stage. Read top to bottom, an issue becomes the story of the work.

**7. Task state stays ours.** git-bug knows open and closed. The eight task
states, the stages, the attempts and the caps remain in the supervisor's own
store, which is what ADR-012 shrinks to.

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

Still to measure, before this is built on: that bug refs survive the
supervisor's existing push and fetch between a role's clone, the factory clone
and the operator's checkout, and that two roles writing issues in separate
clones merge without losing either.
