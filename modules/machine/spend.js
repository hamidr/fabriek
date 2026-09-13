// Tokens spent, per source address and in total. The upstream reports
// usage in every response: once for a plain one, and for a stream in
// message_start (input, and the output so far) and then message_delta
// (output, cumulative). Input is added when first seen; output is the
// last figure seen, added when the response ends.
//
// A chunk boundary can fall inside a key or a figure, so each chunk is
// scanned with the tail of the one before it. Rescanning a figure the tail
// already held changes nothing: input is taken once, and a later output
// figure is the same or larger.
var pending = {};
var TAIL = 32;

function count(r, data, flags) {
  var id = r.variables.request_id;
  var p = pending[id];
  if (!p) { p = pending[id] = { input: 0, output: 0, inputSeen: false, tail: "" }; }
  var text = p.tail + data;
  var m;
  if (!p.inputSeen) {
    m = /"input_tokens"\s*:\s*(\d+)/.exec(text);
    if (m) { p.input = parseInt(m[1]); p.inputSeen = true; }
  }
  var re = /"output_tokens"\s*:\s*(\d+)/g;
  while ((m = re.exec(text)) !== null) { p.output = parseInt(m[1]); }
  p.tail = text.slice(-TAIL);
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
