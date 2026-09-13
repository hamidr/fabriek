---
id: ADR-042
title: A role is a set of specialists from a catalogue, and a specialist is a directory
status: proposed
date: 2026-09-13
status_date: 2026-09-13
summary: a role names specialists; each is a directory of prompt, tools and skills, composed at build and read by pi in the cage
depends_on: [ADR-016, ADR-020, ADR-029, ADR-030, ADR-031, ADR-040]
supersedes: []
superseded_by: []
---

## Context

A role today is a capability it provides and a devShell it enters (ADR-015,
ADR-016). That gives a specialist its tools and nothing else. The brief a role
starts with says `You are the role backend.` and then the task; nothing says
what a backend is, what it knows, or how it does things here. A Django
developer, a Spring Boot developer and a data analyst are three different
workers, and the difference is not only which packages are on `PATH`. It is a
prompt, and it is a set of skills: written procedures, each needing tools of
its own, that the agent loads when the work matches.

pi in the closure (0.84.4) already implements the Agent Skills standard. It
lists every `SKILL.md` under `PI_CODING_AGENT_DIR/skills/` in the system
prompt and loads one on use, and it appends `APPEND_SYSTEM.md` from the same
directory to its system prompt. The machine already builds that directory and
binds it into every supervised session (ADR-035). What is missing is not a
mechanism in the cage but a way to say, outside it, what a specialist is.

The interface has two sides and they want different things. Whoever extends
fabriek adds a specialist or a skill every other day and wants that to be a
directory, not Nix. Whoever runs a factory wants to name specialists in
`fabriek.nix` and touch nothing else: the example's `flake.nix` already asks
a repository to compose devShells by hand, and asking it to compose
specialists the same way would be the wrong interface for the person it is
aimed at.

One earlier objection has to be answered. ADR-030 point 7 refused a
`resources.packages` field because its names would resolve against fabriek's
nixpkgs rather than the project's. That objection is about a project's own
toolchain, which stays in the devShell with the project's pin. A specialist's
kit is the machine's business, like the floor (ADR-030 tier 1): fabriek pins
it, and a project that needs a package of its own declares it in its devShell
as before.

## Decision

**1. A role names a list of specialists.** `roles.backend.specialists = [
"java" "python" ]` in `fabriek.nix`. The field is optional; a role naming
none is a role as today. `shell` stays and means what ADR-016 says: the
repository's own build environment, resolved against the repository's pin.

**2. A specialist is a directory, and so is a skill.** Under a catalogue:

```
catalogue/
  skills/<name>/SKILL.md          the Agent Skills standard: frontmatter and body
  skills/<name>/skill.nix         { tools = [ "python3Packages.django" ]; }
  specialists/<name>/PROMPT.md    what this specialist is told
  specialists/<name>/specialist.nix
                                  { extends = [ "developer" ]; tools = [ "jdk21" ];
                                    skills = [ "jvm-profile" ]; }
```

The directory name is the name. The two `.nix` files are pure data like
`fabriek.nix`: no inputs, no `pkgs`, evaluable alone, dumped to JSON and
validated by one jq program against a closed schema. `tools` are nixpkgs
attribute paths as strings, resolved against fabriek's pin. A key outside the
schema is refused by name.

**3. Two catalogues, one convention.** fabriek ships `catalogue/` in its own
tree and builds it into the image. A repository may declare `catalogue =
"fabriek/catalogue"` in `fabriek.nix`, a path inside itself with the same
layout, for specialists and skills that belong to that project alone. A name
declared in both is refused, never shadowed.

**4. Composition is a flattened DAG, each name once.** `extends` is a list.
The specialists a role names, and everything they extend, are walked depth
first, left to right, parents before children, and a name already seen is
skipped. So `java` and `python` both extending `developer` give `developer`
once. Tools are the union; skills are the union by name; prompts are
concatenated in that order, each under a `## <name>` heading so the model
sees where one specialist ends and the next begins.

