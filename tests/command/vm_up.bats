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

	# nix. Records every call, answers a build of the appliance with the
	# runner, and knows every store path the machine names as one this host
	# holds; everything else (the TOML reader, the declaration's schema) is
	# the real nix, since up reads the declaration at the pin itself now.
	REAL_NIX="$(command -v nix)"
	cat >"$STUB_DIR/cw-nix" <<EOF
#!/usr/bin/env bash
case "\$1" in
build) printf '%s\n' "\$*" >>"$NIX_CALLS"; [ "\$2" = --out-link ] && ln -sfn "$RUNNER" "\$3"; echo "$RUNNER" ;;
path-info) exit 0 ;;
# A git catalogue's prefetch (ADR-062): answered as nix would, with the
# tree the test laid down under \$TEST_TEMP_DIR/fetched and its hash.
flake) printf '%s\n' "\$*" >>"$NIX_CALLS"; printf '{"storePath":"%s","hash":"sha256-IVj69VsrFsewKTLrwoGX9qIjVe6heqBwirkYoGlEbx4="}\n' "$TEST_TEMP_DIR/fetched" ;;
*) exec "$REAL_NIX" "\$@" ;;
esac
EOF
	cat >"$STUB_DIR/nix-store" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TEST_TEMP_DIR/nix-store-calls"
EOF
	chmod +x "$STUB_DIR/cw-nix" "$STUB_DIR/nix-store"
	export FABRIEK_NIX="$STUB_DIR/cw-nix"

		cat >"$STUB_DIR/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SSH_CALLS"
# What arrives on stdin is the interesting half of giving a machine a
# credential, and it is not in the arguments by design.
# The verb and then a host; not the unit of a similar name, whose restart
# carries no stdin and would hang a cat on it.
if printf '%s' "\$*" | grep -qE ' fabriek-egress-credential [a-z0-9.-]+\$'; then
	cat >>"$TEST_TEMP_DIR/ssh-stdin"
fi
# A machine verb arrives NUL-separated on stdin for xargs; kept as words,
# and answered as the machine would: render says what the clamp changed,
# endpoints names what the rendered factory reaches, profiles what render
# built.
if printf '%s' "\$*" | grep -q 'xargs -0 fabriek-container'; then
	verb="\$(tr '\0' ' ')"
	printf '%s\n' "\$verb" >>"$TEST_TEMP_DIR/machine-verbs"
	case "\$verb" in
	"factory-render "*) echo "fabriek: egress asked for api.openai.com, which this host does not allow; dropped"; echo "acme: rendered" ;;
	"factory-endpoints "*) sed -n 's/^"\(api\.[a-z.]*\)" = .*/\1/p' "$FABRIEK_MACHINES/acme/fabriek.toml" ;;
	"factory-profiles "*) echo '{"rev":"abc","roles":{"builder":"/nix/store/aaaa-fabriek-role-builder"},"decider":"/var/lib/fabriek/factory/pi-decider"}' ;;
	esac
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
	cat >"$REPO/fabriek.toml" <<'EOF'
name = "acme"

[roles.builder]
command = ["claude"]
provides = ["build"]

[resources]
memory = "4G"
cores = 2
recordQuota = "2G"
egress = ["api.anthropic.com", "api.openai.com"]
EOF
	git -C "$REPO" add -A
	git -C "$REPO" -c commit.gpgsign=false commit -qm declare
	# The origin the machine clones from (ADR-032): a bare repository here.
	git init -q --bare "$TEST_TEMP_DIR/origin.git"
	git -C "$REPO" remote add origin "$TEST_TEMP_DIR/origin.git"
	git -C "$REPO" push -q origin HEAD
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

@test "up with no factory named takes the one registered, and with two asks which" {
	run_fabriek up
	assert_success
	assert_output --partial "acme is running"
	run_fabriek down
	printf '\n[factories.widgets]\npath = "%s"\n' "$REPO" >>"$FABRIEK_CONFIG"
	run_fabriek up
	[ "$status" -eq 2 ]
	assert_output --partial "which factory"
}

@test "starting a factory builds its machine and leaves it running" {
	run_fabriek up acme
	assert_success
	assert_output --partial "running"
	[ -f "$FABRIEK_MACHINES/acme/pid" ]
	kill -0 "$(cat "$FABRIEK_MACHINES/acme/pid")"
}

