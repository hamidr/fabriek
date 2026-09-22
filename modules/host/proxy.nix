## The proxy (ADR-037 points 3 and 4): holds the model credential, injects
## it at egress, and counts what each cage spent. One nginx on the host
## (ADR-067 point 2): a server per factory on its bridge, a dictionary and
## a ceiling per factory, the locations render writes under the factory's
## directory, and per factory the credential headers composed from the
## endpoints render wrote.
##
## The count is per source address and per factory, read by njs from the
## response body; at the ceiling the proxy answers 429 itself, the only
## hard cost control. The counts live in nginx's memory and start at zero
## when it does: a restart is a spend nobody remembers, accepted and stated
## in docs/roadmap.md, because the ceiling bounds a runaway and is not an
## account.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.fabriek;
  egress = "fabriek-egress";
in
{
  config = lib.mkIf cfg.enable {
    ## The body filter and the status handler, a file beside this one so
    ## node can drive it with the API's own bodies (spend.test.mjs); read
    ## from /etc, where njs has no import path trouble with an absolute
    ## file.
    environment.etc."fabriek/spend.js".text = builtins.readFile ./spend.js;

    users.users.${egress} = {
      isSystemUser = true;
      group = egress;
      uid = 500;
      description = "Holds every factory's model credential and is a cage's only way out";
    };
    users.groups.${egress} = { };

    ## Every up reloads the proxy, and two factories brought up one after
    ## the other reload it twice in a few seconds. A reload does not count
    ## against systemd's start limit but a restart does, and one failed
    ## start makes the next reload a restart, so the limit is off here:
    ## found on the host, where the second factory's up was refused with
    ## "start of the service was attempted too often" and nothing else was
    ## wrong.
    services.nginx = {
      enable = true;
      user = egress;
      group = egress;
      recommendedProxySettings = true;
      additionalModules = [ pkgs.nginxModules.njs ];

      ## What a request cost, and nothing about what it carried (ADR-038
      ## point 4). No $http_ and no $sent_http_: a request header is where
      ## the credential is.
      commonHttpConfig = ''
        js_import spend from /etc/fabriek/spend.js;
        ${lib.concatMapStringsSep "\n" (name: "js_shared_dict_zone zone=spend_${name}:256k type=number;") (
          lib.attrNames cfg.plan
        )}
        js_set $spend_over spend.over;

        log_format fabriek_egress
          '$remote_addr $request $status $upstream_status '
          'req=$request_length resp=$body_bytes_sent '
          'time=$request_time upstream=$upstream_response_time '
          'retry_after=$upstream_http_retry_after '
          'ratelimit_requests=$upstream_http_anthropic_ratelimit_requests_remaining '
          'ratelimit_tokens=$upstream_http_anthropic_ratelimit_tokens_remaining';
      '';

      ## The ceiling and the locations are the factory's: render writes
      ## them under its directory from the clamped declaration
      ## (modules/factory-render.sh) and reloads nginx. A glob include of
      ## nothing is a server with no endpoint, which is what a factory
      ## before render, or one the operator allowed nothing, has.
      virtualHosts = lib.mapAttrs' (
        name: p:
        lib.nameValuePair "fabriek-${name}" {
          listen = [
            {
              addr = p.host;
              port = cfg.ports.egress;
            }
          ];
          extraConfig = ''
            access_log syslog:server=unix:/dev/log,tag=fabriek_egress_${name},nohostname fabriek_egress;
            error_log syslog:server=unix:/dev/log,tag=fabriek_egress_${name},nohostname;
            set $spend_zone spend_${name};
            set $spend_ceiling 0;

            location = /status {
              js_content spend.status;
            }

            include ${p.etc}/proxy/*.conf;
          '';
        }
      ) cfg.plan;
    };

    ## Per factory, the header lines the locations include, from the
    ## endpoints render wrote and the secrets up put under the factory's
    ## state (ADR-025: a path, never a value, and readable by the proxy's
    ## user alone).
    systemd.services = {
      ## Every up reloads the proxy, and two factories brought up one
      ## after the other reload it twice in a few seconds. A reload does
      ## not count against systemd's start limit but a restart does, and a
      ## reload of something that failed to start is a restart, so the
      ## limit is off: found on the host, where the second factory's up
      ## was refused with "start of the service was attempted too often"
      ## and nothing else was wrong.
      ## NixOS gives nginx a limit of its own, which this replaces.
      nginx.startLimitIntervalSec = lib.mkForce 0;
    }
    // lib.mapAttrs' (
      name: p:
      lib.nameValuePair "fabriek-${name}-egress-credentials" {
        description = "Compose the factory ${name}'s credential headers for the proxy";
        wantedBy = [ "multi-user.target" ];
        before = [ "nginx.service" ];
        requiredBy = [ "nginx.service" ];
        after = [ "fabriek-${name}-state.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Slice = "fabriek-${name}.slice";
        };
        path = [
          pkgs.coreutils
          pkgs.jq
        ];
        script = ''
          set -eu
          install -d -m 0750 -o ${egress} -g ${egress} /run/fabriek-egress /run/fabriek-egress/${name}
          endpoints=${p.etc}/endpoints.json
          [ -f "$endpoints" ] || exit 0
          jq -r '.credentials | to_entries[] | "\(.key)\t\(.value)"' "$endpoints" |
          while IFS=$'\t' read -r host header; do
            conf=/run/fabriek-egress/${name}/$host.conf
            secret=${p.state}/egress/$host
            : >"$conf"
            if [ -s "$secret" ]; then
              printf 'proxy_set_header %s "%s";\n' "$header" "$(cat "$secret")" >"$conf"
            fi
            chown ${egress}:${egress} "$conf"
            chmod 0400 "$conf"
          done
        '';
      }
    ) cfg.plan;

    ## A cage's only interface is its factory's bridge, and the host
    ## forwards nothing from or to one, whatever docker or a VPN set
    ## ip_forward to: a drop in a base chain holds beside any other
    ## table's accept.
    networking.nftables = {
      enable = true;
      tables.fabriek = {
        family = "inet";
        content = ''
          chain forward {
            type filter hook forward priority filter; policy accept;
            iifname "fb-*" drop
            oifname "fb-*" drop
          }
        '';
      };
    };
  };
}
