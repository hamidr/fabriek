#!/usr/bin/env bats
# A role signs with a key of its own, and holds nothing that reaches a remote
# (ADR-009).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/role-uid.sh
	source "$NIXCAGE_ROOT/modules/role-uid.sh"
	# shellcheck source=../../modules/signing.sh
	source "$NIXCAGE_ROOT/modules/signing.sh"
	STATE="$TEST_TEMP_DIR/state"
}

teardown() {
	teardown_temp_dir
}

@test "each role's key is its own" {
	a="$(nixcage_signing_key_path "$STATE" builder)"
	b="$(nixcage_signing_key_path "$STATE" reviewer)"
	[ "$a" != "$b" ]
}

@test "a name that could escape the key directory is refused" {
	run nixcage_signing_key_path "$STATE" "../../root/.ssh/id_ed25519"
	assert_failure
}

@test "a key is generated once and reused" {
	first="$(nixcage_signing_ensure "$STATE" builder)"
	fingerprint="$(ssh-keygen -lf "$first.pub" | awk '{print $2}')"
	second="$(nixcage_signing_ensure "$STATE" builder)"
	[ "$first" = "$second" ]
	[ "$(ssh-keygen -lf "$second.pub" | awk '{print $2}')" = "$fingerprint" ]
}

@test "the private half is readable by nobody else" {
	key="$(nixcage_signing_ensure "$STATE" builder)"
	# The dev shell provides GNU coreutils, where -f means filesystem info.
	perms="$(stat -c '%a' "$key" 2>/dev/null || stat -f '%Lp' "$key")"
	[ "$perms" = "400" ]
}

@test "the key carries the role it belongs to, so a signature can be traced" {
	key="$(nixcage_signing_ensure "$STATE" builder)"
	run ssh-keygen -lf "$key.pub"
	assert_output --partial "builder@"
}

@test "allowed_signers names every role that has a key" {
	nixcage_signing_ensure "$STATE" builder >/dev/null
	nixcage_signing_ensure "$STATE" reviewer >/dev/null
	signers="$(nixcage_signing_signers "$STATE")"
	run cat "$signers"
	assert_output --partial "builder@"
	assert_output --partial "reviewer@"
}

@test "revoking a role is removing its line and its key" {
	nixcage_signing_ensure "$STATE" builder >/dev/null
	nixcage_signing_ensure "$STATE" reviewer >/dev/null
	nixcage_signing_revoke "$STATE" builder
	signers="$(nixcage_signing_signers "$STATE")"
	run cat "$signers"
	refute_output --partial "builder@"
	assert_output --partial "reviewer@"
}

@test "a signing session is given the key and told to use it" {
	run nixcage_signing_args /keys/builder /keys/allowed_signers
	assert_success
	assert_output --partial "--bind-ro=/keys/builder:/run/nixcage/signing-key"
	assert_output --partial "--bind-ro=/keys/allowed_signers:/run/nixcage/allowed_signers"
}

@test "a signing session is given no agent socket at all" {
	run nixcage_signing_args /keys/builder /keys/allowed_signers
	refute_output --partial "SSH_AUTH_SOCK"
	refute_output --partial "ssh-agent"
}

@test "the git configuration names the key by path, not by an agent" {
	run nixcage_signing_gitconfig builder
	assert_success
	assert_output --partial "signingKey = /run/nixcage/signing-key"
	assert_output --partial "allowedSignersFile = /run/nixcage/allowed_signers"
	# The agent path of ADR-008 must not appear: it is the thing being replaced.
	refute_output --partial "defaultKeyCommand"
}

@test "a role commits as itself rather than as the operator" {
	run nixcage_signing_gitconfig builder
	assert_output --partial "name = builder"
	assert_output --partial "email = builder@"
}