# ADR-057 point 1a: on a Linux host the store reaches the machine over
# virtiofs, and up starts the appliance's share daemons itself, one per
# program of the wrapper's supervisord configuration. The configuration
# also names supervisord's own event listener, which is no daemon of ours.
@test "up starts one share daemon per program of the runner's virtiofsd wrapper, and not supervisord's listener" {
	local conf="$TEST_TEMP_DIR/virtiofsd.conf" started="$TEST_TEMP_DIR/shares-started"
	cat >"$RUNNER/bin/share-daemon" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$started"
trap 'exit 0' TERM INT
while true; do sleep 0.2; done
EOF
	chmod +x "$RUNNER/bin/share-daemon"
	cat >"$conf" <<EOF
[eventlistener:notify]
command=$RUNNER/bin/share-daemon listener
events=PROCESS_STATE

[program:virtiofsd-ro-db]
command=$RUNNER/bin/share-daemon ro-db --socket-group=kvm
stdout_syslog=true

[program:virtiofsd-ro-store]
command=$RUNNER/bin/share-daemon ro-store --socket-group=kvm

[supervisord]
nodaemon=true
EOF
	printf '#!/usr/bin/env bash\nexec supervisord --configuration %s "$@"\n' "$conf" >"$RUNNER/bin/virtiofsd-run"
	chmod +x "$RUNNER/bin/virtiofsd-run"
	run_fabriek up acme
	assert_success
	run sort "$started"
	assert_output "ro-db
ro-store"
	run wc -l <"$FABRIEK_MACHINES/acme/virtiofsd.pids"
	assert_output 2
	run_fabriek down acme
	assert_success
	sleep 0.5
	run pgrep -f "share-daemon ro-"
	assert_failure
}

# The machine's host key lives on its pool, so a pool made anew is a new
# host at the same port, and the known_hosts of the old one refuses it as
# changed (measured 2026-09-16: a fresh factory never answered).
@test "a pool made anew forgets the host key the old pool answered with" {
	run_fabriek up acme
	assert_success
	echo "[localhost]:$(cat "$FABRIEK_MACHINES/acme/port") ssh-ed25519 AAAAold" >"$FABRIEK_MACHINES/acme/known_hosts"
	run_fabriek down acme
	rm "$FABRIEK_MACHINES/acme/pool.img"
	run_fabriek up acme
	assert_success
	[ ! -s "$FABRIEK_MACHINES/acme/known_hosts" ]
}

@test "a pool kept across a restart keeps its host key" {
	run_fabriek up acme
	assert_success
	echo "[localhost]:$(cat "$FABRIEK_MACHINES/acme/port") ssh-ed25519 AAAAkept" >"$FABRIEK_MACHINES/acme/known_hosts"
	run_fabriek down acme
	run_fabriek up acme
	assert_success
	run cat "$FABRIEK_MACHINES/acme/known_hosts"
	assert_output --partial AAAAkept
}

# What fabriek hands the machine (ADR-057 points 2 and 3): the credential,
# the operator's config projected for this factory plus the pin; and
# runtime.json, the facts the runner's script puts on qemu's command line.
@test "given a registered factory, up writes the credential the machine boots with, pinned at the repository's HEAD" {
	run_fabriek up acme
	assert_success
	local cred="$FABRIEK_MACHINES/acme/fabriek.toml"
	[ -f "$cred" ]
	run grep -c "^name = \"acme\"" "$cred"
	assert_output 1
	run grep -c "^remote = \"$TEST_TEMP_DIR/origin.git\"" "$cred"
	assert_output 1
	run grep -c "^rev = \"$(git -C "$REPO" rev-parse HEAD)\"" "$cred"
	assert_output 1
	run grep -c '^"api.anthropic.com" = "x-api-key"' "$cred"
	assert_output 1
	run grep -c "sk-secret-value" "$cred"
	assert_output 0
	run grep -c "anthropic.key" "$cred"
	assert_output 0
}

