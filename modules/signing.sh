# shellcheck shell=bash
## The key a role signs with (ADR-009).
##
## A run the supervisor starts holds no forwarded agent. It signs with a key
## that belongs to its role and appears in no host's authorized_keys, so it
## cannot push, pull a private repository, or authenticate anywhere. The key
## sits at rest inside the cage for the length of the run, which ADR-008
## declined for the operator's key and which is acceptable here because this
## key's only authority is to produce a signature: exfiltrating it costs a
## revocation line rather than access to anything.
##
## Sourced by store path into cageworks-container alongside names.sh.

cageworks_signing_key_path() {
	local state="$1" role="$2"
	cageworks_name_ok "$role" || return 1
	echo "$state/keys/$role"
}

cageworks_signing_signers() {
	echo "$1/keys/allowed_signers"
}

## Where a role's session gitconfig is written before it is bound over the
## operator's. A file rather than an append into the session's own /etc,
## because the rootfs a session is built in is nixcage's and everything
## cageworks puts in a cage arrives as a bind (ADR-018).
cageworks_signing_gitconfig_path() {
	local state="$1" role="$2"
	cageworks_name_ok "$role" || return 1
	echo "$state/keys/$role.gitconfig"
}

## Rebuild the file that says which key belongs to which role. Written whole
## from the keys that exist, so removing a key removes its line and there is
## no second place for the two to disagree.
cageworks_signing_index() {
	local state="$1"
	local dir="$state/keys"
	local signers
	signers="$(cageworks_signing_signers "$state")"
	mkdir -p "$dir"

	local tmp="$dir/.allowed_signers.$$"
	: >"$tmp"
	local pub role
	for pub in "$dir"/*.pub; do
		[ -f "$pub" ] || continue
		role="$(basename "$pub" .pub)"
		printf '%s@factory.invalid %s\n' "$role" "$(cat "$pub")" >>"$tmp"
	done
	mv "$tmp" "$signers"
}

## Generate a role's key on first use and hand it to that role's uid. Created
## by the supervisor rather than by the agent, so the public half is readable
## without reaching into a cage.
cageworks_signing_ensure() {
	local state="$1" role="$2" uid="${3:-}"
	local key
	key="$(cageworks_signing_key_path "$state" "$role")" || return 1

	if [ ! -f "$key" ]; then
		mkdir -p "$(dirname "$key")"
		ssh-keygen -q -t ed25519 -N '' -C "$role@factory.invalid" -f "$key" || return 1
	fi
	chmod 400 "$key"
	[ -n "$uid" ] && chown "$uid" "$key"
	cageworks_signing_index "$state" || return 1
	echo "$key"
}

## Revoking a role is deleting its key and its line, which this does together
## because a key without a line still signs and a line without a key still
## verifies.
cageworks_signing_revoke() {
	local state="$1" role="$2"
	local key gitconfig
	key="$(cageworks_signing_key_path "$state" "$role")" || return 1
	gitconfig="$(cageworks_signing_gitconfig_path "$state" "$role")" || return 1
	rm -f "$key" "$key.pub" "$gitconfig"
	cageworks_signing_index "$state"
}

## What a signing session is given, as SRC:DST pairs for nixcage's --bind-ro.
## Note what is absent: no agent socket and no SSH_AUTH_SOCK, because a run
## nobody is watching must hold nothing that reaches a host.
##
## The gitconfig goes over the session's own, rather than being appended to it.
## Appending made the operator's identity the base and the role's the override;
## a role commits as itself and inherits none of it, and there is no rootfs
## here to append into in any case.
cageworks_signing_binds() {
	local key="$1" signers="$2" gitconfig="$3"
	echo "$key:/run/cageworks/signing-key"
	echo "$signers:/run/cageworks/allowed_signers"
	echo "$gitconfig:/etc/gitconfig"
}

## The git configuration a role's session gets. It names the key by path, which
## git accepts for gpg.format=ssh and which needs no agent, and it commits as
## the role so a signature is attributable to the role rather than being
## indistinguishable from the operator's.
cageworks_signing_gitconfig() {
	local role="$1"
	cageworks_name_ok "$role" || return 1
	cat <<EOF
[user]
  name = $role
  email = $role@factory.invalid
  signingKey = /run/cageworks/signing-key
[gpg]
  format = ssh
[gpg "ssh"]
  allowedSignersFile = /run/cageworks/allowed_signers
[commit]
  gpgsign = true
[tag]
  gpgsign = true
EOF
}
