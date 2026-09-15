---
name: workflow-tuning
description: Improve how a factory works from what its record shows, through the decider's policy, docs/factory-guidance.md, and a skill or script tool in the repository's own catalogue. Use when the same friction shows up in more than one thread, and before writing any of those three.
---

# Workflow tuning

Three levers, in order of how soon they act. Pick the earliest that
fits; a line of guidance costs nothing to ship and can be wrong
tomorrow, a tool costs a machine build and is right for a year.

## What is live when

| Lever | Where | Reaches a role |
| --- | --- | --- |
| Guidance | `docs/factory-guidance.md` | the `this factory:` section of a role's brief, read from its own worktree; live once its branch has it, no build |
| Policy | the file `decider.policy` names in `fabriek.nix` | the decider, at the next machine build, from the commit the operator pins |
| Skill or tool | `<catalogue>/skills/<name>/`, `<catalogue>/specialists/<name>/` | every role's pi, at the next machine build, from the same commit |

Nothing you write reaches a cage before it is on main, and a skill, a
tool or a policy cannot be loaded in the session that wrote it: the pi
directory and the policy are built into the machine and bound
read-only. Say in your outcome which lever you pulled and when it takes
effect.

## Reading a trace

Each attempt's `trace:` comment in a thread, written by the executor
from what the bus and the kernel saw:

```
trace: attempt 1 of builder
turns: 4
tools: bash 18, read 9, edit 3, codegraph_explore 1
commands: 6x npm test; 4x rg -n "importer" src; 2x git commit -m ...
executables: node 31, rg 4, git 3
skills: tdd
guard refused: 2 (test-first: edit src/importer.ts; ...)
```

What to read off it:

- Many `rg` or `read` calls before the first `edit`, and no
  `codegraph_explore`: the role did not know the index; guidance.
- The same multi-word command in several threads: a script tool.
- `skills:` empty where the work matched a skill's description: the
  description does not say when, in the role's words; rewrite it.
- `guard refused` more than once in one attempt: the role does not know
  the order; guidance, or the skill's first step.
- `turns` high with few tools: the role is reasoning in place of
  reading; a skill that says what to read first.
- `trace: not observed`: the streams no longer held the attempt, which
  is a long task or a busy factory; nothing to tune, note it.

## Reading the record for a symptom

Read the last threads before writing anything. A change is warranted by
a symptom that appears more than once: a role asking the same question
in two threads, a builder rediscovering a command the last one found,
a retry that failed the same way twice, a reviewer blocking on the same
omission, the same line in two traces. One occurrence is a task's own
trouble; write it down and wait for the second.

Name the symptom in your outcome with the threads it appears in. A
workflow change without one is a guess, and the next manager cannot
tell whether it helped.

## Writing policy

Prose, read by the decider as data. One rule per line, each testable
against the board: "file the tests task before the build task when the
goal names a behaviour", "a task blocked twice on the same issue waits
for the architect". No rule about a role's inner work; that is guidance.
Never a rule that names an issue number: the policy outlives the issue.

## Writing guidance

Short enough to be read at the start of every session. Says how this
project does things: the test command, the commit convention, where a
change of each kind belongs, what a reviewer blocks on here. Delete a
rule the tree no longer needs before adding one it does.

## Writing a skill you cannot run

A skill is a directory with `SKILL.md` and whatever scripts it needs
beside it:

```
<catalogue>/skills/<name>/
  SKILL.md        frontmatter with name and description, then the procedure
  default.nix     { ... }: { src = ./.; }, plus tools = [ ... ] if a script needs one on PATH
  <script>        called by path from SKILL.md
```

The description is what the agent reads to decide whether to load it:
say when, in the words a role would think. The body is the procedure,
one step per line, with the exact commands. A script beside it is run
by its path relative to the skill directory; make it take arguments and
exit non-zero on failure, and run it here against your worktree before
you commit, because the cage that gets it will not be yours.

A tool a script needs that is not on your PATH is named in the skill's
`default.nix` as a package; the machine build resolves it. You cannot
install it; the tool-missing skill says what to do until the build.

## After the build

The cycle after a skill or a tool lands, read the threads of the roles
that should have used it. Loaded and helped: leave it. Loaded and
misled: fix the procedure. Never loaded: the description did not match
how the role thought about the moment; rewrite the description before
the body.
