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
#   the role guidance   was bound read-only and named in the environment
#                                                -> nothing: it is in the role's
#                                                   system prompt (ADR-054)
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
	RUN="$TEST_TEMP_DIR/run-fabriek"
	export FABRIEK_RUN="$RUN"

	# The seam itself. 'enter', 'exec' and 'stop' are recorded; the others
	# answer so that role-enter gets far enough to emit one. No cage runs
	# unless a scenario says so (nixcage ADR-012: status, netns).
	RUNNING="$TEST_TEMP_DIR/running"
	cat >"$STUB_DIR/nixcage-container" <<EOF
#!/usr/bin/env bash
case "\$1" in
uid)
	# A principal's number. A subject is never asked for any more (ADR-035),
	# so asking for one is answered the way a machine with none would. The
	# principal is <factory>-<role> (ADR-067 point 3).
	if [ -n "\$3" ]; then echo "no such subject: \$3" >&2; exit 1; fi
	case "\$2" in acme-*) echo 60000 ;; *) echo "no such principal: \$2" >&2; exit 1 ;; esac
	;;
storage)
	printf '%s\n' "\$*" >>"$STORAGE_CALLS"
	mkdir -p "\$3"
	;;
status)
	if [ -f "$RUNNING/\$2" ]; then echo "running \$(cat "$RUNNING/\$2") machine.slice/machine-\$2.scope"; else echo stopped; fi
	;;
netns)
	if [ -f "$RUNNING/\$2" ]; then echo "/proc/\$(cat "$RUNNING/\$2")/ns/net"; else echo "nixcage: \$2 is not running" >&2; exit 1; fi
	;;
enter)
	shift
	printf '%s\n' "\$*" >>"$CALLS"
	;;
exec|stop)
	printf '%s\n' "\$*" >>"$CALLS"
	;;
esac
EOF
	mkdir -p "$RUNNING"
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
	# The decider's directory, rendered by prepare like a role's.
	mkdir -p "$TEST_TEMP_DIR/store/pi-decider/extensions"
	ln -s "$TEST_TEMP_DIR/store/pi-decider" "$FABRIEK_ETC/pi-decider"
	DECIDER_DIR="$(readlink -f "$TEST_TEMP_DIR/store/pi-decider")"
	# The floor the image carries (ADR-057): what a pi directory's index
	# files import, so it is the root a session is handed (nixcage ADR-014).
	export FABRIEK_FLOOR="$TEST_TEMP_DIR/store/floor"
	mkdir -p "$FABRIEK_FLOOR"
	cat >"$FABRIEK_ETC/bridge.json" <<'JSON'
{ "bridge": "fb-0", "host": "10.77.0.1", "prefix": 24,
  "cages": { "builder": "10.77.0.10", "decider": "10.77.0.2" },
  "proxy": "10.77.0.1:8118", "forgejo": "10.77.0.1:3000", "bus": "10.77.0.1:4222" }
JSON
	cat >"$FABRIEK_ETC/declaration.json" <<'JSON'
{ "name": "acme", "roles": { "builder": { "command": ["agent", "--print"], "provides": ["build", "test"], "shell": "backend", "specialists": ["java", "python"] } },
  "resources": { "memory": "8G", "cores": 4, "concurrency": 2 } }
JSON
	# What prepare made for the role: its bus password and its forge token.
	mkdir -p "$STATE/bus" "$STATE/forge"
	# Where a session starts (ADR-029 point 6): the build's answer, read
	# onto pi's argv because pi cannot read a settings file it cannot lock.
	echo '{ "provider": "anthropic", "model": "claude-opus-5" }' >"$FABRIEK_ETC/model.json"
	echo pass >"$STATE/bus/builder"
	echo tok >"$STATE/forge/builder-token"
	echo pass >"$STATE/bus/decider"
	echo tok >"$STATE/forge/decider-token"
}

teardown() {
	teardown_temp_dir
}

