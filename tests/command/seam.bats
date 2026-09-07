#!/usr/bin/env bats
# The seam ADR-018 names. A role session started through cageworks-container
# must reach nixcage-container as one invocation whose flags say exactly what
# modules/container.nix used to build inline, so moving the factory out cannot
# quietly change what a role session is.
#
# Every expectation here is read off the pre-split container.nix:
#
#   --role <role>    allocated a uid and wrote the role's name into the
#                    container's /etc/passwd     -> --uid and --user
#   the home         was $STATE/homes/<name>     -> --home
#   --shell <name>   set NIXCAGE_SHELL           -> --shell, unchanged
#   --signing-key    bound the key and the signers file and appended the
#                    role's identity to the session gitconfig
#                                                -> --no-agent and three
#                                                   --bind-ro
#   --task-dir       bound the run directory and named it in the environment
#                                                -> --bind and --setenv
#   the role guidance was bound read-only and named in the environment
#                                                -> --bind-ro and --setenv
#
# One flag is newer than the split. The journal socket a role writes its
# ledger to is not in a cage's own /run until it is asked for (ADR-027 point
# 5), and asking for it is a --bind like any other, which is the whole reason
# that decision needs nothing new from nixcage.
#
# The in-cage paths move from /run/nixcage and /etc/nixcage to /run/cageworks
# and /etc/cageworks because nixcage refuses a bind over its own /etc.

load ../test_helper/common

setup() {
	setup_temp_dir

	STATE="$TEST_TEMP_DIR/state"
	STUB_DIR="$TEST_TEMP_DIR/bin"
	CALLS="$TEST_TEMP_DIR/nixcage-container-calls"
	mkdir -p "$STATE" "$STUB_DIR"
	PATH="$STUB_DIR:$PATH"
	export PATH STATE

	export CAGEWORKS_LIB="$CAGEWORKS_ROOT/modules"
	export CAGEWORKS_STATE="$STATE"

	# The seam itself. Only 'enter' is recorded; the other two primitives
	# answer so that role-enter gets far enough to emit one.
	cat >"$STUB_DIR/nixcage-container" <<EOF
#!/usr/bin/env bash
case "\$1" in
uid) echo 60000 ;;
storage) mkdir -p "\$3" ;;
enter)
	shift
	printf '%s\n' "\$*" >>"$CALLS"
	;;
esac
EOF
	# Root-only mechanics a role's worktree needs, and which say nothing
	# about the seam.
	for tool in chown setfacl; do
		printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_DIR/$tool"
	done
	chmod +x "$STUB_DIR/nixcage-container" "$STUB_DIR/chown" "$STUB_DIR/setfacl"

	declare_factory
}

teardown() {
	teardown_temp_dir
}

# A repository that declares the factory working it (ADR-020), naming one role
# with a toolchain and a command of its own -- the case that exercises every
# flag. The declaration is committed, because that is what is read.
declare_factory() {
	REPO="$TEST_TEMP_DIR/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init --quiet -b main
	git -C "$REPO" config user.email test@example.invalid
	git -C "$REPO" config user.name test
	cat >"$REPO/flake.nix" <<'EOF'
{
  outputs = { self }: {
    cageworks = {
      name = "acme";
      roles.builder = {
        command = [ "agent" "--print" ];
        provides = [ "build" ];
        shell = "backend";
      };
    };
  };
}
EOF
	git -C "$REPO" add -A
	git -C "$REPO" -c commit.gpgsign=false commit --quiet -m "first"
}

recorded() {
	cat "$CALLS"
}

@test "a supervised role session reaches nixcage-container as one invocation" {
	mkdir -p "$TEST_TEMP_DIR/run"
	run_cageworks_container role-enter --repository "$REPO" \
		--task-dir "$TEST_TEMP_DIR/run" --signing-key builder \
		acme builder
	assert_success

	run recorded
	assert_output "--uid 60000 --user builder --home $STATE/homes/acme-builder --shell backend --no-agent --bind /run/systemd/journal.acme/socket:/run/systemd/journal/socket --bind-ro $CAGEWORKS_LIB/role-guidance.md:/etc/cageworks/role-guidance.md --setenv CAGEWORKS_ROLE_GUIDANCE=/etc/cageworks/role-guidance.md --bind $TEST_TEMP_DIR/run:/run/cageworks/task --setenv CAGEWORKS_TASK=/run/cageworks/task --bind-ro $STATE/keys/builder:/run/cageworks/signing-key --bind-ro $STATE/keys/allowed_signers:/run/cageworks/allowed_signers --bind-ro $STATE/keys/builder.gitconfig:/etc/gitconfig acme-builder $STATE/worktrees/acme/builder agent --print"
}

@test "a person entering a role forwards their agent and gets no cage key" {
	run_cageworks_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success

	run recorded
	assert_output "--uid 60000 --user builder --home $STATE/homes/acme-builder --shell backend --auth-sock /tmp/agent.sock --bind /run/systemd/journal.acme/socket:/run/systemd/journal/socket --bind-ro $CAGEWORKS_LIB/role-guidance.md:/etc/cageworks/role-guidance.md --setenv CAGEWORKS_ROLE_GUIDANCE=/etc/cageworks/role-guidance.md acme-builder $STATE/worktrees/acme/builder agent --print"
}

@test "the uid comes from nixcage rather than from a store cageworks keeps" {
	run_cageworks_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success
	# Nothing under cageworks' own state records an allocation: the number
	# is nixcage's to hand out and never to reissue.
	run find "$STATE" -name "role-uids*"
	assert_output ""
}

@test "a role's worktree asks nixcage for its storage rather than running zfs" {
	# The primitive is what creates the directory in this test, so a
	# worktree that exists is proof it was asked for.
	run_cageworks_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success
	[ -d "$STATE/worktrees/acme/builder" ]
}

@test "the role's own identity is what the session's gitconfig says" {
	run_cageworks_container role-enter --repository "$REPO" \
		--task-dir "$TEST_TEMP_DIR/run" --signing-key builder \
		acme builder
	assert_success
	run cat "$STATE/keys/builder.gitconfig"
	assert_output --partial "email = builder@factory.invalid"
	assert_output --partial "signingKey = /run/cageworks/signing-key"
	assert_output --partial "allowedSignersFile = /run/cageworks/allowed_signers"
}

@test "an agent socket and a cage key are refused together" {
	run_cageworks_container role-enter \
		--auth-sock /tmp/agent.sock --signing-key builder acme builder
	assert_failure
	assert_output --partial "mutually exclusive"
}

@test "a role session can reach the journal it writes its ledger to" {
	run_cageworks_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success

	# The socket is namespaced by factory outside and unnamespaced inside,
	# because journald's client code opens one path and the machine keeps a
	# separate journal per factory (ADR-027 points 5 and 6).
	run recorded
	assert_output --partial "--bind /run/systemd/journal.acme/socket:/run/systemd/journal/socket"
}

@test "no session is handed another factory's journal" {
	run_cageworks_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success
	run recorded
	refute_output --partial "journal.builder"
	refute_output --partial "/run/systemd/journal/socket:/run/systemd/journal.acme/socket"
}
