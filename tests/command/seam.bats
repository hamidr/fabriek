#!/usr/bin/env bats
# The seam ADR-018 names. A role session started through fabriek-container
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
# The in-cage paths move from /run/nixcage and /etc/nixcage to /run/fabriek
# and /etc/fabriek because nixcage refuses a bind over its own /etc.

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

	export FABRIEK_LIB="$FABRIEK_ROOT/modules"
	export FABRIEK_STATE="$STATE"

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
	# Whether a cage of the role's name is running, which a hand session
	# asks before taking a veth. No cage runs unless a scenario says so.
	printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB_DIR/pgrep"
	chmod +x "$STUB_DIR/pgrep"
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
	export FABRIEK_ETC="$TEST_TEMP_DIR/etc"
	mkdir -p "$FABRIEK_ETC/roles/builder" "$TEST_TEMP_DIR/store/role-builder/bin" "$TEST_TEMP_DIR/store/pi-builder/extensions"
	ln -s "$TEST_TEMP_DIR/store/role-builder" "$FABRIEK_ETC/roles/builder/profile"
	# The role's own pi directory (ADR-042 point 5): the loop, the models and
	# its specialists' kit, one store path per role beside its profile.
	ln -s "$TEST_TEMP_DIR/store/pi-builder" "$FABRIEK_ETC/roles/builder/pi"
	# The session is handed the resolved store path, which on a host that
	# symlinks /tmp is not the path the link was written with.
	PROFILE="$(readlink -f "$TEST_TEMP_DIR/store/role-builder")"
	PIDIR="$(readlink -f "$TEST_TEMP_DIR/store/pi-builder")"
	cat >"$FABRIEK_ETC/bridge.json" <<'JSON'
{ "bridge": "fabriek-acme", "host": "10.77.0.1", "prefix": 24,
  "cages": { "builder": "10.77.0.10", "decider": "10.77.0.2" },
  "proxy": "10.77.0.1:8118", "forgejo": "10.77.0.1:3000", "valkey": "10.77.0.1:6379" }
JSON
	cat >"$FABRIEK_ETC/declaration.json" <<'JSON'
{ "name": "acme", "roles": { "builder": { "command": ["agent", "--print"], "provides": ["build", "test"], "shell": "backend", "specialists": ["java", "python"] } } }
JSON
	# What prepare made for the role: its bus password and its forge token.
	mkdir -p "$STATE/bus" "$STATE/forge" "$FABRIEK_ETC/pi-decider/extensions"
	echo pass >"$STATE/bus/builder"
	echo tok >"$STATE/forge/builder-token"
	echo pass >"$STATE/bus/decider"
	echo tok >"$STATE/forge/decider-token"
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
    fabriek = {
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
	run_fabriek_container role-enter --repository "$REPO" \
		--task-dir "$TEST_TEMP_DIR/run" --signing-key builder \
		acme builder
	assert_success

	run recorded
	assert_output "--uid 60000 --user builder --home $STATE/homes/acme-builder --network fabriek-acme:10.77.0.10/24 --no-nix-daemon --setenv NIXCAGE_PATH_PREFIX=$PROFILE/bin --no-agent --bind-ro $FABRIEK_LIB/role-guidance.md:/etc/fabriek/role-guidance.md --setenv FABRIEK_ROLE_GUIDANCE=/etc/fabriek/role-guidance.md --bind $TEST_TEMP_DIR/run:/run/fabriek/task --setenv FABRIEK_TASK=/run/fabriek/task --bind-ro $STATE/keys/builder:/run/fabriek/signing-key --bind-ro $STATE/keys/allowed_signers:/run/fabriek/allowed_signers --bind-ro $STATE/keys/builder.gitconfig:/etc/gitconfig --bind-ro $PIDIR:/run/fabriek/pi --setenv PI_CODING_AGENT_DIR=/run/fabriek/pi --setenv PI_AGENT_DIR=/run/fabriek/pi --setenv PI_CODING_AGENT_SESSION_DIR=/root/.pi/sessions --setenv PI_OFFLINE=1 --bind-ro $STATE/bus/builder:/run/fabriek/bus-password --bind-ro $STATE/forge/builder-token:/run/fabriek/forge-token --setenv FABRIEK_BUS_PASSWORD=/run/fabriek/bus-password --setenv FABRIEK_FORGE_TOKEN=/run/fabriek/forge-token --setenv FABRIEK_ROLE=builder --setenv FABRIEK_CAPABILITIES=build,test --setenv FABRIEK_SPECIALISTS=java,python --setenv FABRIEK_BUS=10.77.0.1:6379 --setenv FABRIEK_FORGE=http://10.77.0.1:3000/api/v1 --setenv FABRIEK_REPOSITORY=operator/acme --setenv FABRIEK_BASE_BRANCH=main --setenv FABRIEK_PROXY=10.77.0.1:8118 --setenv FABRIEK_HOME_HOST=$STATE/homes/acme-builder builder $STATE/worktrees/acme/builder agent --print"
}