@test "runtime.json carries the machine's size as the declaration asked and the caps allow, the port, and the two credentials" {
	run_fabriek up acme
	assert_success
	run jq -cS '[.mem, .cpus, .sshPort, .diskSize, .credentials]' "$FABRIEK_MACHINES/acme/runtime.json"
	assert_output "[4096,2,$(cat "$FABRIEK_MACHINES/acme/port"),65536,{\"fabriek.authorized_keys\":\"authorized_keys\",\"fabriek.toml\":\"fabriek.toml\"}]"
	[ -f "$FABRIEK_MACHINES/acme/store.img" ]
	[ -f "$FABRIEK_MACHINES/acme/pool.img" ]
}

@test "a declaration the schema refuses stops up before a machine is started, naming the key" {
	printf 'colour = "blue"\n' >>"$REPO/fabriek.toml"
	git -C "$REPO" -c commit.gpgsign=false commit -qam colour
	run_fabriek up acme
	assert_failure
	assert_output --partial colour
	[ ! -f "$FABRIEK_MACHINES/acme/pid" ]
	[ ! -f "$NIX_CALLS" ]
}

# ADR-061: the operator's file may declare the factory whole; then the
# machine is sized from it and the repository must declare nothing.
@test "up sizes the machine from a declaration in the operator's file when the repository has none" {
	git -C "$REPO" rm -q fabriek.toml
	git -C "$REPO" -c commit.gpgsign=false commit -qm undeclare
	cat >>"$FABRIEK_CONFIG" <<TOML

[factories.acme.roles.builder]
provides = ["build"]

[[factories.acme.workflows.ship.stages]]
needs = "build"

[factories.acme.resources]
memory = "4G"
cores = 2
TOML
	run_fabriek up acme
	assert_success
	run jq -c '{mem, cpus}' "$FABRIEK_MACHINES/acme/runtime.json"
	assert_output '{"mem":4096,"cpus":2}'
}

@test "a factory declared in the operator's file and in the repository stops up naming both, before anything is written" {
	cat >>"$FABRIEK_CONFIG" <<TOML

[factories.acme.roles.builder]
provides = ["build"]
TOML
	run_fabriek up acme
	assert_failure
	assert_output --partial "acme is declared twice: in $FABRIEK_CONFIG and in $REPO/fabriek.toml"
	[ ! -f "$FABRIEK_MACHINES/acme/fabriek.toml" ]
	[ ! -f "$FABRIEK_MACHINES/acme/pid" ]
}

# ADR-061 points 3, 4 and 6: the operator's prompts, skill files and
# catalogue directories go to the machine through the lower store, so up
# puts each in the host's store and roots it, and the credential names the
# store paths; the credential itself is kept beside runtime.json, since a
# declaration in the operator's file has no commit to be read back from.
@test "up puts the operator's prompts, skills and catalogues in the store, roots them, and names them in the credential it keeps" {
	mkdir -p "$TEST_TEMP_DIR/catalogue/specialists"
	printf '# Strict\n' >"$TEST_TEMP_DIR/strict.md"
	printf '# Profile\n' >"$TEST_TEMP_DIR/SKILL.md"
	cat >>"$FABRIEK_CONFIG" <<TOML

[specialists.reviewer-strict]
extends = ["reviewer"]
prompt = "$TEST_TEMP_DIR/strict.md"

[specialists.rust]
prompt = "Inline text stays text."

[skills.cargo-profile]
skill = "$TEST_TEMP_DIR/SKILL.md"
TOML
	sed -i.bak "1i catalogues = [\"$TEST_TEMP_DIR/catalogue\"]" "$FABRIEK_CONFIG" && rm "$FABRIEK_CONFIG.bak"
	run_fabriek up acme
	assert_success
	local cred="$FABRIEK_MACHINES/acme/fabriek.toml"
	run grep -E '^"prompt" = "/nix/store/[a-z0-9]{32}-strict.md"$' "$cred"
	assert_success
	run grep -E '^"prompt" = "Inline text stays text."$' "$cred"
	assert_success
	run grep -E '^"skill" = "/nix/store/[a-z0-9]{32}-SKILL.md"$' "$cred"
	assert_success
	run grep -E '^catalogues = \["/nix/store/[a-z0-9]{32}-catalogue"\]$' "$cred"
	assert_success
	run grep -cE -- '--add-root .*/roots/(specialist|skill|catalogue)-' "$TEST_TEMP_DIR/nix-store-calls"
	assert_output 3
	run bash -c "ls $FABRIEK_MACHINES/acme/fabriek.toml.* | wc -l"
	assert_output 1
	run bash -c "diff $FABRIEK_MACHINES/acme/fabriek.toml $FABRIEK_MACHINES/acme/fabriek.toml.*"
	assert_success
}

