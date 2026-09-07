#!/usr/bin/env bats
# Building and booting one factory's machine (ADR-019).
#
# The builder and ssh are stubbed; evaluation is not. A repository really
# declares a factory and the operator's config is really TOML, because those
# are read rather than built and stubbing them would test the stub.

load ../test_helper/common

setup() {
	setup_temp_dir
	export CAGEWORKS_MACHINES="$TEST_TEMP_DIR/machines"
	export CAGEWORKS_SELF="$CAGEWORKS_ROOT"

	STUB_DIR="$TEST_TEMP_DIR/bin"
	mkdir -p "$STUB_DIR"
	PATH="$STUB_DIR:$PATH"
	export PATH

	BUILD_CALLS="$TEST_TEMP_DIR/build-calls"
	SSH_CALLS="$TEST_TEMP_DIR/ssh-calls"
	RUNNER="$TEST_TEMP_DIR/runner"
	mkdir -p "$RUNNER/bin"

	# A runner that stays up until it is asked to stop, which is what a machine
	# does and all this needs to be.
	cat >"$RUNNER/bin/microvm-run" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while true; do sleep 0.2; done
EOF
	chmod +x "$RUNNER/bin/microvm-run"

	# The builder. Records the spec it was given, because what cageworks asks
	# for is the thing worth asserting on.
	cat >"$STUB_DIR/cw-nix-build" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$CAGEWORKS_MACHINE_SPEC" >>"$BUILD_CALLS"
echo "$RUNNER"
EOF
	chmod +x "$STUB_DIR/cw-nix-build"
	export CAGEWORKS_NIX_BUILD="$STUB_DIR/cw-nix-build"

	cat >"$STUB_DIR/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SSH_CALLS"
[ -f "$TEST_TEMP_DIR/refuse-shutdown" ] && exit 1
# A guest that accepts a shutdown stops the machine that is running it.
if [ -f "$CAGEWORKS_MACHINES/acme/pid" ]; then
	kill "\$(cat "$CAGEWORKS_MACHINES/acme/pid")" 2>/dev/null || true
fi
exit 0
EOF
	chmod +x "$STUB_DIR/ssh"

	declare_repository
	write_operator_config
}

teardown() {
	if [ -f "$CAGEWORKS_MACHINES/acme/pid" ]; then
		kill "$(cat "$CAGEWORKS_MACHINES/acme/pid")" 2>/dev/null || true
	fi
	teardown_temp_dir
}

## A repository that declares the factory working it, committed, because that
## is what is read (ADR-020).
declare_repository() {
	REPO="$TEST_TEMP_DIR/acme"
	mkdir -p "$REPO"
	git init -q "$REPO"
	git -C "$REPO" config user.name factory
	git -C "$REPO" config user.email factory@invalid
	cat >"$REPO/flake.nix" <<'EOF'
{
  outputs = { self }: {
    cageworks = {
      name = "acme";
      roles.builder = {
        command = [ "claude" ];
        provides = [ "build" ];
      };
      resources = {
        memory = "4G";
        cores = 2;
        egress = [ "api.anthropic.com" "api.openai.com" ];
      };
    };
  };
}
EOF
	git -C "$REPO" add -A
	git -C "$REPO" -c commit.gpgsign=false commit -qm declare
}

write_operator_config() {
	cat >"$CAGEWORKS_CONFIG" <<EOF
[caps]
memory = "16G"
cores = 8
egress = ["api.anthropic.com"]

[factories.acme]
path = "$REPO"
EOF
}

@test "a factory nobody registered here has no machine to start" {
	run_cageworks up ghost
	assert_failure
	assert_output --partial "ghost"
}

@test "up with no factory named explains itself" {
	run_cageworks up
	assert_failure
	assert_output --partial "usage"
}

@test "starting a factory builds its machine and leaves it running" {
	run_cageworks up acme
	assert_success
	assert_output --partial "running"
	[ -f "$CAGEWORKS_MACHINES/acme/pid" ]
	kill -0 "$(cat "$CAGEWORKS_MACHINES/acme/pid")"
}

# What cageworks asks for is the machine the declaration describes, met by the
# ceilings this host allows, with the way in that belongs to this factory.
@test "the machine asked for is the one the repository declared" {
	run_cageworks up acme
	assert_success

	run jq -r '.factory, .cpus, .mem, .system, .hostSystem' "$BUILD_CALLS"
	assert_line --index 0 "acme"
	assert_line --index 1 "2"
	assert_line --index 2 "4096"
	# The guest is Linux whatever the operator is on, and the runner that
	# starts it is built for the operator's own host.
	assert_line --index 3 --regexp '^(aarch64|x86_64)-linux$'
	assert_line --index 4 --regexp '^(aarch64|x86_64)-(linux|darwin)$'
}

@test "the machine is told the one key that reaches it, and its own port" {
	run_cageworks up acme
	assert_success

	local port key
	port="$(cat "$CAGEWORKS_MACHINES/acme/port")"
	key="$(cat "$CAGEWORKS_MACHINES/acme/id_ed25519.pub")"
	run jq -r '.sshPort, .authorizedKey' "$BUILD_CALLS"
	assert_line --index 0 "$port"
	assert_line --index 1 "$key"
}

@test "starting a machine that is already running builds nothing" {
	run_cageworks up acme
	assert_success
	run_cageworks up acme
	assert_success
	assert_output --partial "already running"

	run wc -l <"$BUILD_CALLS"
	assert_output --regexp '^ *1$'
}

@test "stopping a machine that is not running is not an error" {
	run_cageworks down acme
	assert_success
	assert_output --partial "not running"
}

# ADR-017 exists because a VM was ended rather than shut down. cageworks owns
# the stopping now, so it asks the guest and waits rather than killing it.
@test "stopping asks the guest to shut down, and waits for it" {
	run_cageworks up acme
	assert_success
	local pid
	pid="$(cat "$CAGEWORKS_MACHINES/acme/pid")"

	run_cageworks down acme
	assert_success
	assert_output --partial "stopped"

	run cat "$SSH_CALLS"
	assert_output --partial "systemctl poweroff"
	run kill -0 "$pid"
	assert_failure
	[ ! -f "$CAGEWORKS_MACHINES/acme/pid" ]
}

# A stop that cannot complete is reported and the machine keeps running. There
# is no path here that ends one anyway.
@test "a guest that will not shut down is reported, and is left running" {
	run_cageworks up acme
	assert_success
	local pid
	pid="$(cat "$CAGEWORKS_MACHINES/acme/pid")"
	: >"$TEST_TEMP_DIR/refuse-shutdown"

	run_cageworks down acme
	assert_failure
	assert_output --partial "still running"
	kill -0 "$pid"
}

@test "a running machine says so, and one that has stopped says that" {
	run_cageworks up acme
	assert_success
	run_cageworks vm status
	assert_success
	assert_output --partial "running"

	run_cageworks down acme
	assert_success
	run_cageworks vm status
	assert_success
	assert_output --partial "stopped"
	refute_output --partial "running"
}

# ADR-025: where a factory's agents may reach is declared by the repository and
# allowed by the operator, and the machine is built to the result. The
# declaration asks for two endpoints and this host allows one.
@test "the machine is built to reach what the operator allowed, not what the repository asked" {
	run_cageworks up acme
	assert_success

	run jq -c '.egress' "$BUILD_CALLS"
	assert_output '["api.anthropic.com"]'
}

@test "dropping an endpoint is said where the operator will see it" {
	run_cageworks up acme
	assert_success
	assert_output --partial "api.openai.com"
}
