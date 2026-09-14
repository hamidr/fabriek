#!/usr/bin/env bats
# Building and booting one factory's machine (ADR-019).
#
# nix and ssh are stubbed; the operator's config is not. What fabriek hands
# nix is a generated flake and a file of local facts (ADR-040), and those are
# what is asserted on; what the build makes of them is machine_spec.bats'.

load ../test_helper/common

setup() {
	setup_temp_dir
	export FABRIEK_MACHINES="$TEST_TEMP_DIR/machines"
	export FABRIEK_SELF="$FABRIEK_ROOT"

	STUB_DIR="$TEST_TEMP_DIR/bin"
	mkdir -p "$STUB_DIR"
	PATH="$STUB_DIR:$PATH"
	export PATH

	NIX_CALLS="$TEST_TEMP_DIR/nix-calls"
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

	# nix. Records every call, answers a build with the runner, a lock or an
	# update by writing the lock file, and an eval with the spec a build would
	# have produced for this factory: enough for the CLI to file a credential
	# and to say what the clamp changed.
	cat >"$STUB_DIR/cw-nix" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$NIX_CALLS"
case "\$1 \$2" in
"build "*) echo "$RUNNER" ;;
"flake lock") dir="\${3#path:}"; echo '{"stub":true}' >"\$dir/flake.lock" ;;
"flake update") dir="\${5#path:}"; echo "{\"stub\":\"\$3\"}" >"\$dir/flake.lock" ;;
"eval "*)
	if grep -q credentials "$FABRIEK_MACHINES/acme/machine/local.json" && jq -e '.credentials["api.anthropic.com"]' "$FABRIEK_MACHINES/acme/machine/local.json" >/dev/null; then
		echo '{"factory":"acme","egress":["api.anthropic.com"],"egressHeaders":{"api.anthropic.com":"x-api-key"},"notes":["fabriek: acme: egress: dropped api.openai.com, which the operator has not allowed"]}'
	else
		echo '{"factory":"acme","egress":["api.anthropic.com"],"egressHeaders":{},"notes":[]}'
	fi
	;;
esac
EOF
	chmod +x "$STUB_DIR/cw-nix"
	export FABRIEK_NIX="$STUB_DIR/cw-nix"

		cat >"$STUB_DIR/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SSH_CALLS"
# What arrives on stdin is the interesting half of giving a machine a
# credential, and it is not in the arguments by design.
if printf '%s' "\$*" | grep -q 'fabriek-egress-credential'; then
	cat >>"$TEST_TEMP_DIR/ssh-stdin"
fi
# A machine verb arrives NUL-separated on stdin for xargs; kept as words.
if printf '%s' "\$*" | grep -q 'xargs -0 fabriek-container'; then
	tr '\0' ' ' >>"$TEST_TEMP_DIR/machine-verbs"
	echo >>"$TEST_TEMP_DIR/machine-verbs"
fi
[ -f "$TEST_TEMP_DIR/refuse-shutdown" ] && exit 1
# Only a shutdown stops the machine. Every other command is one run on a
# machine that stays up.
if printf '%s' "\$*" | grep -q poweroff; then
	if [ -f "$FABRIEK_MACHINES/acme/pid" ]; then
		kill "\$(cat "$FABRIEK_MACHINES/acme/pid")" 2>/dev/null || true
	fi
fi
exit 0
EOF
	chmod +x "$STUB_DIR/ssh"

	declare_repository
	write_operator_config
}

