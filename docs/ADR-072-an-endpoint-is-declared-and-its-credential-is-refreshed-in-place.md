---
id: ADR-072
title: An endpoint is declared by the operator and its credential is refreshed in place
status: implementing
date: 2026-11-03
status_date: 2026-11-03
summary: the operator declares endpoints beyond the built-in three; a changed credential file reaches the proxy, no restart
depends_on: [ADR-020, ADR-029, ADR-037, ADR-061, ADR-067, ADR-070]
supersedes: []
superseded_by: []
---

## Context

The operator's own pi (`pi-dev`, in the operator's NixOS config) reaches a
company AI gateway: Bedrock Claude behind Entra ID, at a host fabriek has
never heard of, authenticated by a bearer token that lives about ninety
minutes and comes from `az account get-access-token` after an interactive
`az login`. The gateway answers on public addresses (an unauthenticated
`GET /v1/models` from the operator's Mac returns 401), so a VM on the LAN
reaches it without the Mac's VPN. The operator wants a factory's roles to use
it. Two things in fabriek stop that.

**Routing is a table in code.** `FABRIEK_PROVIDERS` in
`modules/factory-render.sh:83` maps three hosts (`api.anthropic.com`,
`api.openai.com`, `api.deepseek.com`) to pi's built-in providers, and
`FABRIEK_DEFAULT_MODELS` (line 84) gives each a starting model. An endpoint
outside the table is reachable through the proxy and pi is never pointed at
it (`fabriek_render_routed`, `fabriek_render_models`). Nothing else reads
either constant. Adding a host is a change to fabriek, and a company's
gateway host does not belong in it.

**A credential is read once.** `credentials.<host>` is a `header` and a
`file` (`modules/host.nix:329`). At `factory-up`, `fabriek_up_secrets`
(`modules/factory-up.sh:127`) copies the operator's file into the factory's
state for the proxy's user, restarts `fabriek-<factory>-egress-credentials`
and reloads nginx; the unit turns the copy into an nginx header include. The
operator's file is never read again, so a token that expires in ninety minutes
would end every run that outlives it, and the operator would find out from a
401 mid-task.

The token cannot be minted where fabriek runs. The host is a NixOS VM on the
operator's Mac (devbox) with no `az` and no browser, and fabriek opens no SSH
connection (ADR-067). The Mac holds a key devbox accepts.

## Decision

**1. An endpoint is declared, and the built-in three become data.** A new
operator table `endpoints.<host>` (`services.fabriek.endpoints` and the
`endpoints` key of `config.toml`, beside `credentials` and `models`, ADR-061)
names per host the pi provider that answers it, its `api` where that is not the
provider's own, and a `compat` map copied into the provider's entry in
`models.json`. The gateway needs `supportsEagerToolInputStreaming = false` and
`supportsStrictTools = false`, which pi's `models.json` takes for
`anthropic-messages` (pi `docs/models-configuration.md`). The starting model
stays `models.<host>`; a declared endpoint outside the shipped three with no
`models` entry fails the render rather than starting pi on no model.
fabriek ships the three current hosts as default entries in the same table, so
nothing changes for an operator who declares none, and both constants are
deleted. The table is the operator's alone: a repository's `fabriek.toml`
cannot declare an endpoint, since that would widen its own reach (ADR-020). An
endpoint is still routed only if the declaration's `egress` allows it and the
operator's ceiling does. `models.json` keys a provider by name, so two allowed
endpoints answering as one provider are refused by the render, naming it.

**2. A credential file is re-read when it changes.** One function, called by
`fabriek_up_secrets` and by a systemd path unit on each declared
`credentials.<host>.file`, copies the file into the state of every factory
whose clamped endpoints hold that host (credentials are the host's, the
allowed endpoints each factory's), restarts that factory's
`egress-credentials` unit, and runs `systemctl reload nginx.service`. It never
restarts nginx on this path: a restart drops every connection a cage holds
open, resets the spend count, and counts against the start limit (the reload
is what `factory-up` already does). The file is the whole header value, as
today (`Bearer <token>` for the gateway). A copy that fails leaves the
previous header in place.

**3. The token's source is the operator's, and it pushes.** fabriek names a
file on its host and knows nothing about `az`. The operator's Mac runs the
existing `zd-gateway-token` on a timer, about every forty-five minutes, and
writes the file on the host through the operator's own SSH to it, to a
temporary name renamed into place. The file sits in a directory the operator
owns, mode 0700 (`/var/lib/fabriek-credentials`, a tmpfiles rule), and the path
unit watches the directory, not the file: a rename replaces the inode a file
watch holds, and a directory sees the create and the move. The operator's key
gains write access to that one directory and no root. That keeps ADR-067:
fabriek opens no connection, and the `az login` stays where a browser is.

**4. A credential carries an age, and past its `maxAge` the executor holds new
work.** The refresh function touches a stamp per credential in the factory's
state, readable by the executor (the credential's own copy is the proxy
user's alone), so its mtime is the last successful refresh. `fabriek ps` gains
a line per credential with its age (today it prints a factory's state and
revision only). A credential may declare `maxAge`; past it the executor stops
routing new assignments to roles whose endpoint uses that credential, running
turns finish, and routing resumes when a refresh moves the stamp, as the soft
limit does (ADR-037 point 4). Without `maxAge` the age is shown and nothing
reads it. The executor reads a time, never a token: it stays content-blind and
the token's own expiry is not parsed.

**5. The proxy strips the placeholder key.** pi sends `models.json`'s
placeholder `apiKey` as `x-api-key`. For every endpoint whose credential
header is not `x-api-key`, the proxy removes the incoming one before it adds
the credential, so the gateway sees `Authorization` alone and no endpoint
depends on how an upstream treats a header it did not ask for.

**Rejected alternatives.**
- A gateway entry in `FABRIEK_PROVIDERS`: puts a company host in this
  repository, and the next operator's host is another edit here.
- `az` on the host with a device-code login: a second interactive login to
  keep alive on a machine nobody sits at, for a token the Mac already makes.
- A `command` the host runs to fetch the token: root, or the proxy's user,
  would run an operator-named program on a timer, which is more authority
  than reading a file and invites `az` into the host's closure.
- The token in the cage, with pi-dev's extension calling the helper: a cage
  would hold a credential that reaches a host, which ADR-037 exists to forbid.
- Restarting the egress unit and nginx on every refresh: drops running turns
  twice an hour.
- A static key: the gateway accepts Entra tokens only.
- Running the factory on the Mac: fabriek is a Linux host program (ADR-067).
- Showing the age and acting on nothing: a lapsed `az login` would spend the
  executor's attempts on 401s before anyone looked.
- A repository declaring its own endpoints: widens reach from the inside.
- Forwarding the placeholder and testing the gateway: leaves the outcome to
  the gateway's behavior, found on a real turn.
- Discovering the model list from the gateway at render: the render would
  need a live token and the network, and a stale token would fail the whole
  `factory-up`. A role has no picker to use the list.
- The token file in the operator's home, watched as a file: a rename swaps
  the inode and the watch can miss it, so refresh would stop without a sign.
- A root-only file written through `sudo tee`: gives the operator's key a
  passwordless root write, more authority than a directory it already owns.
- Dropping the key from `models.json`: pi treats a provider with no key as
  unconfigured and will not start a session on it.

## Consequences

A factory on the gateway works only while the Mac is awake, `az` is logged in,
and the push reaches the host. A lapsed `az login` (the refresh token ends
after days) holds new work once `maxAge` passes and shows the age; runs in
flight when a push is missed fail at the next request after expiry, under the
executor's attempt limit. A stamp moved without a fresh token (a clock fault,
a push of an unchanged file) un-holds a factory that will still get 401s, and
a `maxAge` shorter than the push interval freezes a healthy one.

The deepseek token is a root-only sops file (`hardware/pc/system/fabriek.nix`
in the operator's config). The pushed token is written by the operator's user,
so the file is the operator's to read and write and the proxy's user reads a
copy; a cage still cannot reach either.

The proxy reloads about twice an hour per credential. A reload keeps nginx's
shared zones of unchanged name and size, so the spend count (ADR-037 point 4)
is expected to survive; the measurement plan checks it.

The built-in table moves out of shell into data the render and the host module
both read, so a new built-in endpoint is one entry rather than two edits.

## Measurement plan

```bash
nix develop --command bats -f "an operator-declared endpoint" tests/unit/factory_render.bats
```
Passes when `models.json` routes a declared host through the proxy with its
`compat`, the render refuses a declared host with no `models` entry, the
three built-in hosts render byte-identical to before, and the proxy's
location for a non-`x-api-key` endpoint clears the incoming `x-api-key`.

```bash
nix develop --command bats tests/command/egress_refresh.bats
```
Passes when a changed credential file yields the new header in every factory
that holds the host, with one `reload` and no `restart` of nginx, the stamp
moves only on a successful copy, and a failed copy leaves the old header.

```bash
nix develop --command bash -c 'cd factory && tsc -p . && cp src/relay/fixtures.json dist/relay/ \
  && node --test --test-name-pattern="credential age" dist/executor/*.test.js'
```
Passes when the executor routes nothing new to a role whose credential is past
`maxAge`, lets running turns finish, resumes when the stamp moves, and ignores
the age when `maxAge` is absent.

```bash
nix develop --command bats tests/command/host_module.bats
```
Passes when `nixosModules.host` evaluates with a declared endpoint and a path
unit per credential file, and a repository declaring an endpoint is refused.

```bash
FABRIEK_PROOF_DIR=/tmp/proof tests/manual/gateway.sh
```
Passes on the host with a real token pushed from the Mac: a turn against the
gateway returns 200; a push by rename into the directory moves the stamp
within a minute; a second push mid-turn leaves the connection open, the
next request carries the new header, and the spend count does not reset;
`fabriek ps` shows an age under forty-five minutes; no role can read the
credential file.

```bash
docmeta-check docs && docmeta-tracker --check docs
```

## Tasks

- [x] T1 The render reads a merged endpoint table: defaults in `modules/endpoints.json`, `compat` and `api` in `models.json`, a declared host with no model refused, both constants deleted
- [ ] T2 The operator's `endpoints` key reaches the render: schema, credential projection, clamp to allowed egress, `endpoints.json`; a repository's declaration carrying one is refused (after: T1)
- [ ] T3 `services.fabriek.endpoints` renders into the operator's `config.toml` (after: T2)
- [ ] T4 The proxy clears the incoming `x-api-key` for an endpoint whose credential header is another (after: T2)
- [ ] T5 One credential-refresh function, used by `fabriek_up_secrets` and a `credential-refresh` verb that reaches every factory holding the host, touching a stamp on success
- [ ] T6 A path unit per credential file watches a directory the operator owns, and runs the verb (after: T5)
- [ ] T7 `fabriek ps` prints a line per credential with its age (after: T5)
- [ ] T8 `credentials.<host>.maxAge` reaches the executor, which holds new work past it and resumes when the stamp moves (after: T2, T5)
- [ ] T9 The operator's Mac pushes the token to the host's directory on a timer, in the NixOS repository (after: T6)
- [ ] G1 `nix develop --command bats -f "an operator-declared endpoint" tests/unit/factory_render.bats` (after: T1, T4)
- [ ] G2 `nix develop --command bats tests/command/egress_refresh.bats` (after: T5)
- [ ] G3 `nix develop --command bats tests/command/host_module.bats` (after: T3, T6)
- [ ] G4 `nix develop --command bash -c 'cd factory && tsc -p . && cp src/relay/fixtures.json dist/relay/ && node --test --test-name-pattern="credential age" dist/executor/*.test.js'` (after: T8)
- [ ] G5 `FABRIEK_PROOF_DIR=/tmp/proof tests/manual/gateway.sh` on the host with a real token (after: T1, T2, T3, T4, T6, T7, T8, T9)
- [ ] G6 `docmeta-check docs && docmeta-tracker --check docs` (after: G1, G2, G3, G4)
