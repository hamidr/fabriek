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
# Three things changed with ADR-037 and ADR-040, and each is a flag here. A
# cage is on the factory's bridge at the address the machine's plan gives its
# role, and has no nix daemon (--network, --no-nix-daemon); its toolchain is
# the profile the build realised, handed in on the front of PATH
# (NIXCAGE_PATH_PREFIX) rather than a devShell entered inside (--shell is
# gone); and the session runs as the block's base uid, because loop and agent
# are one process under one uid (ADR-035) and --subject is gone with ADR-028.
# The journal bind is gone with the ledger (ADR-038). The cage is named after
# its role alone, because nspawn names its veth after the cage.
#
# The in-cage paths move from /run/nixcage and /etc/nixcage to /run/cageworks
# and /etc/cageworks because nixcage refuses a bind over its own /etc.

load ../test_helper/common

setup() {
	setup_temp_dir

	STATE="$TEST_TEMP_DIR/state"
	STUB_DIR="$TEST_TEMP_DIR/bin"
	CALLS="$TEST_TEMP_DIR/nixcage-container-calls"
	STORAGE_CALLS="$TEST_TEMP_DIR/nixcage-container-storage"
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
uid)
	# A principal's number. A subject is never asked for any more (ADR-035),
	# so asking for one is answered the way a machine with none would.
	if [ -n "\$3" ]; then echo "no such subject: \$3" >&2; exit 1; fi
	echo 60000
	;;
storage)
	printf '%s\n' "\$*" >>"$STORAGE_CALLS"
	mkdir -p "\$3"
	;;
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
	declare_machine
}

## What the machine's build put on it (ADR-040): the bridge plan the session
## takes its address from, and the profile its toolchain is.
declare_machine() {
	export CAGEWORKS_ETC="$TEST_TEMP_DIR/etc"
	mkdir -p "$CAGEWORKS_ETC/roles/builder" "$TEST_TEMP_DIR/store/role-builder/bin"
	ln -s "$TEST_TEMP_DIR/store/role-builder" "$CAGEWORKS_ETC/roles/builder/profile"
	# The session is handed the resolved store path, which on a host that
	# symlinks /tmp is not the path the link was written with.
	PROFILE="$(readlink -f "$TEST_TEMP_DIR/store/role-builder")"
	cat >"$CAGEWORKS_ETC/bridge.json" <<'JSON'
{ "bridge": "cageworks-acme", "host": "10.77.0.1", "prefix": 24,
  "cages": { "builder": "10.77.0.10", "decider": "10.77.0.2" },
  "proxy": "10.77.0.1:8118", "forgejo": "10.77.0.1:3000", "valkey": "10.77.0.1:6379" }
JSON
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
	assert_output "--uid 60000 --user builder --home $STATE/homes/acme-builder --network cageworks-acme:10.77.0.10/24 --no-nix-daemon --setenv NIXCAGE_PATH_PREFIX=$PROFILE/bin --no-agent --bind-ro $CAGEWORKS_LIB/role-guidance.md:/etc/cageworks/role-guidance.md --setenv CAGEWORKS_ROLE_GUIDANCE=/etc/cageworks/role-guidance.md --bind $TEST_TEMP_DIR/run:/run/cageworks/task --setenv CAGEWORKS_TASK=/run/cageworks/task --bind-ro $STATE/keys/builder:/run/cageworks/signing-key --bind-ro $STATE/keys/allowed_signers:/run/cageworks/allowed_signers --bind-ro $STATE/keys/builder.gitconfig:/etc/gitconfig builder $STATE/worktrees/acme/builder agent --print"
}

@test "a person entering a role forwards their agent and gets no cage key" {
	run_cageworks_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success

	run recorded
	assert_output "--uid 60000 --user builder --home $STATE/homes/acme-builder --network cageworks-acme:10.77.0.10/24 --no-nix-daemon --setenv NIXCAGE_PATH_PREFIX=$PROFILE/bin --auth-sock /tmp/agent.sock --bind-ro $CAGEWORKS_LIB/role-guidance.md:/etc/cageworks/role-guidance.md --setenv CAGEWORKS_ROLE_GUIDANCE=/etc/cageworks/role-guidance.md builder $STATE/worktrees/acme/builder agent --print"
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

@test "given no bridge plan on the machine, a session is refused rather than started off the bridge" {
	rm "$CAGEWORKS_ETC/bridge.json"
	run_cageworks_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_failure
	assert_output --partial "bridge"
	[ ! -f "$CALLS" ]
}

@test "a role the plan does not place gets no session, because it would have no address" {
	cat >"$CAGEWORKS_ETC/bridge.json" <<'JSON'
{ "bridge": "cageworks-acme", "host": "10.77.0.1", "prefix": 24, "cages": { "decider": "10.77.0.2" } }
JSON
	run_cageworks_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_failure
	assert_output --partial "builder"
	[ ! -f "$CALLS" ]
}

@test "a role whose build realised no profile enters with the floor alone" {
	rm "$CAGEWORKS_ETC/roles/builder/profile"
	run_cageworks_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success
	run recorded
	refute_output --partial "NIXCAGE_PATH_PREFIX"
	assert_output --partial "--no-nix-daemon --auth-sock"
}


# --private-users-ownership=off means a host file has to already carry the uid
# the session runs as, and libgit2 refuses a repository owned by anyone else.
# Loop and agent are one uid now (ADR-035), and it is the principal's own.
@test "the worktree is owned by the uid that opens it" {
	run_cageworks_container role-worktree acme builder "$REPO"
	assert_success
	run cat "$STORAGE_CALLS"
	assert_output --partial "ensure $STATE/worktrees/acme/builder 60000"
}