@test "a person entering a role forwards their agent and gets no cage key" {
	run_fabriek_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success

	run recorded
	assert_output "--uid 60000 --user builder --home $STATE/homes/acme-builder --network fabriek-acme:10.77.0.10/24 --no-nix-daemon --setenv NIXCAGE_PATH_PREFIX=$PROFILE/bin --auth-sock /tmp/agent.sock --bind-ro $FABRIEK_LIB/role-guidance.md:/etc/fabriek/role-guidance.md --setenv FABRIEK_ROLE_GUIDANCE=/etc/fabriek/role-guidance.md builder $STATE/worktrees/acme/builder"
}

@test "the uid comes from nixcage rather than from a store fabriek keeps" {
	run_fabriek_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success
	# Nothing under fabriek' own state records an allocation: the number
	# is nixcage's to hand out and never to reissue.
	run find "$STATE" -name "role-uids*"
	assert_output ""
}

@test "a role's worktree asks nixcage for its storage rather than running zfs" {
	# The primitive is what creates the directory in this test, so a
	# worktree that exists is proof it was asked for.
	run_fabriek_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success
	[ -d "$STATE/worktrees/acme/builder" ]
}

@test "the role's own identity is what the session's gitconfig says" {
	run_fabriek_container role-enter --repository "$REPO" \
		--task-dir "$TEST_TEMP_DIR/run" --signing-key builder \
		acme builder
	assert_success
	run cat "$STATE/keys/builder.gitconfig"
	assert_output --partial "email = builder@factory.invalid"
	assert_output --partial "signingKey = /run/fabriek/signing-key"
	assert_output --partial "allowedSignersFile = /run/fabriek/allowed_signers"
}

@test "an agent socket and a cage key are refused together" {
	run_fabriek_container role-enter \
		--auth-sock /tmp/agent.sock --signing-key builder acme builder
	assert_failure
	assert_output --partial "mutually exclusive"
}

@test "given no bridge plan on the machine, a session is refused rather than started off the bridge" {
	rm "$FABRIEK_ETC/bridge.json"
	run_fabriek_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_failure
	assert_output --partial "bridge"
	[ ! -f "$CALLS" ]
}

@test "a role the plan does not place gets no session, because it would have no address" {
	cat >"$FABRIEK_ETC/bridge.json" <<'JSON'
{ "bridge": "fabriek-acme", "host": "10.77.0.1", "prefix": 24, "cages": { "decider": "10.77.0.2" } }
JSON
	run_fabriek_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_failure
	assert_output --partial "builder"
	[ ! -f "$CALLS" ]
}

# ADR-035: a supervised run is an actor, so it is handed the loop (pi's
# configuration directory, with the extension and models.json in it), its two
# credentials as read-only files, and where the bus and the board are. A
# person entering by hand gets none of that: they are not an actor.
@test "a person entering by hand is handed no loop, no bus password and no forge token" {
	run_fabriek_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success
	run recorded
	refute_output --partial "PI_CODING_AGENT_DIR"
	refute_output --partial "bus-password"
	refute_output --partial "FABRIEK_ROLE="
}

# The declared command is what an actor runs (ADR-033); a person entering by
# hand is not one, and a hand that asks for a command gets that command.
# Found by tests/manual/isolation.sh, whose every question to a cage ran pi.
## An actor's cage holds the role's one veth and one address, and a second
## cage of that name would collide with it on both; a person entering the
## role while its actor runs joins the actor's network namespace instead
## (nixcage ADR-011 point 5). The cage's leader is the child of the nspawn
## whose argv names the machine, since a cage is not registered.
running_cage() {
	cat >"$STUB_DIR/pgrep" <<EOF
#!/usr/bin/env bash
case "\$*" in
*"--machine=$1( |\$)"*) echo 4242 ;;
"-P 4242") echo 4243 ;;
*) exit 1 ;;
esac
EOF
	chmod +x "$STUB_DIR/pgrep"
}

@test "a person entering a role whose actor is running joins its cage's network instead of taking a second veth" {
	running_cage builder
	run_fabriek_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success
	run recorded
	assert_output --partial "--network ns:/proc/4243/ns/net"
	refute_output --partial "--network fabriek-acme:"
	# nspawn keeps a directory under /run/systemd/nspawn per machine name
	# and refuses a second machine of one name, registered or not; found on
	# a machine ("Mount point ... exists already, refusing"). The hand's
	# cage carries its own name, which reaches no veth in this mode.
	assert_output --partial " builder-hand $STATE/worktrees/acme/builder"
}

@test "a supervised run takes the bridge placement whatever else is running under the role's name" {
	running_cage builder
	mkdir -p "$TEST_TEMP_DIR/run"
	run_fabriek_container role-enter --repository "$REPO" --task-dir "$TEST_TEMP_DIR/run" --signing-key builder acme builder
	assert_success
	run recorded
	assert_output --partial "--network fabriek-acme:10.77.0.10/24"
	refute_output --partial "ns:/proc"
}