# ADR-062 points 2 and 5: a git catalogue is fetched on the host at up by
# its rev, its tree's hash checked against the one the operator wrote,
# rooted, and named in the credential as a table with the store path
# beside the entry as written.
@test "up prefetches a git catalogue, checks its hash, roots it, and writes the table with the store path into the credential" {
	mkdir -p "$TEST_TEMP_DIR/fetched/catalogue/specialists"
	sed -i.bak '1i catalogues = [ { git = "github:acme/cat", rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", narHash = "sha256-IVj69VsrFsewKTLrwoGX9qIjVe6heqBwirkYoGlEbx4=", dir = "catalogue" } ]' "$FABRIEK_CONFIG" && rm "$FABRIEK_CONFIG.bak"
	run_fabriek up acme
	assert_success
	run grep -E '^flake prefetch --json github:acme/cat\?rev=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa$' "$NIX_CALLS"
	assert_success
	run grep -E -- "--add-root .*/roots/catalogue-0 --indirect -r $TEST_TEMP_DIR/fetched" "$TEST_TEMP_DIR/nix-store-calls"
	assert_success
	# Read back as the machine reads it: the entry as written, the store
	# path and the hash fetched beside it.
	run nix eval --json --impure --expr "builtins.fromTOML (builtins.readFile $FABRIEK_MACHINES/acme/fabriek.toml)" --apply 'c: c.catalogues'
	assert_success
	run jq -cS . <<<"$output"
	assert_output "[{\"dir\":\"catalogue\",\"git\":\"github:acme/cat\",\"narHash\":\"sha256-IVj69VsrFsewKTLrwoGX9qIjVe6heqBwirkYoGlEbx4=\",\"path\":\"$TEST_TEMP_DIR/fetched/catalogue\",\"rev\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}]"
}

@test "show -f names a git catalogue by its reference and rev, with the store path it became" {
	mkdir -p "$TEST_TEMP_DIR/fetched" "$TEST_TEMP_DIR/mine"
	sed -i.bak "1i catalogues = [ \"$TEST_TEMP_DIR/mine\", { git = \"github:acme/cat\", rev = \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\", narHash = \"sha256-IVj69VsrFsewKTLrwoGX9qIjVe6heqBwirkYoGlEbx4=\" } ]" "$FABRIEK_CONFIG" && rm "$FABRIEK_CONFIG.bak"
	run_fabriek up acme
	assert_success
	run_fabriek -f acme show
	assert_success
	assert_line --regexp "catalogue: /nix/store/[a-z0-9]{32}-mine$"
	assert_line --partial "catalogue: github:acme/cat at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ($TEST_TEMP_DIR/fetched)"
}

@test "a git catalogue with a dir and no hash is fetched with its dir, and its hash written into the credential" {
	mkdir -p "$TEST_TEMP_DIR/fetched/catalogue"
	sed -i.bak '1i catalogues = [ { git = "git+https://forge.example/cat.git", rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", dir = "catalogue" } ]' "$FABRIEK_CONFIG" && rm "$FABRIEK_CONFIG.bak"
	run_fabriek up acme
	assert_success
	run nix eval --json --impure --expr "builtins.fromTOML (builtins.readFile $FABRIEK_MACHINES/acme/fabriek.toml)" --apply 'c: [ (builtins.head c.catalogues).path (builtins.head c.catalogues).narHash ]'
	assert_output "[\"$TEST_TEMP_DIR/fetched/catalogue\",\"sha256-IVj69VsrFsewKTLrwoGX9qIjVe6heqBwirkYoGlEbx4=\"]"
}

