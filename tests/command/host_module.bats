#!/usr/bin/env bats
# A NixOS host declares its factories (ADR-048): services.fabriek renders the
# operator's config.toml and a unit per auto-started factory. The module is
# evaluated for real in a minimal NixOS configuration; nothing is built.

load ../test_helper/common

setup() {
	setup_temp_dir
	HOST="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
	MACHINE="${HOST%%-*}-linux"
}

teardown() {
	teardown_temp_dir
}

## A NixOS configuration with the module and the options given, and one
## attribute of its config as JSON.
host_eval() {
	nix eval --json --impure --expr "
	  let flake = builtins.getFlake \"path:$FABRIEK_ROOT\";
	      c = (flake.inputs.nixpkgs.lib.nixosSystem {
	        system = \"$MACHINE\";
	        modules = [
	          flake.nixosModules.host
	          { boot.loader.grub.enable = false; fileSystems.\"/\" = { device = \"none\"; fsType = \"tmpfs\"; }; system.stateVersion = \"25.05\"; nixpkgs.overlays = [ flake.overlays.default ]; }
	          { services.fabriek = { enable = true; $1 }; }
	        ];
	      }).config;
	  in $2" 2> >(grep -v -e 'Nix search path entry' >&2)
}

@test "the module renders the operator's config as the TOML the CLI reads, at /etc/fabriek/config.toml" {
	run host_eval 'caps = { memory = "16G"; cores = 8; egress = [ "api.anthropic.com" ]; };
	               credentials."api.anthropic.com" = { header = "x-api-key"; file = "/run/secrets/anthropic"; };
	               models."api.anthropic.com" = "claude-opus-5";
	               factories.acme.path = "/srv/acme";' \
		'c.environment.etc."fabriek/config.toml".text'
	assert_success
	local text
	text="$(jq -r . <<<"$output")"
	# shellcheck source=../../modules/names.sh
	source "$FABRIEK_ROOT/modules/names.sh"
	# shellcheck source=../../modules/schema.sh
	source "$FABRIEK_ROOT/modules/schema.sh"
	# shellcheck source=../../modules/resources.sh
	source "$FABRIEK_ROOT/modules/resources.sh"
	# shellcheck source=../../modules/repo-declaration.sh
	source "$FABRIEK_ROOT/modules/repo-declaration.sh"
	# shellcheck source=../../modules/operator-config.sh
	source "$FABRIEK_ROOT/modules/operator-config.sh"
	printf '%s\n' "$text" >"$TEST_TEMP_DIR/config.toml"
	run fabriek_operator_config "$TEST_TEMP_DIR/config.toml"
	assert_success
	run jq -c '[.caps.cores, .factories.acme.path, .credentials["api.anthropic.com"].header, .models["api.anthropic.com"]]' <<<"$output"
	assert_output '[8,"/srv/acme","x-api-key","claude-opus-5"]'
}

@test "a factory with autoStart gets a unit that brings its machine up at boot and down at stop, as root, under /var/lib" {
	run host_eval 'factories.acme = { path = "/srv/acme"; autoStart = true; }; factories.widgets.path = "/srv/widgets";' \
		'{ start = c.systemd.services.fabriek-acme.serviceConfig.ExecStart; stop = c.systemd.services.fabriek-acme.serviceConfig.ExecStop;
		   type = c.systemd.services.fabriek-acme.serviceConfig.Type; env = c.systemd.services.fabriek-acme.environment;
		   wanted = c.systemd.services.fabriek-acme.wantedBy; widgets = c.systemd.services ? fabriek-widgets; }'
	assert_success
	run jq -c '[(.start | test("/bin/fabriek up acme$")), (.stop | test("/bin/fabriek down acme$")), .type, .env.FABRIEK_CONFIG, .env.FABRIEK_MACHINES, .wanted, .widgets]' <<<"$output"
	assert_output '[true,true,"oneshot","/etc/fabriek/config.toml","/var/lib/fabriek/machines",["multi-user.target"],false]'
}

@test "the CLI is on the host's PATH, since the unit and a hand run the same program" {
	run host_eval 'factories.acme.path = "/srv/acme";' 'map (p: p.pname or p.name) c.environment.systemPackages'
	assert_success
	assert_output --partial '"fabriek"'
}

