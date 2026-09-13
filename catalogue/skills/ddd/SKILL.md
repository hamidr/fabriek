---
name: ddd
description: Put a change where the domain says it belongs - the glossary's words in the code, invariants inside the aggregate that owns them, contexts that do not reach into each other. Use before adding a type, a module or a rule.
---

# Domain-driven placement

## The language is the glossary

`docs/GLOSSARY.md` holds the terms. A type, a function, a field, a test
name uses the glossary's word for the thing and no synonym. A concept the
code needs and the glossary lacks is a gap: add the term to the glossary
in the same change, or ask the architect through a consult when its
meaning is not yours to decide.

## Where a rule lives

- An invariant over one entity's data lives on that entity.
- An invariant over several entities lives on the aggregate that owns
  them, and only the aggregate root is reachable from outside; nothing
  else edits its parts.
- A rule that needs two aggregates is a domain service, named as a verb
  in the glossary, and it is stateless.
- Reading for display is a query, separate from the model that enforces
  rules; it does not go through the aggregate.

## Contexts

`docs/architecture.md` names the bounded contexts. A context imports
another only at the seam the overview draws (an interface, a message, an
anti-corruption layer), never its internals. A change that needs a new
seam is an architect's decision, not a quiet import.

## Before adding a type

```sh
rg -n "class |type |sig |case class |data " src | rg -i "<the glossary term>"
```

If the concept exists, extend it. If a similar one exists under another
name, that is two names for one thing; resolve it, do not add a third.

## Done

Every new name is in the glossary; every rule sits with its owner; no
import crosses a context outside a drawn seam. Say which context the
change lives in, in the outcome.
