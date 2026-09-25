#!/usr/bin/env bats
# The seam with a factory in a nixcage machine of its own (ADR-070 point 9).
# The host's fabriek-container asks the guest's for a plan, since the guest
# is where the role's state is, and runs the plan itself with --machine,
# since the host is where the closure can be computed. What the guest plans
# is data from inside the boundary: the host refuses any verb but enter and
# exec, and any agent socket it did not give.

load ../test_helper/common

setup() {
	setup_temp_dir
	STUB_DIR="$TEST_TEMP_DIR/bin"
	CALLS="$TEST_TEMP_DIR/calls"
	PLAN="$TEST_TEMP_DIR/plan"
	mkdir -p "$STUB_DIR"
	export PATH="$STUB_DIR:$PATH" CALLS PLAN
	export FABRIEK_LIB="$FABRIEK_ROOT/modules"
	export FABRIEK_STATE="$TEST_TEMP_DIR/state" FABRIEK_ETC="$TEST_TEMP_DIR/etc"
	export FABRIEK_MACHINE=acme
	mkdir -p "$FABRIEK_STATE" "$FABRIEK_ETC"
	# The credential up wrote, naming the operator's checkout, which the
	# machine sees read-only at the same path.
	printf 'path = "/srv/acme"\n' >"$FABRIEK_ETC/fabriek.toml"
	# The guest answers a plan request with the words in $PLAN; every call
	# is recorded, one per line, with NULs shown as |.
	cat >"$STUB_DIR/nixcage-container" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
if [ "$1 $2 $3 $4" = "machine exec acme fabriek-machine" ] && [ "$5" = role-enter ]; then
	cat "$PLAN"
fi
exit 0
EOF
	chmod +x "$STUB_DIR/nixcage-container"
}

teardown() {
	teardown_temp_dir
}

plan() {
	printf '%s\0' "$@" >"$PLAN"
}

role_enter() {
	run "$FABRIEK_ROOT/fabriek-container" role-enter "$@"
}

@test "a supervised session asks the guest for its plan and enters it with --machine" {
	plan enter --uid 60000 --no-agent --no-nix-daemon --store-root /nix/store/abc-p acme-builder /var/lib/nixcage/fabriek/acme/worktrees/acme/builder pi
	role_enter --signing-key builder acme builder
	assert_success
	run cat "$CALLS"
	assert_line --index 0 "machine exec acme fabriek-machine role-enter --plan --signing-key builder --repository /srv/acme acme builder"
	assert_line --index 1 "enter --machine acme --uid 60000 --no-agent --no-nix-daemon --store-root /nix/store/abc-p acme-builder /var/lib/nixcage/fabriek/acme/worktrees/acme/builder pi"
}

@test "a hand beside a running actor is put inside it through the machine" {
	plan exec acme-builder -- git status
	role_enter acme builder git status
	assert_success
	run cat "$CALLS"
	assert_line --index 1 "exec --machine acme acme-builder -- git status"
}

@test "a plan naming an agent socket is refused, and nothing is entered" {
	plan enter --auth-sock /run/user/1000/bus acme-builder /w
	role_enter --signing-key builder acme builder
	assert_failure
	assert_output --partial "names an agent socket, which is the host's to give"
	run grep -c "^enter" "$CALLS"
	assert_output 0
}

@test "a plan whose verb is not enter or exec is refused" {
	plan rm acme-builder
	role_enter --signing-key builder acme builder
	assert_failure
	assert_output --partial "planned 'rm', which is neither enter nor exec"
}

@test "an empty plan is refused" {
	: >"$PLAN"
	role_enter --signing-key builder acme builder
	assert_failure
	assert_output --partial "the machine planned nothing"
}

@test "a session command spelt like the agent flag is the session's, not the plan's" {
	plan enter --no-agent acme-builder /w sh -c --auth-sock
	role_enter acme builder
	assert_success
	run tail -1 "$CALLS"
	assert_output "enter --machine acme --no-agent acme-builder /w sh -c --auth-sock"
}

@test "a hand's agent is the host's to give: the guest is not told it, and the enter carries it" {
	plan enter --uid 60000 --no-agent acme-builder /w
	role_enter --auth-sock /tmp/agent.sock acme builder
	assert_success
	run cat "$CALLS"
	assert_line --index 0 "machine exec acme fabriek-machine role-enter --plan --repository /srv/acme acme builder"
	assert_line --index 1 "enter --machine acme --auth-sock /tmp/agent.sock --uid 60000 acme-builder /w"
}

@test "an agent and a signing key together are refused, as they are on the host" {
	role_enter --auth-sock /tmp/agent.sock --signing-key builder acme builder
	assert_failure
	assert_output --partial "--auth-sock and --signing-key are mutually exclusive"
	[ ! -s "$CALLS" ]
}

@test "a task directory is refused: a task reaches a role in a machine by the bus" {
	role_enter --task-dir /tmp/task acme builder
	assert_failure
	assert_output --partial "--task-dir is not available to a factory in a machine"
	[ ! -s "$CALLS" ]
}

@test "a role's worktree is prepared by the guest, where it lives" {
	run "$FABRIEK_ROOT/fabriek-container" role-worktree acme builder /srv/acme
	assert_success
	run cat "$CALLS"
	assert_output "machine exec acme fabriek-machine role-worktree acme builder /srv/acme"
}

@test "a stop at the scope reaches the machine's cage" {
	run "$FABRIEK_ROOT/fabriek-container" role-stop acme builder --now
	assert_success
	run cat "$CALLS"
	assert_output "stop --machine acme acme-builder"
}

@test "a role's transcript is read in the guest, where its home is" {
	run "$FABRIEK_ROOT/fabriek-container" role-transcript acme builder --text
	assert_success
	run cat "$CALLS"
	assert_output "machine exec acme fabriek-machine role-transcript acme builder --text"
}

@test "a repository the caller names is the one the guest is told" {
	plan enter --no-agent acme-builder /w
	role_enter --repository /srv/other acme builder
	assert_success
	run head -1 "$CALLS"
	assert_output "machine exec acme fabriek-machine role-enter --plan --repository /srv/other acme builder"
}
