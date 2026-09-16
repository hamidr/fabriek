---
id: ADR-063
title: A person beside the unit reaches the machine with their own key, which the host names as an operator's
status: proposed
date: 2026-09-16
status_date: 2026-09-16
summary: the host lists operator public keys, the machine accepts them, and a hand without the unit key uses its own
depends_on: [ADR-019, ADR-048, ADR-057]
supersedes: []
superseded_by: []
---

## Context

On a NixOS host the factory's machine is started by a unit, as root, and
its state is root's: the machine's ssh key under
`/var/lib/fabriek/machines/<factory>/id_ed25519` is `0600` (ADR-019), and
the hand and the unit are one program on one state (ADR-048 point 3). The
first day on such a host showed the half that did not follow: `fabriek
ps` sees the machine, `check`, `ls` and `show <name>` need nothing of it,
and every verb that reaches the machine (`console`, `enter`, `show -f`,
`log`, `file`, `steer`, `board`, `watch`, `send`, `mirror`) answers
`Load key ... Permission denied` to the person who declared the factory,
unless they are root.

A key readable by a group is not a way out: ssh refuses a private key
another uid could read, on purpose. What a person has is a key of their
own, and what the machine has is a list of keys it accepts, which today
holds one.

## Decision

**1. The host names its operators by their public keys.** `config.toml`
gains a top-level `operatorKeys`, a list of public keys as `authorized_keys`
carries them (`ssh-ed25519 AAAA... comment`); `services.fabriek.operatorKeys`
is the same as an option, and a NixOS host would usually write
`operatorKeys = config.users.users.<me>.openssh.authorizedKeys.keys`. The
reader refuses an entry that is not one key on one line.

**2. The machine accepts them beside its own.** `up` writes
`authorized_keys` under the machine's directory, the machine's public key
first and each operator key after, and hands that file to the machine as
the `fabriek.authorized_keys` credential (ADR-057 point 3) in place of
`id_ed25519.pub`. A key added to the file is a `down` and `up` away from
the machine, as any change to the credential is; nothing reaches into a
running machine's sshd.

**3. A hand that cannot read the unit's key reaches with its own.** When
`fabriek_machine_ssh_args` finds the machine's key unreadable it names no
identity and lets ssh use the person's own keys and agent, and it keeps
the machine's host key under the person's own state,
`$XDG_STATE_HOME/fabriek/known_hosts/<factory>`, since the machine's file
under `/var/lib` is root's too. The first hand sees the machine's host key
once (`accept-new`) as the unit did; a machine that changes identity is
still refused by name. The port and the pid stay readable by everyone,
as they are.

**4. Nothing of this reaches a cage.** An operator key is an
`authorized_keys` line for the machine's root, which is what the unit's
key already is; the cages' side of the machine is untouched (invariants
1 to 3 of `CLAUDE.md`).

## Consequences

The person who declared a factory on their NixOS host works it from their
own shell, and `sudo` is for the unit's own state only. A host with no
operator keys is where it is today: root, or the unit. A person whose key
is not in the list is refused by the machine's sshd, not by a file mode,
which is the refusal that says what to do.

`modules/operator-config.sh` grows the key; `modules/host.nix` the option;
`fabriek` writes `authorized_keys` and names it in `runtime.json`;
`modules/machine.sh` falls back to the person's own identity and known
hosts. `seam.bats` is untouched: the session line is the machine's.

## Verification

```bash
nix develop --command bats tests/unit/operator_config.bats tests/unit/machine.bats \
  tests/command/vm_up.bats tests/command/host_module.bats
docmeta-check docs && docmeta-tracker --check docs
```

Scenarios, written first: a key accepted and a line that is not one
refused; `up` writing `authorized_keys` with the machine's key first and
the operator's after, named in `runtime.json`; the ssh arguments naming
the unit's key when it is readable and no identity, with the person's
known hosts file, when it is not; the module rendering the option. On
the pc: `fabriek -f example console` as the operator, no `sudo`,
after a `down` and `up` of the unit. Recorded here when run.