teardown() {
	if [ -f "$FABRIEK_MACHINES/acme/pid" ]; then
		kill "$(cat "$FABRIEK_MACHINES/acme/pid")" 2>/dev/null || true
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
    fabriek = {
      name = "acme";
      roles.builder = {
        command = [ "claude" ];
        provides = [ "build" ];
      };
      resources = {
        memory = "4G";
        cores = 2;
        recordQuota = "2G";
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
	cat >"$FABRIEK_CONFIG" <<EOF
[caps]
memory = "16G"
cores = 8
egress = ["api.anthropic.com"]

[credentials."api.anthropic.com"]
header = "x-api-key"
file = "$TEST_TEMP_DIR/anthropic.key"

[factories.acme]
path = "$REPO"
EOF
	printf 'sk-secret-value' >"$TEST_TEMP_DIR/anthropic.key"
}

@test "a factory nobody registered here has no machine to start" {
	run_fabriek up ghost
	assert_failure
	assert_output --partial "ghost"
}

@test "up with no factory named explains itself" {
	run_fabriek up
	assert_failure
	assert_output --partial "usage"
}

@test "starting a factory builds its machine and leaves it running" {
	run_fabriek up acme
	assert_success
	assert_output --partial "running"
	[ -f "$FABRIEK_MACHINES/acme/pid" ]
	kill -0 "$(cat "$FABRIEK_MACHINES/acme/pid")"
}

# What fabriek hands the build is a flake naming the repository and a file
# of the facts only this host knows (ADR-040). The build composes the rest,
# and machine_spec.bats asserts on that.
@test "given a registered factory, up writes a machine flake whose project input is that repository" {
	run_fabriek up acme
	assert_success
	local flake="$FABRIEK_MACHINES/acme/machine/flake.nix"
	[ -f "$flake" ]
	run grep -c "project.url = \"git+file://$REPO\"" "$flake"
	assert_output 1
	run grep -c "fabriek.url = \"path:$FABRIEK_ROOT\"" "$flake"
	assert_output 1
}

@test "the build is given the local facts: the way in, both systems, the ceilings and the credential headers" {
	run_fabriek up acme
	assert_success
	local local_file="$FABRIEK_MACHINES/acme/machine/local.json"
	run jq -r '.factory, .sshPort, .authorizedKey, .system, .hostSystem' "$local_file"
	assert_line --index 0 acme
	assert_line --index 1 "$(cat "$FABRIEK_MACHINES/acme/port")"
	assert_line --index 2 "$(cat "$FABRIEK_MACHINES/acme/id_ed25519.pub")"
	# The machine is Linux whatever the operator is on, and the runner that
	# starts it is built for the operator's own host.
	assert_line --index 3 --regexp '^(aarch64|x86_64)-linux$'
	assert_line --index 4 --regexp '^(aarch64|x86_64)-(linux|darwin)$'
	run jq -c '.caps, .credentials' "$local_file"
	assert_line --index 0 '{"cores":8,"egress":["api.anthropic.com"],"memory":"16G"}'
	assert_line --index 1 '{"api.anthropic.com":"x-api-key"}'
	run grep -c "sk-secret-value" "$local_file"
	assert_output 0
}

# A build that fails prints a trace with the thrown message at its end,
# which is the one line the operator can act on (task 5).
@test "when the build fails, the thrown message is printed first and the trace after it" {
	cat >"$STUB_DIR/cw-nix" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
"build "*)
	cat >&2 <<'TRACE'
error:
       ... while evaluating the attribute 'config'
         at /nix/store/xxx-source/modules/factory.nix:150:3:
       ... while calling 'compose'
       error: role backend names specialist rust, which no catalogue declares; the catalogue offers: architect, developer
TRACE
	exit 1
	;;
"flake lock") dir="\${3#path:}"; echo '{"stub":true}' >"\$dir/flake.lock" ;;
"flake update") dir="\${5#path:}"; echo "{\"stub\":\"\$3\"}" >"\$dir/flake.lock" ;;
esac
EOF
	chmod +x "$STUB_DIR/cw-nix"
	run_fabriek up acme
	assert_failure
	assert_line --index 1 --partial "role backend names specialist rust"
	assert_output --partial "while calling 'compose'"
	refute_line --index 1 --partial "while evaluating"
}

@test "up builds the runner from the machine flake and keeps the spec the build produced" {
	run_fabriek up acme
	assert_success
	run grep -c "^build --no-link --print-out-paths path:$FABRIEK_MACHINES/acme/machine#runner$" "$NIX_CALLS"
	assert_output 1
	run jq -r '.factory' "$FABRIEK_MACHINES/acme/spec.json"
	assert_output acme
}

@test "what the build clamped is said where the operator will see it" {
	run_fabriek up acme
	assert_success
	assert_output --partial "api.openai.com"
}

@test "the first up locks the flake; a second keeps the lock; --update refreshes the project" {
	run_fabriek up acme
	assert_success
	run grep -c "^flake lock path:$FABRIEK_MACHINES/acme/machine$" "$NIX_CALLS"
	assert_output 1
	run_fabriek down acme
	run_fabriek up acme
	assert_success
	run grep -c "^flake lock " "$NIX_CALLS"
	assert_output 1
	run grep -c "^flake update project " "$NIX_CALLS"
	assert_output 0
	run_fabriek down acme
	run_fabriek up acme --update
	assert_success
	run grep -c "^flake update project --flake path:$FABRIEK_MACHINES/acme/machine$" "$NIX_CALLS"
	assert_output 1
}