**5. What reaches the cage is one derivation per role, and one directory pi
already reads.** The role's profile (ADR-040) grows from the devShell's
inputs to the devShell's inputs plus the composed specialist: `bin/` with the
specialist first on `PATH` and the floor under both, and
`share/fabriek/specialist/` carrying `APPEND_SYSTEM.md` and `skills/`. The
machine writes a pi directory per role, `fabriek/roles/<role>/pi/`, holding
the same loop extension and settings as today plus `skills` and
`APPEND_SYSTEM.md` linked from that profile. The actor line binds it where
`PI_CODING_AGENT_DIR` already points. The declared `command` is not touched:
no `--skill`, no `--append-system-prompt`; a role runs the argv the
repository declared and finds its kit in the directory it was always given.

**6. Every refusal is at build and names a directory.** A specialist the
catalogues lack, listing what they offer; an unknown parent, skill or tool;
a cycle in `extends`; one `bin/` file from two packages of one role's
specialists, naming both; a `SKILL.md` without a `description`, which pi
would otherwise drop silently.

**7. The brief agrees with the system prompt.** `actor.ts` adds one line
after the role's name: `Your specialists: java, python.` A role naming none
gets no line.

**8. ADR-031 point 3 gets its answer.** Wanting a tool is still a consult;
what the consult changes is a `skill.nix`, a `specialist.nix`, or the
repository's own catalogue, and the tool arrives at the next session as
that document says.

**9. `command` defaults to `[ "pi" "--mode" "rpc" ]`.** ADR-029 fixed the
agent and ADR-030 put it on every cage, so a role declaring none runs it. A
declared `command` still wins, word for word. A role is then two lines:
what it provides and who it is.

## Consequences

Whoever extends fabriek adds a directory and commits it. Whoever runs a
factory writes two lines per role. Neither writes Nix that composes anything,
and the repository's `flake.nix` keeps only `flake.fabriek = import
./fabriek.nix;` beside its own devShells.

A skill is the standard's format and nothing more, so the same directory
loads in pi, Claude Code and Codex. The `skill.nix` beside it is the one
fabriek-specific file, and it is data.

Specialists are pinned by fabriek, so adding a tool to one is a fabriek
change and a machine rebuild, exactly as the floor is. That is the trade
against ADR-030 point 7 stated in the context: the kit follows the machine's
pin so that a directory can name a package without a flake around it. A
project's own dependencies do not move; they stay in its devShell.

Prompt order is declaration order and nothing smarter. A role naming
`[ "java" "python" ]` reads Java first. Two specialists that contradict each
other in prose contradict each other in the cage, and nothing here reads the
prose to notice.

Collisions in `bin/` fail the build rather than picking a winner, which
means a role cannot compose two specialists carrying different builds of one
interpreter until somebody decides which. That is the ADR-016 point 4 rule
applied to composition: never hand a specialist somebody else's tool.

The floor still sits under everything (ADR-030), so a role with no
specialist and no devShell starts as it does today. Nothing about a
declaration written before this decision changes meaning.

The default `command` means a declaration can omit the agent and still
mean pi. A repository wanting another build or another flag declares it and
gets exactly what it wrote; nothing is appended to a declared command.

## Verification

Behaviour first, in the runner each component has (`docs/roadmap.md`,
Method).

```bash
nix develop --command bats tests/unit/catalogue.bats
nix develop --command bats tests/command/factory_flake.bats
nix develop --command bats tests/command/machine_services.bats
nix develop --command bats -f "one invocation" tests/command/seam.bats
nix build .#factory
nix develop --command tests/system/journey.sh
docmeta-check docs && docmeta-tracker --check docs
```

`tests/unit/catalogue.bats` drives `modules/catalogue.sh` on fixture
directories: each refusal in point 6, the diamond flattening once, the order
of point 4, and the concatenated prompt. `factory_flake.bats` evaluates
`lib.factory` for real on a fixture repository naming specialists and reads
`bin/`, `share/fabriek/specialist/skills/<name>/SKILL.md` and
`APPEND_SYSTEM.md` out of the profile. `seam.bats` asserts the actor line's
bind word. `actor.test.ts` asserts the brief's line is present with
specialists and absent without.

On a machine, what matters is what a session can see rather than what a
module declared, as with the floor:

```bash
FABRIEK_PROOF_DIR=/tmp/proof tests/manual/observe.sh specialist
# in a cage of a role naming java: jdk on PATH, the skill listed by pi,
# and APPEND_SYSTEM.md in the system prompt
```
