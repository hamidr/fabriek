// The counting filter, driven the way nginx drives it: one call per body
// chunk with the request's variables, the last call flagged, and a shared
// dictionary that outlives the request. The bodies are what the Messages API
// answers, plain and streamed, so what is asserted is what a real turn costs.
import { test } from "node:test";
import assert from "node:assert/strict";

function dict() {
  const m = new Map();
  return {
    incr(k, d) { const v = (m.get(k) ?? 0) + d; m.set(k, v); return v; },
    get(k) { return m.get(k); },
    keys() { return [...m.keys()]; },
  };
}

globalThis.ngx = { shared: { spend: dict() } };
const spend = (await import("./spend.js")).default;

/** One response from one address, delivered in the given chunks. */
function respond(addr, id, chunks) {
  const sent = [];
  const r = { variables: { connection: id, connection_requests: 1, remote_addr: addr }, sendBuffer: (d, f) => sent.push([d, f]) };
  chunks.forEach((c, i) => spend.count(r, c, { last: i === chunks.length - 1 }));
  return sent;
}

const plain = JSON.stringify({
  id: "msg_01", type: "message", role: "assistant", model: "claude-sonnet-5",
  content: [{ type: "text", text: "Hi" }], stop_reason: "end_turn", stop_sequence: null,
  usage: { input_tokens: 10, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 25 },
});

const streamed = [
  'event: message_start\ndata: {"type":"message_start","message":{"id":"msg_02","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":30,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}\n\n',
  'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n',
  'event: ping\ndata: {"type": "ping"}\n\n',
  'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}\n\n',
  'event: content_block_stop\ndata: {"type":"content_block_stop","index":0}\n\n',
  'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}\n\n',
  'event: message_stop\ndata: {"type":"message_stop"}\n\n',
];

test("given a plain response, when it ends, then input plus output is on the address and on the total", () => {
  globalThis.ngx.shared.spend = dict();
  respond("10.77.0.10", "a", [plain]);
  assert.equal(ngx.shared.spend.get("10.77.0.10"), 35);
  assert.equal(ngx.shared.spend.get("total"), 35);
});

test("given a streamed response, when it ends, then output is the last cumulative figure and not the sum of the figures seen", () => {
  globalThis.ngx.shared.spend = dict();
  respond("10.77.0.10", "b", streamed);
  assert.equal(ngx.shared.spend.get("10.77.0.10"), 45);
});

test("given a stream whose chunk boundary falls inside the output figure, when it ends, then the whole figure is counted", () => {
  globalThis.ngx.shared.spend = dict();
  const whole = streamed.join("");
  const cut = whole.indexOf('"output_tokens":15}') + '"output_tokens":1'.length;
  respond("10.77.0.10", "c", [whole.slice(0, cut), whole.slice(cut)]);
  assert.equal(ngx.shared.spend.get("10.77.0.10"), 45);
});

test("given a stream whose chunk boundary falls inside the key, when it ends, then the figure after it is still counted", () => {
  globalThis.ngx.shared.spend = dict();
  const whole = streamed.join("");
  const cut = whole.lastIndexOf('"output_tokens"') + 5;
  respond("10.77.0.10", "d", [whole.slice(0, cut), whole.slice(cut)]);
  assert.equal(ngx.shared.spend.get("10.77.0.10"), 45);
});

test("given text the model wrote that mentions output_tokens, when the stream ends, then only the usage figure is counted", () => {
  globalThis.ngx.shared.spend = dict();
  const chatty = streamed.slice();
  chatty[3] = 'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"usage: {\\"input_tokens\\": 999, \\"output_tokens\\": 999}"}}\n\n';
  respond("10.77.0.10", "e", chatty);
  assert.equal(ngx.shared.spend.get("10.77.0.10"), 45);
});

test("given two addresses, when each answers, then each is counted apart and the total is both", () => {
  globalThis.ngx.shared.spend = dict();
  respond("10.77.0.10", "f", [plain]);
  respond("10.77.0.2", "g", streamed);
  assert.equal(ngx.shared.spend.get("10.77.0.10"), 35);
  assert.equal(ngx.shared.spend.get("10.77.0.2"), 45);
  assert.equal(ngx.shared.spend.get("total"), 80);
});

test("given two responses in flight at once, when their chunks interleave, then neither figure lands on the other", () => {
  globalThis.ngx.shared.spend = dict();
  const r1 = { variables: { connection: "h", connection_requests: 1, remote_addr: "10.77.0.10" }, sendBuffer() {} };
  const r2 = { variables: { connection: "i", connection_requests: 1, remote_addr: "10.77.0.11" }, sendBuffer() {} };
  spend.count(r1, streamed[0], { last: false });
  spend.count(r2, plain.slice(0, 40), { last: false });
  spend.count(r1, streamed.slice(1).join(""), { last: true });
  spend.count(r2, plain.slice(40), { last: true });
  assert.equal(ngx.shared.spend.get("10.77.0.10"), 45);
  assert.equal(ngx.shared.spend.get("10.77.0.11"), 35);
});