@test "a git catalogue whose fetched tree has another hash than the one written stops up naming both" {
	mkdir -p "$TEST_TEMP_DIR/fetched"
	sed -i.bak '1i catalogues = [ { git = "github:acme/cat", rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", narHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" } ]' "$FABRIEK_CONFIG" && rm "$FABRIEK_CONFIG.bak"
	run_fabriek up acme
	assert_failure
	assert_output --partial "catalogue github:acme/cat at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: the tree fetched has hash sha256-IVj69VsrFsewKTLrwoGX9qIjVe6heqBwirkYoGlEbx4=, not sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	[ ! -f "$FABRIEK_MACHINES/acme/pid" ]
}

@test "a git catalogue whose dir the tree lacks stops up naming the dir" {
	mkdir -p "$TEST_TEMP_DIR/fetched"
	sed -i.bak '1i catalogues = [ { git = "github:acme/cat", rev = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", narHash = "sha256-IVj69VsrFsewKTLrwoGX9qIjVe6heqBwirkYoGlEbx4=", dir = "nowhere" } ]' "$FABRIEK_CONFIG" && rm "$FABRIEK_CONFIG.bak"
	run_fabriek up acme
	assert_failure
	assert_output --partial "catalogue github:acme/cat at aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: the tree has no nowhere"
}

# ADR-063 point 2: the machine accepts the operators' keys beside its own,
# from one authorized_keys file up writes and hands over as the credential.
@test "up hands the machine an authorized_keys of its own key and every operator key, in that order" {
	sed -i.bak '1i operatorKeys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGt4Q3fL4G7y8n2u9qS0mR1x7Hf2VfR7c1aFf4QZ1F2K me@pc"]' "$FABRIEK_CONFIG" && rm "$FABRIEK_CONFIG.bak"
	run_fabriek up acme
	assert_success
	run jq -r '.credentials["fabriek.authorized_keys"]' "$FABRIEK_MACHINES/acme/runtime.json"
	assert_output authorized_keys
	run cat "$FABRIEK_MACHINES/acme/authorized_keys"
	assert_line --index 0 "$(cat "$FABRIEK_MACHINES/acme/id_ed25519.pub")"
	assert_line --index 1 "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGt4Q3fL4G7y8n2u9qS0mR1x7Hf2VfR7c1aFf4QZ1F2K me@pc"
}

# A build that fails prints a trace with the thrown message at its end,
# which is the one line the operator can act on.
@test "when the appliance's build fails, the thrown message is printed first and the trace after it" {
	cat >"$STUB_DIR/cw-nix" <<EOF
#!/usr/bin/env bash
case "\$1" in
build)
	cat >&2 <<'TRACE'
error:
       ... while evaluating the attribute 'config'
         at /nix/store/xxx-source/modules/appliance.nix:30:3:
       error: attribute 'vmHostPackages' missing
TRACE
	exit 1
	;;
*) exec "$REAL_NIX" "\$@" ;;
esac
EOF
	chmod +x "$STUB_DIR/cw-nix"
	run_fabriek up acme
	assert_failure
	assert_line --index 1 --partial "attribute 'vmHostPackages' missing"
	assert_output --partial "while evaluating the attribute"
	refute_line --index 1 --partial "while evaluating"
}

@test "the model the operator named for an endpoint reaches the machine in the credential" {
	printf '\n[models]\n"api.anthropic.com" = "claude-opus-5"\n' >>"$FABRIEK_CONFIG"
	run_fabriek up acme
	assert_success
	run grep -c '^"api.anthropic.com" = "claude-opus-5"' "$FABRIEK_MACHINES/acme/fabriek.toml"
	assert_output 1
}

# ADR-057 point 1: the appliance is fabriek's own package, built or fetched
# once and rooted beside the machine, and nothing of the repository is
# built on this host.
@test "up builds the appliance from fabriek itself, rooted beside the machine, and no flake per factory" {
	run_fabriek up acme
	assert_success
	run grep -c "^build --out-link $FABRIEK_MACHINES/acme/appliance --print-out-paths path:$FABRIEK_ROOT#machine$" "$NIX_CALLS"
	assert_output 1
	[ ! -e "$FABRIEK_MACHINES/acme/machine/flake.nix" ]
	[ ! -e "$FABRIEK_MACHINES/acme/machine/flake.lock" ]
}

@test "what the clamp changed is said where the operator will see it" {
	run_fabriek up acme
	assert_success
	assert_output --partial "api.openai.com"
}

