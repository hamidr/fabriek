## The proxy (ADR-037 points 3 and 4): holds the model credential, injects it
## at egress, and counts what each cage spent.
##
## It listens on the bridge, where a cage reaches it by address, and the
## bridge's first rule is what makes the source address the cage's own. The
## count is per source address and for the factory, in a shared dictionary
## that njs reads from the response body: the input tokens once, from the
## message start, and the output tokens as the last cumulative figure the
## upstream reported, streamed or not. At the ceiling the proxy answers 429
## itself, which is the only hard cost control. The executor reads /status
## for the soft limit.
##
## The counts live in nginx's memory and start at zero when it does; a
## restart is a spend nobody remembers. Accepted for now and stated in
## docs/roadmap.md, because the ceiling is a bound on a runaway and not an
## account.
{
  config,
  pkgs,
  ...
}:
let
  cfg = config.fabriek.machine;
  host = config.environment.variables.FABRIEK_BRIDGE_HOST;
in
{
  config = {
    ## The body filter and the status handler, a file beside this one so
    ## node can drive it with the API's own bodies (spend.test.mjs); on the
    ## machine it is read from /etc, where njs has no import path trouble
    ## with an absolute file.
    environment.etc."fabriek/spend.js".text = builtins.readFile ./spend.js;

    services.nginx = {
      enable = true;
      user = "fabriek-egress";
      group = "fabriek-egress";
      recommendedProxySettings = true;
      additionalModules = [ pkgs.nginxModules.njs ];

      ## What a request cost, and nothing about what it carried (ADR-038
      ## point 4). No $http_ and no $sent_http_: a request header is where
      ## the credential is.
      commonHttpConfig = ''
        js_import spend from /etc/fabriek/spend.js;
        js_shared_dict_zone zone=spend:256k type=number;
        js_set $spend_over spend.over;

        log_format fabriek_egress
          '$remote_addr $request $status $upstream_status '
          'req=$request_length resp=$body_bytes_sent '
          'time=$request_time upstream=$upstream_response_time '
          'retry_after=$upstream_http_retry_after '
          'ratelimit_requests=$upstream_http_anthropic_ratelimit_requests_remaining '
          'ratelimit_tokens=$upstream_http_anthropic_ratelimit_tokens_remaining';
      '';

      ## The ceiling and the locations are the factory's (ADR-057 point 4):
      ## factory-prepare renders them under the state directory from the
      ## clamped declaration (modules/factory-render.sh) and reloads nginx.
      ## A glob include of nothing is a vhost with no endpoint, which is
      ## what a machine before prepare, or an operator who allowed none, has.
      virtualHosts."fabriek-egress" = {
        listen = [
          {
            addr = host;
            port = cfg.egressPort;
          }
        ];
        extraConfig = ''
          access_log syslog:server=unix:/dev/log,tag=fabriek_egress,nohostname fabriek_egress;
          error_log syslog:server=unix:/dev/log,tag=fabriek_egress,nohostname;
          set $spend_ceiling 0;

          location = /status {
            js_content spend.status;
          }

          include /var/lib/fabriek/factory/proxy/*.conf;
        '';
      };
    };
  };
}
