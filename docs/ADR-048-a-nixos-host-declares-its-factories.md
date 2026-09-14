---
id: ADR-048
title: A NixOS host declares its factories, and the same file serves every other host
status: proposed
date: 2026-09-14
status_date: 2026-09-14
summary: services.fabriek renders the operator's config.toml and a unit per auto-started factory; the CLI reads /etc too
depends_on: [ADR-019, ADR-020, ADR-025, ADR-047]
supersedes: []
superseded_by: []
---

## Context

The operator's side is one file, `~/.config/fabriek/config.toml`: the
ceilings, the register of factories, the credentials, the models
(ADR-020, ADR-025). On macOS and on a non-NixOS Linux that is the right
shape, a file a person keeps. On NixOS it is the one thing on the host
that is not declared: the machines are microVMs a NixOS host runs beside
others, the cages are nixcage's host module, and the factories are a
file somebody edits under `$HOME`. A host rebuilt from its configuration
comes up with no factories registered and nothing starting them.

A NixOS operator wants what they have for everything else: options in
the host's configuration, evaluated and checked with the rest, and units
that bring the machines up at boot and down at shutdown.

## Decision

**1. `services.fabriek`, a NixOS module of this flake
(`nixosModules.host`).** Its options are the file's sections: `caps`,
`credentials.<host>.{header,file}`, `models.<host>`, and
`factories.<name>.path` with `factories.<name>.autoStart`. It renders
them to `/etc/fabriek/config.toml` as TOML, so the same schema, the same
reader and the same refusals apply as to the file a person writes;
nothing is checked twice in two languages.

**2. The CLI reads `/etc/fabriek/config.toml` when the user's file is
absent.** `FABRIEK_CONFIG` still wins, then `~/.config/fabriek/config.toml`,
then `/etc/fabriek/config.toml`. A person on a NixOS host with a personal
file keeps it; a host with only the module's file uses that. Which one
was read is what `fabriek help` prints.

**3. A unit per auto-started factory.** `factories.<name>.autoStart =
true` gives `fabriek-<name>.service`: `fabriek up <name>` at start,
`fabriek down <name>` at stop, `Type=oneshot` with `RemainAfterExit`,
after the network and nix-daemon, machines under `/var/lib/fabriek`. The
CLI by hand and the unit are the same program on the same state, so
`fabriek ps` shows both.

**4. The module writes the file; the CLI never does.** There is no
`fabriek register`; a factory is registered by editing the file or the
option. One source of truth per host.

## Consequences

A NixOS host declares its factories beside its cages and its microVMs,
and a rebuild is a host with its factories registered and, when asked,
running. Every other host keeps the file, and the file is what the module
produces, so a person can read the one to understand the other.

Credentials stay files named by path (ADR-025); the module names the
path and never the value, so a secret manager's path fits and nothing
about a credential enters the store.

The unit runs as root because the machine's runner needs the host's
virtualisation and its state lives under `/var/lib`; that is what
microvm.nix's own host units do.

## Verification

```bash
nix develop --command bats tests/command/host_module.bats
nix develop --command bats tests/unit/operator_config.bats
```

`host_module.bats` evaluates a NixOS configuration with the module for
real and reads back the rendered TOML and the unit; `operator_config.bats`
asserts the order the CLI reads the files in. On a NixOS host: a factory
with `autoStart` is running after boot and `fabriek ps` says so; not run
as of this document's date.