// An OpenAI-compatible endpoint (DeepSeek among them) reports usage as
// prompt_tokens and completion_tokens: once at the end of a stream, and in
// a plain answer.
const chatPlain = JSON.stringify({
  id: "chatcmpl-1", object: "chat.completion", model: "deepseek-v4-flash",
  choices: [{ index: 0, message: { role: "assistant", content: "Hi" }, finish_reason: "stop" }],
  usage: { prompt_tokens: 12, completion_tokens: 8, total_tokens: 20 },
});

const chatStreamed = [
  'data: {"id":"chatcmpl-2","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}\n\n',
  'data: {"id":"chatcmpl-2","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}\n\n',
  'data: {"id":"chatcmpl-2","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n',
  'data: {"id":"chatcmpl-2","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":40,"completion_tokens":9,"total_tokens":49}}\n\n',
  'data: [DONE]\n\n',
];

test("given a plain chat completion, when it ends, then prompt plus completion tokens are on the address", () => {
  globalThis.ngx.shared.spend = dict();
  respond("10.77.0.2", "k", [chatPlain]);
  assert.equal(ngx.shared.spend.get("10.77.0.2"), 20);
  assert.equal(ngx.shared.spend.get("total"), 20);
});

test("given a streamed chat completion whose usage comes last, when it ends, then that usage is counted", () => {
  globalThis.ngx.shared.spend = dict();
  respond("10.77.0.2", "l", chatStreamed);
  assert.equal(ngx.shared.spend.get("10.77.0.2"), 49);
});

test("given an error answer with no usage, when it ends, then nothing is spent", () => {
  globalThis.ngx.shared.spend = dict();
  respond("10.77.0.10", "j", ['{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}']);
  assert.equal(ngx.shared.spend.get("10.77.0.10"), 0);
  assert.equal(ngx.shared.spend.get("total"), 0);
});

test("given a body, when it passes the filter, then every chunk reaches the client unchanged with its flags", () => {
  globalThis.ngx.shared.spend = dict();
  const sent = respond("10.77.0.10", "k", streamed);
  assert.deepEqual(sent.map(([d]) => d), streamed);
  assert.deepEqual(sent.map(([, f]) => f.last), streamed.map((_, i) => i === streamed.length - 1));
});

test("given a ceiling, when the total reaches it, then over says so, and a ceiling of zero is none", () => {
  globalThis.ngx.shared.spend = dict();
  const at = (ceiling) => spend.over({ variables: { spend_ceiling: String(ceiling) } });
  assert.equal(at(0), "0");
  assert.equal(at(100), "0");
  respond("10.77.0.10", "l", [plain]);
  respond("10.77.0.10", "m", [plain]);
  respond("10.77.0.10", "n", [plain]);
  assert.equal(at(100), "1");
  assert.equal(at(106), "0");
  assert.equal(at(0), "0");
});

test("given counts, when status is asked, then it answers every key as JSON", () => {
  globalThis.ngx.shared.spend = dict();
  respond("10.77.0.10", "o", [plain]);
  let answered;
  const r = { variables: {}, headersOut: {}, return: (code, body) => { answered = [code, body, r.headersOut["Content-Type"]]; } };
  spend.status(r);
  assert.deepEqual(answered, [200, JSON.stringify({ "10.77.0.10": 35, total: 35 }), "application/json"]);
});

test("given two factories, when a server names its zone, then each factory's spend lands in its own dictionary and the other's stays untouched", () => {
  globalThis.ngx.shared.spend_acme = dict();
  globalThis.ngx.shared.spend_widgets = dict();
  const r = (zone, addr, id) => ({ variables: { spend_zone: zone, connection: id, connection_requests: 1, remote_addr: addr, spend_ceiling: "40" }, sendBuffer() {} });
  spend.count(r("spend_acme", "10.77.0.10", "j"), plain, { last: true });
  spend.count(r("spend_widgets", "10.77.1.10", "k"), plain, { last: true });
  spend.count(r("spend_widgets", "10.77.1.10", "l"), plain, { last: true });
  assert.equal(ngx.shared.spend_acme.get("total"), 35);
  assert.equal(ngx.shared.spend_widgets.get("total"), 70);
  assert.equal(spend.over(r("spend_acme", "10.77.0.10", "m")), "0");
  assert.equal(spend.over(r("spend_widgets", "10.77.1.10", "n")), "1");
});
