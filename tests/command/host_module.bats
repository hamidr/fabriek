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