@test "a person entering by hand with a command runs that command, not the declared one" {
	run_fabriek_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder ip -o link show
	assert_success
	run recorded
	assert_output --partial " builder $STATE/worktrees/acme/builder ip -o link show"
	refute_output --partial "agent --print"
}

@test "a person entering by hand with no command gets the cage's shell, not the declared command" {
	run_fabriek_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success
	run recorded
	refute_output --partial "agent --print"
}

@test "a supervised run without its credentials on the machine is refused rather than started deaf" {
	rm "$STATE/bus/builder"
	mkdir -p "$TEST_TEMP_DIR/run"
	run_fabriek_container role-enter --repository "$REPO" \
		--task-dir "$TEST_TEMP_DIR/run" --signing-key builder acme builder
	assert_failure
	assert_output --partial "bus password"
	[ ! -f "$CALLS" ]
}

# ADR-034 point 1: the decider is a cage like any other, provided by the
# machine rather than declared. Its session is composed the same way, with
# its own loop, a read-only token, the declaration and the policy bound in,
# and no capabilities, no profile and no branch to sign for.
@test "the decider's session is a role session with the machine's own loop and the policy bound in" {
	echo "Prefer finishing started work." >"$FABRIEK_ETC/decider-policy.md"
	run_fabriek_container role-enter --repository "$REPO" --signing-key decider acme decider
	assert_success
	run recorded
	assert_output --partial "--network fabriek-acme:10.77.0.2/24 --no-nix-daemon"
	assert_output --partial "--bind-ro $FABRIEK_ETC/pi-decider:/run/fabriek/pi --setenv PI_CODING_AGENT_DIR=/run/fabriek/pi --setenv PI_AGENT_DIR=/run/fabriek/pi --setenv PI_CODING_AGENT_SESSION_DIR=/root/.pi/sessions --setenv PI_OFFLINE=1"
	assert_output --partial "--bind-ro $STATE/forge/decider-token:/run/fabriek/forge-token"
	assert_output --partial "--bind-ro $FABRIEK_ETC/declaration.json:/run/fabriek/declaration.json --setenv FABRIEK_DECLARATION=/run/fabriek/declaration.json"
	assert_output --partial "--bind-ro $FABRIEK_ETC/decider-policy.md:/run/fabriek/policy.md --setenv FABRIEK_POLICY=/run/fabriek/policy.md"
	assert_output --partial "--setenv FABRIEK_ROLE=decider --setenv FABRIEK_CAPABILITIES= "
	assert_output --partial " decider $STATE/worktrees/acme/decider pi --mode rpc"
	refute_output --partial NIXCAGE_PATH_PREFIX
}

@test "without a policy file on the machine, the decider is started without one and told nothing" {
	run_fabriek_container role-enter --repository "$REPO" --signing-key decider acme decider
	assert_success
	run recorded
	refute_output --partial "FABRIEK_POLICY"
}

# ADR-040: the executor starts every session and names no origin; the one
# fabriek up filed is used until the clone exists and records its own.
@test "a session started without an origin takes the one up filed on the machine" {
	echo "file://$REPO" >"$STATE/origin"
	mkdir -p "$TEST_TEMP_DIR/run"
	run_fabriek_container role-enter --task-dir "$TEST_TEMP_DIR/run" --signing-key builder acme builder
	assert_success
	run recorded
	assert_output --partial " builder $STATE/worktrees/acme/builder agent --print"
}

@test "a session with no origin anywhere is refused and told to run up" {
	run_fabriek_container role-enter --signing-key builder acme builder
	assert_failure
	assert_output --partial "fabriek up"
}

# The loop, the models and who the role is all ride in that directory; a
# session started without it is an agent with no loop, which nobody can reach.
@test "a role whose build realised no pi directory is refused rather than started as nobody" {
	rm "$FABRIEK_ETC/roles/builder/pi"
	mkdir -p "$TEST_TEMP_DIR/run"
	run_fabriek_container role-enter --repository "$REPO" \
		--task-dir "$TEST_TEMP_DIR/run" --signing-key builder \
		acme builder
	assert_failure
	assert_output --partial "role builder has no pi directory"
}

@test "a role whose build realised no profile enters with the floor alone" {
	rm "$FABRIEK_ETC/roles/builder/profile"
	run_fabriek_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success
	run recorded
	refute_output --partial "NIXCAGE_PATH_PREFIX"
	assert_output --partial "--no-nix-daemon --auth-sock"
}


# --private-users-ownership=off means a host file has to already carry the uid
# the session runs as, and libgit2 refuses a repository owned by anyone else.
# Loop and agent are one uid now (ADR-035), and it is the principal's own.
@test "the worktree is owned by the uid that opens it" {
	run_fabriek_container role-worktree acme builder "$REPO"
	assert_success
	run cat "$STORAGE_CALLS"
	assert_output --partial "ensure $STATE/worktrees/acme/builder 60000"
}