@test "once the machine answers and holds its credential, up prepares the factory on it" {
	run_fabriek up acme
	assert_success
	run cat "$TEST_TEMP_DIR/machine-verbs"
	assert_output --partial "factory-prepare acme"
	# After the credential, because the forge and the bus are up by then and
	# a prepare that ran first would be a prepare against nothing.
	run bash -c "grep -n 'fabriek-egress-credential \|xargs -0 fabriek-container' '$SSH_CALLS' | head -2"
	assert_line --index 0 --partial "egress-credential"
	assert_line --index 1 --partial "xargs -0 fabriek-container"
}

@test "every up points the fabriek input at the fabriek that is running" {
	run_fabriek up acme
	assert_success
	run grep -c "^flake update fabriek --flake path:$FABRIEK_MACHINES/acme/machine$" "$NIX_CALLS"
	assert_output 1
}

@test "starting a machine that is already running builds nothing" {
	run_fabriek up acme
	assert_success
	run_fabriek up acme
	assert_success
	assert_output --partial "already running"

	run grep -c "^build " "$NIX_CALLS"
	assert_output 1
}

@test "stopping a machine that is not running is not an error" {
	run_fabriek down acme
	assert_success
	assert_output --partial "not running"
}

# ADR-017 exists because a VM was ended rather than shut down. fabriek owns
# the stopping now, so it asks the machine and waits rather than killing it.
@test "stopping asks the machine to shut down, and waits for it" {
	run_fabriek up acme
	assert_success
	local pid
	pid="$(cat "$FABRIEK_MACHINES/acme/pid")"

	run_fabriek down acme
	assert_success
	assert_output --partial "stopped"

	run cat "$SSH_CALLS"
	assert_output --partial "systemctl poweroff"
	run kill -0 "$pid"
	assert_failure
	[ ! -f "$FABRIEK_MACHINES/acme/pid" ]
}

# A stop that cannot complete is reported and the machine keeps running. There
# is no path here that ends one anyway.
@test "a machine that will not shut down is reported, and is left running" {
	run_fabriek up acme
	assert_success
	local pid
	pid="$(cat "$FABRIEK_MACHINES/acme/pid")"
	: >"$TEST_TEMP_DIR/refuse-shutdown"

	run_fabriek down acme
	assert_failure
	assert_output --partial "still running"
	kill -0 "$pid"
}

@test "a running machine says so, and one that has stopped says that" {
	run_fabriek up acme
	assert_success
	run_fabriek vm status
	assert_success
	assert_output --partial "running"

	run_fabriek down acme
	assert_success
	run_fabriek vm status
	assert_success
	assert_output --partial "stopped"
	refute_output --partial "running"
}

# ADR-025: where a factory's agents may reach is declared by the repository and
# allowed by the operator, and the machine is built to the result. The
# declaration asks for two endpoints and this host allows one.
@test "the credential goes to the machine on stdin, never as an argument" {
	run_fabriek up acme
	assert_success

	run cat "$TEST_TEMP_DIR/ssh-stdin"
	assert_output "sk-secret-value"

	# /proc is readable by everything on a machine, so a secret that was an
	# argument would be a secret every uid there had.
	run cat "$SSH_CALLS"
	refute_output --partial "sk-secret-value"
}

@test "a credential the operator says is somewhere it is not stops the machine being trusted with it" {
	rm -f "$TEST_TEMP_DIR/anthropic.key"
	run_fabriek up acme
	assert_failure
	assert_output --partial "anthropic.key"
}

@test "an endpoint nobody holds a credential for asks the machine for nothing" {
	cat >"$FABRIEK_CONFIG" <<EOF
[caps]
memory = "16G"
cores = 8
egress = ["api.anthropic.com"]

[factories.acme]
path = "$REPO"
EOF
	run_fabriek up acme
	assert_success
	run jq -c '.egressHeaders' "$FABRIEK_MACHINES/acme/spec.json"
	assert_output '{}'
	[ ! -f "$TEST_TEMP_DIR/ssh-stdin" ]
}

# ADR-018. Where a credential lands is the machine's business. The operator
# names a host and pipes a secret, and nothing on this side knows the layout of
# the state directory nixcage owns.
@test "the machine is asked to file a credential, not told where it keeps one" {
	run_fabriek up acme
	assert_success

	run cat "$SSH_CALLS"
	assert_output --partial "fabriek-egress-credential api.anthropic.com"
	refute_output --partial "/var/lib/nixcage"
	refute_output --partial "install -m 0400"
}

# ADR-027 point 8. The ledger is bounded by what the factory declared and the
# operator allowed, converted here for the same reason memory is: a person
# writes a size and the thing on the far side counts MiB.