# A repository that declares the factory working it (ADR-020, ADR-058),
# naming one role with a toolchain and a command of its own -- the case that
# exercises every flag. The declaration is committed, because that is what
# is read.
declare_factory() {
	REPO="$TEST_TEMP_DIR/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init --quiet -b main
	git -C "$REPO" config user.email test@example.invalid
	git -C "$REPO" config user.name test
	cat >"$REPO/fabriek.toml" <<'EOF'
name = "acme"

[roles.builder]
command = ["agent", "--print"]
provides = ["build"]
shell = "backend"
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
	assert_output "--uid 60000 --user builder --home $STATE/homes/acme-builder --network fb-0:10.77.0.10/24 --no-nix-daemon --substrate nspawn --memory 4096M --cpus 2 --setenv NIXCAGE_PATH_PREFIX=$PROFILE/bin --store-root $PROFILE --no-agent --bind $TEST_TEMP_DIR/run:/run/fabriek/task --setenv FABRIEK_TASK=/run/fabriek/task --bind-ro $STATE/keys/builder:/run/fabriek/signing-key --bind-ro $STATE/keys/allowed_signers:/run/fabriek/allowed_signers --bind-ro $STATE/keys/builder.gitconfig:/etc/gitconfig --bind $RUN/pi-builder:/run/fabriek/pi --bind-ro $PIDIR/extensions:/run/fabriek/pi/extensions --store-root $FABRIEK_FLOOR --setenv PI_CODING_AGENT_DIR=/run/fabriek/pi --setenv PI_AGENT_DIR=/run/fabriek/pi --setenv PI_CODING_AGENT_SESSION_DIR=~/.pi/sessions --setenv PI_OFFLINE=1 --bind-ro $STATE/bus/builder:/run/fabriek/bus-password --bind-ro $STATE/forge/builder-token:/run/fabriek/forge-token --setenv FABRIEK_BUS_PASSWORD=/run/fabriek/bus-password --setenv FABRIEK_FORGE_TOKEN=/run/fabriek/forge-token --setenv FABRIEK_ROLE=builder --setenv FABRIEK_CAPABILITIES=build,test --setenv FABRIEK_SPECIALISTS=java,python --setenv FABRIEK_BUS=10.77.0.1:4222 --setenv FABRIEK_FORGE=http://10.77.0.1:3000/api/v1 --setenv FABRIEK_REPOSITORY=acme-operator/acme --setenv FABRIEK_BASE_BRANCH=main --setenv FABRIEK_PROXY=10.77.0.1:8118 --setenv FABRIEK_HOME_HOST=$STATE/homes/acme-builder acme-builder $STATE/worktrees/acme/builder agent --print"
}