# ADR-061: everything the operator's file may say, roles and workflows,
# specialists and skills and catalogue directories, is an option here and
# comes out as the TOML the CLI reads: the same value, read back.
@test "the module renders a whole factory, specialists, skills and catalogues, and the CLI reads back what was given" {
	mkdir -p "$TEST_TEMP_DIR/cat/specialists"
	printf '# Strict\n' >"$TEST_TEMP_DIR/strict.md"
	run host_eval "factories.knot = {
	                 path = \"/srv/knot\";
	                 roles.backend = { provides = [ \"build\" ]; specialists = [ \"rust\" ]; shell = \"default\"; replicas = 2; };
	                 roles.reviewer = { provides = [ \"review\" ]; specialists = [ \"strict\" ]; };
	                 workflows.ship = {
	                   stages = [ { needs = \"build\"; done = \"tests pass\"; ready = [ \"acceptance\" ]; } { needs = \"review\"; verdict = true; gate = \"before-integration\"; } ];
	                   budget.runs = 200;
	                   consults.backend = [ \"reviewer\" ];
	                 };
	                 resources = { memory = \"8G\"; cores = 4; egress = [ \"api.anthropic.com\" ]; };
	                 decider.policy = \"docs/policy.md\";
	               };
	               specialists.rust = { extends = [ \"developer\" ]; tools = [ \"cargo\" ]; skills = [ \"cargo-profile\" ]; prompt = \"You write Rust.\"; };
	               specialists.strict = { extends = [ \"reviewer\" ]; prompt = $TEST_TEMP_DIR/strict.md; };
	               skills.cargo-profile = { tools = [ \"cargo\" ]; skill = \"# Profile\"; };
	               catalogues = [ $TEST_TEMP_DIR/cat ];" \
		'c.environment.etc."fabriek/config.toml".text'
	assert_success
	local text
	text="$(jq -r . <<<"$output")"
	source "$FABRIEK_ROOT/modules/names.sh"
	source "$FABRIEK_ROOT/modules/schema.sh"
	source "$FABRIEK_ROOT/modules/resources.sh"
	source "$FABRIEK_ROOT/modules/repo-declaration.sh"
	source "$FABRIEK_ROOT/modules/operator-config.sh"
	printf '%s\n' "$text" >"$TEST_TEMP_DIR/config.toml"
	run fabriek_operator_config "$TEST_TEMP_DIR/config.toml"
	assert_success
	run jq -cS '{ knot: (.factories.knot | del(.path)), rust: .specialists.rust, profile: .skills."cargo-profile" }' <<<"$output"
	assert_output '{"knot":{"decider":{"policy":"docs/policy.md"},"resources":{"cores":4,"egress":["api.anthropic.com"],"memory":"8G"},"roles":{"backend":{"provides":["build"],"replicas":2,"shell":"default","specialists":["rust"]},"reviewer":{"provides":["review"],"specialists":["strict"]}},"workflows":{"ship":{"budget":{"runs":200},"consults":{"backend":["reviewer"]},"stages":[{"done":"tests pass","needs":"build","ready":["acceptance"]},{"gate":"before-integration","needs":"review","verdict":true}]}}},"profile":{"skill":"# Profile","tools":["cargo"]},"rust":{"extends":["developer"],"prompt":"You write Rust.","skills":["cargo-profile"],"tools":["cargo"]}}'
	# A path given for a prompt or a catalogue is a store path in the file.
	run fabriek_operator_config "$TEST_TEMP_DIR/config.toml"
	run jq -r '.specialists.strict.prompt, .catalogues[0]' <<<"$output"
	assert_line --index 0 --regexp '^/nix/store/[a-z0-9]{32}-strict.md$'
	assert_line --index 1 --regexp '^/nix/store/[a-z0-9]{32}-cat$'
	# And the declaration the CLI would send is the one given.
	run fabriek_operator_declaration "$TEST_TEMP_DIR/config.toml" knot
	assert_success
	run jq -r '.roles | keys | join(",")' <<<"$output"
	assert_output "backend-1,backend-2,reviewer"
}
