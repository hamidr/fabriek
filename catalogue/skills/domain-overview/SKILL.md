---
name: domain-overview
description: Keep docs/GLOSSARY.md and docs/architecture.md true to the tree, reconciling terms, contexts and seams against what changed. Use at the end of every architect task and whenever a boundary or a term moved.
---

# The glossary and the overview

Both describe what is, on the day they are written. Neither describes a
plan; plans are decision records with status proposed.

## Find what moved

```sh
git log --oneline -1 docs/GLOSSARY.md docs/architecture.md
git diff --stat <that commit>..HEAD
```

Read every changed module for a new term, a renamed one, a boundary that
moved, a dependency that now points the other way.

## The glossary

`docs/GLOSSARY.md`, alphabetical, one entry per term:

```markdown
**Assignment** - the executor's grant of one task to one role, recorded
before it is sent and confirmed on the role's ack. Not a claim: a role
never takes.
```

- One meaning per term. Two meanings: split into two terms and rename
  the code that used the wrong one, as a task for a builder.
- A term is defined in the domain's words, then bounded by what it is not.
- A term used in code, an issue or a record and absent here is a gap;
  add it.
- A term nothing uses any more is removed, with a line in the record that
  removed the thing.

## The overview

`docs/architecture.md`, in this order:

1. What the system is, in one paragraph, in glossary terms.
2. The bounded contexts: each with its name, its own terms, and the record
   that drew it.
3. The modules inside each context and the seams between contexts: what
   crosses each seam, in which direction, in what form (a call, a message,
   a file), and which record explains the shape.
4. The invariants the shape exists to keep, numbered, each testable.
5. What is not built, and where the plan for it is.

Every path named must exist in the tree; every record cited must exist in
`docs/adr/`. Check both before reporting done:

```sh
grep -o '`[a-zA-Z0-9_./-]*`' docs/architecture.md | tr -d '`' | sort -u | while read -r p; do [ -e "$p" ] || echo "missing: $p"; done
grep -o 'ADR-[0-9]*' docs/architecture.md | sort -u | while read -r a; do ls docs/adr/"$a"-* >/dev/null 2>&1 || echo "no record: $a"; done
```

## Done means

Both files reflect HEAD, the checks above print nothing, and the commit
says which change in the tree each edit follows from.
