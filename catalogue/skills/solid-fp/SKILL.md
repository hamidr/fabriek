---
name: solid-fp
description: Shape a unit so it has one reason to change, depends on an interface at the seam, and keeps data immutable with effects at the edge. Use when writing or splitting a function, a type or a module, and when a unit grows past a screen.
---

# One reason, one seam, pure inside

## Single responsibility

A unit has one reason to change. Signs it has two: fields only some
methods touch; a name with Manager, Helper, Utils or And in it; a
function past roughly twenty lines that mixes levels (parsing and
deciding, deciding and writing). Split at the seam: a distinct step, a
nameable decision, a policy apart from its mechanism. No seam: leave it
whole; two halves one caller must read together are worse.

## Open for extension, closed for edit

A new case of an existing concept extends the owning unit (a new variant,
a new implementation of the interface). A case that only resembles it
gets its own unit. Extract a shared unit on the third concrete case,
never the second: two are a coincidence.

## Substitution and interfaces

An implementation of an interface keeps every promise the interface
makes, including what it throws and what it never does. An interface is
small and named for the caller's need, not the implementor's shape; a
caller depends on it, and the concrete type is chosen at the edge.

## Dependency direction

The domain depends on nothing outside itself. Adapters (database, HTTP,
filesystem, clock) implement the domain's interfaces and are passed in;
the domain never imports them.

## Functional core, imperative shell

- Data is immutable: a change returns a new value.
- A function's result depends on its arguments alone; the same call
  gives the same answer.
- Effects (I/O, time, randomness) happen in a thin shell that calls the
  pure core and acts on what it returns.
- Errors are values (`Either`, `Result`, an error type) at the seams;
  exceptions only where the language gives no choice.
- Prefer expressions and pattern matching to mutation and flags.

## Done

Name the reason each new unit changes; name the interface each
dependency crosses; every function in the core is pure, and the outcome
says where the shell is.