@test "a person entering a role forwards their agent and gets no cage key" {
	run_fabriek_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success

	run recorded
	assert_output "--uid 60000 --user builder --home $STATE/homes/acme-builder --network fb-0:10.77.0.10/24 --no-nix-daemon --substrate nspawn --setenv NIXCAGE_PATH_PREFIX=$PROFILE/bin --store-root $PROFILE --auth-sock /tmp/agent.sock acme-builder $STATE/worktrees/acme/builder"
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
{ "bridge": "fb-0", "host": "10.77.0.1", "prefix": 24, "cages": { "decider": "10.77.0.2" } }
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
## An actor's cage is where its work is; a person entering the role while
## its actor runs is put inside that cage rather than beside it (nixcage
## ADR-012 point 4), which nixcage answers for from the cage's scope.
running_cage() {
	echo 4243 >"$RUNNING/acme-$1"
}

@test "a person entering a role whose actor is running is put inside that cage, not beside it" {
	running_cage builder
	run_fabriek_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder
	assert_success
	run recorded
	assert_output "exec acme-builder"
}

@test "a person entering a running role with a command runs it inside the cage" {
	running_cage builder
	run_fabriek_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder git status
	assert_success
	run recorded
	assert_output "exec acme-builder -- git status"
}

@test "asked for a plan, the guest prints the same line NUL-separated and enters nothing (ADR-070)" {
	mkdir -p "$TEST_TEMP_DIR/run"
	run_fabriek_container role-enter --repository "$REPO" --task-dir "$TEST_TEMP_DIR/run" --signing-key builder acme builder
	assert_success
	local entered
	entered="enter $(recorded)"
	rm "$CALLS"
	"$FABRIEK_ROOT/fabriek-container" role-enter --plan --repository "$REPO" \
		--task-dir "$TEST_TEMP_DIR/run" --signing-key builder acme builder >"$TEST_TEMP_DIR/plan"
	[ ! -f "$CALLS" ]
	run bash -c "tr '\\0' ' ' <'$TEST_TEMP_DIR/plan'"
	assert_output "$entered "
}

@test "asked for a plan beside a running actor, the guest plans the exec" {
	running_cage builder
	"$FABRIEK_ROOT/fabriek-container" role-enter --plan --repository "$REPO" acme builder git log >"$TEST_TEMP_DIR/plan"
	[ ! -f "$CALLS" ]
	run bash -c "tr '\\0' '|' <'$TEST_TEMP_DIR/plan'"
	assert_output "exec|acme-builder|--|git|log|"
}

@test "a supervised run takes the bridge placement whatever else is running under the role's name" {
	running_cage builder
	mkdir -p "$TEST_TEMP_DIR/run"
	run_fabriek_container role-enter --repository "$REPO" --task-dir "$TEST_TEMP_DIR/run" --signing-key builder acme builder
	assert_success
	run recorded
	assert_output --partial "--network fb-0:10.77.0.10/24"
	refute_output --partial "ns:/proc"
	refute_output --partial "exec"
}

@test "a person entering by hand with a command runs that command, not the declared one" {
	run_fabriek_container role-enter --repository "$REPO" --auth-sock /tmp/agent.sock acme builder ip -o link show
	assert_success
	run recorded
	assert_output --partial " acme-builder $STATE/worktrees/acme/builder ip -o link show"
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
	assert_output --partial "--network fb-0:10.77.0.2/24 --no-nix-daemon --substrate nspawn"
	assert_output --partial "--bind $RUN/pi-decider:/run/fabriek/pi --bind-ro $DECIDER_DIR/extensions:/run/fabriek/pi/extensions --store-root $FABRIEK_FLOOR --setenv PI_CODING_AGENT_DIR=/run/fabriek/pi --setenv PI_AGENT_DIR=/run/fabriek/pi --setenv PI_CODING_AGENT_SESSION_DIR=~/.pi/sessions --setenv PI_OFFLINE=1"
	assert_output --partial "--bind-ro $STATE/forge/decider-token:/run/fabriek/forge-token"
	assert_output --partial "--bind-ro $FABRIEK_ETC/declaration.json:/run/fabriek/declaration.json --setenv FABRIEK_DECLARATION=/run/fabriek/declaration.json"
	assert_output --partial "--bind-ro $FABRIEK_ETC/decider-policy.md:/run/fabriek/policy.md --setenv FABRIEK_POLICY=/run/fabriek/policy.md"
	assert_output --partial "--setenv FABRIEK_ROLE=decider --setenv FABRIEK_CAPABILITIES= "
	assert_output --partial " acme-decider $STATE/worktrees/acme/decider pi --mode rpc --provider anthropic --model claude-opus-5 --no-approve"
	refute_output --partial NIXCAGE_PATH_PREFIX
}

# pi 0.84 locks settings.json to read it, and the pi directory is bound
# read-only, so the settings a session needs with nobody at the keyboard
# (the model to start on, and never to trust the project's own .pi) ride
# on its argv, from the answer the build wrote. A declared command is the
# repository's word for word and gets nothing appended.
@test "a role that declares no command runs pi on the build's model and trusts no project settings" {
	cat >"$FABRIEK_ETC/declaration.json" <<'JSON'
{ "name": "acme", "roles": { "builder": { "provides": ["build", "test"], "shell": "backend" } },
  "resources": { "memory": "8G", "cores": 4, "concurrency": 2 } }
JSON
	run_fabriek_container role-enter --repository "$REPO" --signing-key builder acme builder
	assert_success
	run recorded
	assert_output --partial " acme-builder $STATE/worktrees/acme/builder pi --mode rpc --provider anthropic --model claude-opus-5 --no-approve"
}

# pi 0.84 locks settings.json, auth.json and models-store.json to read them,
# and the lock is a directory beside each, so the directory pi is handed
# has to be writable. What the build put there stays the build's: each
# entry is bound read-only over a scratch directory made fresh for the
# session and owned by the role, so a lock lands and nothing outlives the
# session.
@test "the pi directory is scratch for the session with every file of the build's bound read-only over it" {
	mkdir -p "$TEST_TEMP_DIR/store/pi-builder/skills"
	echo '{}' >"$TEST_TEMP_DIR/store/pi-builder/models.json"
	echo 'leftover' >"$RUN/pi-builder/auth.json" 2>/dev/null || { mkdir -p "$RUN/pi-builder"; echo leftover >"$RUN/pi-builder/auth.json"; }
	run_fabriek_container role-enter --repository "$REPO" --signing-key builder acme builder
	assert_success
	run recorded
	assert_output --partial "--bind $RUN/pi-builder:/run/fabriek/pi --bind-ro $PIDIR/extensions:/run/fabriek/pi/extensions --bind-ro $PIDIR/models.json:/run/fabriek/pi/models.json --bind-ro $PIDIR/skills:/run/fabriek/pi/skills --store-root $FABRIEK_FLOOR --setenv PI_CODING_AGENT_DIR=/run/fabriek/pi"
	[ -d "$RUN/pi-builder" ]
	[ ! -e "$RUN/pi-builder/auth.json" ]
}

@test "a machine whose build wrote no model is refused a supervised session rather than starting pi on none" {
	rm "$FABRIEK_ETC/model.json"
	run_fabriek_container role-enter --repository "$REPO" --signing-key decider acme decider
	assert_failure
	assert_output --partial "model.json"
	[ ! -f "$CALLS" ]
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
	assert_output --partial " acme-builder $STATE/worktrees/acme/builder agent --print"
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
	refute_output --partial "--store-root"
	assert_output --partial "--no-nix-daemon --substrate nspawn --auth-sock"
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

# ADR-054: the guidance is in the role's system prompt, built into its pi
# directory; the session binds nothing for it and names nothing.
@test "a role session binds no guidance file and sets no variable for it" {
	run_fabriek_container role-enter --repository "$REPO" --signing-key builder acme builder
	assert_success
	run recorded
	refute_output --partial "role-guidance"
	refute_output --partial "FABRIEK_ROLE_GUIDANCE"
}

# ADR-067 point 4: a role that asks for a kernel of its own is composed the
# same way, one flag apart, which nixcage takes to its microVM substrate
# (nixcage ADR-019). Everything else on the line is the same.
@test "a role declared microvm reaches nixcage-container with --substrate microvm and nothing else changed" {
	jq '.roles.builder.substrate = "microvm"' "$FABRIEK_ETC/declaration.json" >"$FABRIEK_ETC/d.new" && mv "$FABRIEK_ETC/d.new" "$FABRIEK_ETC/declaration.json"
	mkdir -p "$TEST_TEMP_DIR/run"
	run_fabriek_container role-enter --repository "$REPO" --task-dir "$TEST_TEMP_DIR/run" --signing-key builder acme builder
	assert_success
	run recorded
	assert_output --partial "--network fb-0:10.77.0.10/24 --no-nix-daemon --substrate microvm --memory 4096M"
}

# Where pi keeps a role's sessions is the role's home, which nixcage binds
# at /root on nspawn and at /home/nixcage on microvm (nixcage ADR-019
# decision 5). A fixed /root put a microvm role's sessions where it may not
# write (seen 2026-09-22: EACCES on /root/.pi/sessions); pi expands ~ from
# HOME, which nixcage sets to wherever the home is.
@test "a role's sessions are kept under its home wherever the substrate binds it" {
	mkdir -p "$TEST_TEMP_DIR/run"
	run_fabriek_container role-enter --repository "$REPO" \
		--task-dir "$TEST_TEMP_DIR/run" --signing-key builder acme builder
	assert_success
	run recorded
	assert_output --partial "--setenv PI_CODING_AGENT_SESSION_DIR=~/.pi/sessions"
	refute_output --partial "/root/.pi/sessions"
}
