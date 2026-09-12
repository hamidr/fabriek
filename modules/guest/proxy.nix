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
  lib,
  pkgs,
  ...
}:
let
  cfg = config.cageworks.machine;
  plan = builtins.fromJSON config.environment.etc."cageworks/bridge.json".text;
in
{
  options.cageworks.machine.tokenCeiling = lib.mkOption {
    type = lib.types.int;
    default = 0;
    description = ''
      Input plus output tokens the factory may spend before the proxy refuses,
      as the factory asked and the operator allowed. Zero is no ceiling.
    '';
  };

  config = lib.mkIf (cfg.egress != [ ]) {
    ## The body filter and the status handler. Loaded from /etc so the module
    ## reads as configuration beside the rest, and njs has no import path
    ## trouble with an absolute file.
    environment.etc."cageworks/spend.js".text = ''
      // Tokens spent, per source address and in total. The upstream reports
      // usage in every response: once for a plain one, and for a stream in
      // message_start (input, and the output so far) and then message_delta
      // (output, cumulative). Input is added when first seen; output is the
      // last figure seen, added when the response ends.
      var pending = {};

      function count(r, data, flags) {
        var id = r.variables.request_id;
        var p = pending[id];
        if (!p) { p = pending[id] = { input: 0, output: 0, inputSeen: false }; }
        var m;
        if (!p.inputSeen) {
          m = /"input_tokens"\s*:\s*(\d+)/.exec(data);
          if (m) { p.input = parseInt(m[1]); p.inputSeen = true; }
        }
        var re = /"output_tokens"\s*:\s*(\d+)/g;
        while ((m = re.exec(data)) !== null) { p.output = parseInt(m[1]); }
        if (flags.last) {
          var spent = p.input + p.output;
          var dict = ngx.shared.spend;
          dict.incr(r.variables.remote_addr, spent);
          dict.incr("total", spent);
          delete pending[id];
        }
        r.sendBuffer(data, flags);
      }

      // 1 when the factory is at or past its ceiling, 0 otherwise. A ceiling
      // of zero is none.
      function over(r) {
        var ceiling = parseInt(r.variables.spend_ceiling);
        if (!ceiling) { return "0"; }
        var total = ngx.shared.spend.get("total") || 0;
        return total >= ceiling ? "1" : "0";
      }

      // The counts, for the executor's soft limit and for the proofs.
      function status(r) {
        var out = {};
        ngx.shared.spend.keys().forEach(function (k) { out[k] = ngx.shared.spend.get(k); });
        r.headersOut["Content-Type"] = "application/json";
        r.return(200, JSON.stringify(out));
      }

      export default { count, over, status };
    '';

    services.nginx = {
      enable = true;
      user = "cageworks-egress";
      group = "cageworks-egress";
      recommendedProxySettings = true;
      additionalModules = [ pkgs.nginxModules.njs ];

      ## What a request cost, and nothing about what it carried (ADR-038
      ## point 4). No $http_ and no $sent_http_: a request header is where
      ## the credential is.
      commonHttpConfig = ''
        js_import spend from /etc/cageworks/spend.js;
        js_shared_dict_zone zone=spend:256k;
        js_set $spend_over spend.over;

        log_format cageworks_egress
          '$remote_addr $request $status $upstream_status '
          'req=$request_length resp=$body_bytes_sent '
          'time=$request_time upstream=$upstream_response_time '
          'retry_after=$upstream_http_retry_after '
          'ratelimit_requests=$upstream_http_anthropic_ratelimit_requests_remaining '
          'ratelimit_tokens=$upstream_http_anthropic_ratelimit_tokens_remaining';
      '';

      virtualHosts."cageworks-egress" = {
        listen = [
          {
            addr = plan.host;
            port = cfg.egressPort;
          }
        ];
        extraConfig = ''
          set $spend_ceiling ${toString cfg.tokenCeiling};
          access_log syslog:server=unix:/dev/log,tag=cageworks_egress,nohostname cageworks_egress;
          error_log syslog:server=unix:/dev/log,tag=cageworks_egress,nohostname;

          location = /status {
            js_content spend.status;
          }
        ''
        + lib.concatMapStrings (host: ''
          location /${host}/ {
            if ($spend_over = 1) {
              return 429;
            }
            proxy_pass https://${host}/;
            proxy_set_header Host ${host};
            proxy_ssl_server_name on;
            ## Streamed responses must reach the filter chunk by chunk, or
            ## the last figure is the only one and arrives when the turn is
            ## over; gzip would hide the body from the filter altogether.
            proxy_buffering off;
            proxy_set_header Accept-Encoding "";
            js_body_filter spend.count;
            include /run/cageworks-egress/${host}.conf;
          }
        '') cfg.egress;
      };
    };
  };
}