@test "the first up pins the repository's HEAD; a second keeps the pin; --update moves it" {
	run_fabriek up acme
	assert_success
	local first
	first="$(git -C "$REPO" rev-parse HEAD)"
	printf '# more\n' >>"$REPO/fabriek.toml"
	git -C "$REPO" -c commit.gpgsign=false commit -qam more
	run_fabriek down acme
	run_fabriek up acme
	assert_success
	run grep -c "^rev = \"$first\"" "$FABRIEK_MACHINES/acme/fabriek.toml"
	assert_output 1
	run_fabriek down acme
	run_fabriek up -u acme
	assert_success
	run grep -c "^rev = \"$(git -C "$REPO" rev-parse HEAD)\"" "$FABRIEK_MACHINES/acme/fabriek.toml"
	assert_output 1
}

# ADR-057 point 4: render first, then the credential, then prepare. Render
# needs no secret; the proxy needs the secret; prepare needs the proxy and
# the bus.
@test "once the machine answers, up renders the factory, gives the credential, prepares, and roots the profiles it built" {
	run_fabriek up acme
	assert_success
	run cat "$TEST_TEMP_DIR/machine-verbs"
	assert_line --index 0 --partial "factory-render acme"
	assert_line --index 1 --partial "factory-endpoints acme"
	assert_line --index 2 --partial "factory-prepare acme $TEST_TEMP_DIR/origin.git"
	assert_line --index 3 --partial "factory-profiles acme"
	# The order on the wire: render, endpoints, the credential, prepare.
	run bash -c "grep -oE 'fabriek-egress-credential [a-z.]+|xargs -0 fabriek-container' '$SSH_CALLS'"
	assert_line --index 0 "xargs -0 fabriek-container"
	assert_line --index 1 "xargs -0 fabriek-container"
	assert_line --index 2 "fabriek-egress-credential api.anthropic.com"
	assert_line --index 3 "xargs -0 fabriek-container"
	run cat "$TEST_TEMP_DIR/nix-store-calls"
	assert_output "--add-root $FABRIEK_MACHINES/acme/roots/builder --indirect -r /nix/store/aaaa-fabriek-role-builder"
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
	run_fabriek ps
	assert_success
	assert_output --partial "running"

	run_fabriek down acme
	assert_success
	run_fabriek ps
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
	run grep -c '^"api' "$FABRIEK_MACHINES/acme/fabriek.toml"
	assert_output 0
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

# ADR-057 point 7: a run's identity is the image, the pin and the profiles
# the machine built; show -f with nothing named prints it from the machine.
@test "show -f with no role asks the running machine what the factory is made of" {
	run_fabriek up acme
	assert_success
	run_fabriek -f acme show
	assert_success
	assert_line --index 0 "image: $RUNNER"
	assert_line --index 1 "rev: abc"
	assert_line --index 2 "  builder: /nix/store/aaaa-fabriek-role-builder"
	assert_line --index 3 "  decider: /var/lib/fabriek/factory/pi-decider"
	# And which file declared it (ADR-061 point 6): the repository's here.
	assert_line --index 4 "declared in: $REPO/fabriek.toml"
	run_fabriek -f acme show --json
	assert_success
	run jq -r '.image, .rev, .declaration' <<<"$output"
	assert_line --index 0 "$RUNNER"
	assert_line --index 1 abc
	assert_line --index 2 "$REPO/fabriek.toml"
}

@test "show -f on a factory declared in the operator's file prints the declaration the machine was given" {
	git -C "$REPO" rm -q fabriek.toml
	git -C "$REPO" -c commit.gpgsign=false commit -qm undeclare
	cat >>"$FABRIEK_CONFIG" <<TOML

[factories.acme.roles.builder]
provides = ["build"]

[[factories.acme.workflows.ship.stages]]
needs = "build"
TOML
	run_fabriek up acme
	assert_success
	run_fabriek -f acme show
	assert_success
	assert_line --partial "declared in: $FABRIEK_MACHINES/acme/fabriek.toml."
	assert_line --partial '[declaration."roles"."builder"]'
	assert_line --partial '"provides" = ["build"]'
}

@test "show -f on a factory that is not running says the machine is the one to ask" {
	run_fabriek -f acme show
	assert_failure
	assert_output --partial "not running"
}
