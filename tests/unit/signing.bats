#!/usr/bin/env bats
# A role signs with a key of its own, and holds nothing that reaches a remote
# (ADR-009).

load ../test_helper/common

setup() {
	setup_temp_dir
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/signing.sh
	source "$FABRIEK_ROOT/modules/signing.sh"
	STATE="$TEST_TEMP_DIR/state"
}

teardown() {
	teardown_temp_dir
}

@test "each role's key is its own" {
	a="$(fabriek_signing_key_path "$STATE" builder)"
	b="$(fabriek_signing_key_path "$STATE" reviewer)"
	[ "$a" != "$b" ]
}

@test "a name that could escape the key directory is refused" {
	run fabriek_signing_key_path "$STATE" "../../root/.ssh/id_ed25519"
	assert_failure
}

@test "a key is generated once and reused" {
	first="$(fabriek_signing_ensure "$STATE" builder)"
	fingerprint="$(ssh-keygen -lf "$first.pub" | awk '{print $2}')"
	second="$(fabriek_signing_ensure "$STATE" builder)"
	[ "$first" = "$second" ]
	[ "$(ssh-keygen -lf "$second.pub" | awk '{print $2}')" = "$fingerprint" ]
}

@test "the private half is readable by nobody else" {
	key="$(fabriek_signing_ensure "$STATE" builder)"
	# The dev shell provides GNU coreutils, where -f means filesystem info.
	perms="$(stat -c '%a' "$key" 2>/dev/null || stat -f '%Lp' "$key")"
	[ "$perms" = "400" ]
}

@test "the key carries the role it belongs to, so a signature can be traced" {
	key="$(fabriek_signing_ensure "$STATE" builder)"
	run ssh-keygen -lf "$key.pub"
	assert_output --partial "builder@"
}

@test "allowed_signers names every role that has a key" {
	fabriek_signing_ensure "$STATE" builder >/dev/null
	fabriek_signing_ensure "$STATE" reviewer >/dev/null
	signers="$(fabriek_signing_signers "$STATE")"
	run cat "$signers"
	assert_output --partial "builder@"
	assert_output --partial "reviewer@"
}

@test "revoking a role is removing its line and its key" {
	fabriek_signing_ensure "$STATE" builder >/dev/null
	fabriek_signing_ensure "$STATE" reviewer >/dev/null
	fabriek_signing_revoke "$STATE" builder
	signers="$(fabriek_signing_signers "$STATE")"
	run cat "$signers"
	refute_output --partial "builder@"
	assert_output --partial "reviewer@"
}

@test "a signing session is given the key and told to use it" {
	run fabriek_signing_binds /keys/builder /keys/allowed_signers /keys/builder.gitconfig
	assert_success
	assert_line --index 0 "/keys/builder:/run/fabriek/signing-key"
	assert_line --index 1 "/keys/allowed_signers:/run/fabriek/allowed_signers"
}

@test "the role's identity goes over the session's own, not beside it" {
	# Appending made the operator's identity the base and the role's the
	# override. A role commits as itself and inherits none of it.
	run fabriek_signing_binds /keys/builder /keys/allowed_signers /keys/builder.gitconfig
	assert_line --index 2 "/keys/builder.gitconfig:/etc/gitconfig"
}

@test "a session gitconfig is a file of the role's own, named after it" {
	run fabriek_signing_gitconfig_path "$STATE" builder
	assert_success
	assert_output "$STATE/keys/builder.gitconfig"
}

@test "a name that could escape the gitconfig it names is refused" {
	run fabriek_signing_gitconfig_path "$STATE" "../../etc"
	assert_failure
}

@test "a signing session is given no agent socket at all" {
	run fabriek_signing_binds /keys/builder /keys/allowed_signers /keys/builder.gitconfig
	refute_output --partial "SSH_AUTH_SOCK"
	refute_output --partial "ssh-agent"
}

@test "the git configuration names the key by path, not by an agent" {
	run fabriek_signing_gitconfig builder
	assert_success
	assert_output --partial "signingKey = /run/fabriek/signing-key"
	assert_output --partial "allowedSignersFile = /run/fabriek/allowed_signers"
	# The agent path of ADR-008 must not appear: it is the thing being replaced.
	refute_output --partial "defaultKeyCommand"
}

@test "a role commits as itself rather than as the operator" {
	run fabriek_signing_gitconfig builder
	assert_output --partial "name = builder"
	assert_output --partial "email = builder@"
}
