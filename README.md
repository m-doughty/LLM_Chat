[![Actions Status](https://github.com/m-doughty/LLM_Chat/actions/workflows/test.yml/badge.svg)](https://github.com/m-doughty/LLM_Chat/actions)

LLM::Chat
=========

Simple framework for LLM inferencing in Raku. Supports multiple backends (OpenAI-compatible, KoboldCpp), chat templates (ChatML, Llama 3/4, Mistral, Gemma 2, and any HuggingFace Jinja2 template), conversation management with context shifting, and token counting.

Synopsis
--------

```raku
use LLM::Chat::Backend::KoboldCpp;
use LLM::Chat::Template::ChatML;
use LLM::Chat::Conversation;

my $backend = LLM::Chat::Backend::KoboldCpp.new(
    api_url  => 'http://localhost:5001/v1',
    template => LLM::Chat::Template::ChatML.new,
);

my $conv = LLM::Chat::Conversation.new;
$conv.add-message('user', 'Hello!');

my $response = $backend.text-completion($conv.messages);
```

Templates
---------

### Built-in Templates

```raku
use LLM::Chat::Template::ChatML;
use LLM::Chat::Template::Llama3;
use LLM::Chat::Template::Llama4;
use LLM::Chat::Template::MistralV7;
use LLM::Chat::Template::Gemma2;
use LLM::Chat::Template::DeepSeekV4;

my $template = LLM::Chat::Template::ChatML.new;
```

### DeepSeek V4

DeepSeek V4 publishes a Python message encoder instead of a Jinja chat template. `LLM::Chat::Template::DeepSeekV4` implements the prompt-encoding half of that protocol (not completion parsing):

```raku
use LLM::Chat::Template::DeepSeekV4;

my $template = LLM::Chat::Template::DeepSeekV4.new;
my $prompt = $template.render(@messages);

# Full upstream message shape, retaining JSON member order:
my $prompt = $template.encode-json(
    $messages-json,
    thinking-mode    => 'thinking',
    reasoning-effort => 'high',
);
```

`encode-messages` accepts associative structures and supports context, thinking removal, tools, DSML calls/results, response formats, developer and latest-reminder roles, and quick tasks. `encode-json` is preferable when the exact JSON wire-member order must be reflected in the rendered prompt.

### Jinja2 Templates (HuggingFace)

Load any HuggingFace `chat_template` directly from a `tokenizer_config.json`:

```raku
use LLM::Chat::Template::Jinja2;

# From tokenizer_config.json
my $json = 'tokenizer_config.json'.IO.slurp;
my $template = LLM::Chat::Template::Jinja2.from-tokenizer-config($json);

# Or provide the template string directly
my $template = LLM::Chat::Template::Jinja2.new(
    template  => $jinja2-string,
    bos-token => '<s>',
    eos-token => '</s>',
);
```

The Jinja2 template support is powered by [Template::Jinja2](https://raku.land/zef:apogee/Template::Jinja2), a complete Jinja2 engine for Raku with byte-identical output to Python Jinja2.

Backends
--------

### KoboldCpp

```raku
use LLM::Chat::Backend::KoboldCpp;

my $backend = LLM::Chat::Backend::KoboldCpp.new(
    api_url   => 'http://localhost:5001/v1',
    template  => $template,  # for text completions
    max_tokens => 200,
);
```

KoboldCpp reports a generation that ended on one of your `stop` strings as `finish_reason: "length"` — the same as one that ran out of budget. When a completion finishes with `length`, this backend asks KoboldCpp's `GET /api/extra/perf` why it stopped, and finishes it as `stop` when that was a stop string and the token counts match (or, with no usage to match, are well under `max_tokens`). The wire value stays readable:

```raku
$resp.finish-reason;            # 'stop'
$resp.provider-finish-reason;   # 'length'
$resp.finish-reason-evidence;   # { source, verdict, note, stop_reason, last_token_count, ... }
```

Anything short of a clear answer leaves `length`. The check is bounded (`verify-length-finish-timeout`, 2 seconds) and can be turned off with `verify-length-finish => False`. The rules and their limits are in [LLM::Chat::Backend::KoboldCpp](../lib/LLM/Chat/Backend/KoboldCpp.rakumod).

### OpenAI-compatible

Any OpenAI-compatible API (vLLM, Ollama, etc.):

```raku
use LLM::Chat::Backend::OpenAICommon;

my $backend = LLM::Chat::Backend::OpenAICommon.new(
    api_url => 'http://localhost:8000/v1',
    model   => 'my-model',
);
```

### Message normalization

Some chat templates (Mistral's, among others) refuse any conversation that is not an optional system message followed by strictly alternating user and assistant turns — and llama.cpp or KoboldCpp `--jinja` run the model's own template. Every OpenAI-compatible backend can reshape the outgoing conversation to fit:

```raku
my $backend = LLM::Chat::Backend::KoboldCpp.new(
    api_url               => 'http://localhost:5001/v1',
    message-normalization => 'alternate-roles',   # default 'none'
);
```

Adjacent plain messages of one role merge (contents joined with a blank line), the leading system messages become one, and a system message later in the conversation becomes user text under a `[System message]` marker line, merged into the user turn beside it. Tool calls and tool results are never merged or crossed; a user message straight after tool results, which such a template reads as the user speaking twice, gets an assistant turn in front of it saying `tool-result-acknowledgement` (`'Understood.'`; `''` for none). Nothing is reordered, and the result is a pure function of the messages — a repeated conversation prefix normalizes to the same bytes, so prompt caches keep matching. It applies to the chat paths' `messages` and to the messages the text paths render through their template. The full rules are in [LLM::Chat::Backend::OpenAICommon](../lib/LLM/Chat/Backend/OpenAICommon.rakumod).

### Structured output and field order

Set `json_schema` on the settings to constrain the reply's shape. It goes out as `response_format` on OpenAI-compatible backends and as the native `json_schema` field on KoboldCpp. Servers that compile the schema into a grammar (llama.cpp, KoboldCpp) make the model write an object's fields in the order the schema lists them, and LLM::Chat lists a schema's `properties` in the order of its `required` array, then any optional properties alphabetically — so **the order of `required` is the order the model writes the fields**:

```raku
my $settings = LLM::Chat::Backend::Settings.new(
    json_schema => %(
        type       => 'object',
        properties => %(
            change   => %( type => 'string' ),
            evidence => %( type => 'string' ),
        ),
        required   => [ 'evidence', 'change' ],   # evidence first
    ),
);
```

Every request body is serialized deterministically — the same request is the same bytes on every call and in every process, which also keeps provider prompt caches warm. The full rule, including nested schemas, `$defs` and tool parameters, is in [LLM::Chat::WireJSON](../lib/LLM/Chat/WireJSON.rakumod), which is exported for building prompt text with the same guarantees.

### Mock (for tests)

Canned-response backend for unit and integration tests. Returns pre-configured responses in order, records every call for assertions, and can be scripted to fail on specific calls to exercise retry / fallback paths in downstream consumers.

```raku
use LLM::Chat::Backend::Mock;
use LLM::Chat::Backend::Settings;

my $mock = LLM::Chat::Backend::Mock.new(
    settings  => LLM::Chat::Backend::Settings.new,
    responses => ['first', 'second', 'third'],
    # Optional: script per-call failures by index. Returning a defined
    # hash fails that call; returning Nil proceeds normally.
    error-producer => -> $i {
        when $i == 0 { { class => 'http', status => 503,
                         message => 'bad gateway' } }
        default      { Nil }
    },
    # Optional: script a truncated-but-successful call by index. The
    # call still succeeds with its canned body; the Response just
    # carries finish-reason 'length', the way a real blocking
    # completion reports an exhausted token budget.
    finish-reason-producer => -> $i { $i == 0 ?? 'length' !! Str },
);

my $resp = $mock.chat-completion(@messages);
# $mock.recorded-calls[0]<messages>, <response>, <error>, <call-index>, ...
# $mock.call-index — monotonic counter, bumped on every call
```

See [LLM::Chat::Backend::Mock](../lib/LLM/Chat/Backend/Mock.rakumod) for the full attribute list and recording contract.

Response
--------

Every completion method returns an `LLM::Chat::Backend::Response` (or `::Stream` for streaming calls). Callers poll `.is-done`, read `.msg` on success, and inspect `.err` on failure.

Responses also carry structured error metadata on the failure path so consumers can classify errors without regex-parsing raw messages:

```raku
until $resp.is-done { sleep 0.01 }

if $resp.is-success {
    say $resp.msg;
}
else {
    say "failed: {$resp.err}";
    say "  class:  {$resp.error-class  // '(none)'}";   # 'http' / 'timeout' /
                                                        # 'connection' /
                                                        # 'response' / 'unknown'
    say "  status: {$resp.error-status // '(none)'}";   # HTTP code when
                                                        # error-class eq 'http'
}
```

`error-class` values:

  * `'http'` — HTTP-level error. `error-status` is populated with the code.

  * `'timeout'` — request exceeded the client-side deadline.

  * `'connection'` — network unreachable / connection reset / DNS failure.

  * `'response'` — HTTP succeeded but the body was malformed, empty, or finished with a `'length'` / `'content_filter'` quit.

  * `'unknown'` — catch-all for exceptions that don't classify.

[LLM::Data::Inference::Task](https://raku.land/zef:apogee/LLM::Data::Inference) reads these fields to decide between abort / retry-same / advance in its model-fallback policy — consumers that want the same policy without depending on that module can implement it against the `Response.error-class` / `.error-status` pair directly.

Provider-reported usage is also available on the Response when the backend emits it:

```raku
$resp.prompt-tokens;       # Int, undefined on backends that don't emit usage
$resp.completion-tokens;   # Int
$resp.total-tokens;        # Int
$resp.cached-prompt-tokens;# Int, the cached SLICE of prompt-tokens; undefined
                           # when the provider says nothing about caching
                           # (which is not the same as nothing cached)
$resp.cost;                # Num (credits)
$resp.model-used;          # Str, provider-reported routed model
$resp.provider-id;         # Str, provider-assigned request id
$resp.finish-reason;       # Str ('stop' / 'length' / 'content_filter' / ...)
$resp.provider-finish-reason; # Str, the reason exactly as the wire said it —
                           # differs only when a backend corrected it
$resp.finish-reason-evidence; # Hash, how a backend decided, when it checked
```

### How a stream ends

A streamed generation ends in one of three ways, and every backend built on `LLM::Chat::Backend::OpenAICommon` settles the Response the same way for each:

  * **The provider says it is finished** — `[DONE]`, or a `stop` / `tool_calls` finish reason and then `[DONE]` or a closed body. `.is-done` and `.is-success` are both true.

  * **The provider names a terminal failure** — `length`, `content_filter`, or a reason this library doesn't know. `.is-success` is false, `.error-class` is `'response'`, and `.finish-reason` says which. Note that `length` is a failure: a generation stopped by the completion budget is a truncated one, and it never arrives labelled as a complete answer. The partial text is still on `.latest` / `.msg`, and the usage is on the token counters when the provider sent it.

  * **The body just stops** — no `[DONE]`, no finish reason. A dropped connection, a killed upstream worker, a proxy that gave up. `.is-success` is false with `.error-class` `'response'`; there is no way to tell a reply that was cut off from one that ended.

A finish reason is recorded when it arrives but acted on only when the stream ends, because the usage frame (`stream_options.include_usage`) comes *after* the finish chunk — a stream settled on the finish chunk never reported its token counts. Content after the finish chunk is ignored; a server that sends its finish chunk and then goes quiet is settled after `stream-finish-grace` seconds (default 10) and its connection dropped.

A streamed `data:` line that doesn't parse is skipped rather than fatal, but counted on `.dropped-frames`:

```raku
$resp.dropped-frames;      # Int, 0 unless frames were unparseable
```

If any frames were dropped **while tool calls were being assembled**, the stream fails whatever else happened — tool-call `arguments` are streamed as JSON fragments concatenated blind, so a hole in them can produce valid JSON saying something the model never asked for, and nothing downstream could detect it. Prose-only streams keep their success and leave the counter for the caller to judge.

### Cancelling a generation

There is a fourth way a generation can end that isn't the provider's decision: the caller changes its mind. `cancel` is for that, and it stops the **server** as well as the client.

```raku
my $resp = $backend.chat-completion-stream(@messages);
# ... the user hits escape, or a newer request supersedes this one ...
$backend.cancel($resp);      # or $resp.cancel — same effect

$resp.is-done;               # True, immediately and synchronously
$resp.is-cancelled;          # True
$resp.err;                   # 'Cancelled by user'
$resp.error-class;           # undefined — a cancel is not a failure
$resp.latest;                # whatever had already arrived, kept
```

The OpenAI-compatible protocol has no abort message: a client that no longer wants a completion hangs up, and llama.cpp's server, OpenRouter and the gateways between them stop generating when it does. So `cancel` closes the HTTP connection carrying the generation. Without that it would only quit the local supply — the caller sees nothing more while the model generates, and bills for, the entire reply anyway. On a slow model with a caller that cancels freely, that accumulates abandoned generations nobody will ever read.

Three properties are worth relying on:

  * **The local close is synchronous and unconditional.** The supply is quit before any network work, so a hung or unreachable endpoint cannot delay or prevent the cancel. Tearing down the connection is best-effort and swallows its own errors — safe to call straight from a keybind handler.

  * **A cancel during prefill is not lost.** Before response headers arrive there is nothing to close, and Cro's client offers no handle on a request in flight. The Response remembers that a cancel was asked for and aborts the instant the transport exists, so the abort lands on the first response byte rather than never. Prefill is exactly when a caller gets bored, so this is the common case.

  * **A cancel after the generation finished is a no-op.** A late or duplicate cancel changes nothing; a completed Response keeps `.is-success`.

A cancelled Response is deliberately **not** classified — `.error-class` stays undefined — so a fallback policy reading the Response cannot mistake an abandoned request for a flaky backend and retry it.

`LLM::Chat::Backend::KoboldCpp` additionally sends `POST /api/extra/abort`, which stops a generation still in prefill, before there is a connection to close. Its `cancel` returns the background `Promise` for that POST; it is fire-and-forget and callers may sink it.

Tool Loop
---------

`LLM::Chat::ToolLoop` wraps a streaming backend and runs OpenAI-style tool-call rounds until the model produces a final answer or the safety limits are reached. It is backend-agnostic: pass tools in OpenAI format and an executor callback that returns `role =` "tool"> result hashes.

```raku
use LLM::Chat::ToolLoop;

my @tools = $mcp-server.tools-for-llm;

my $loop = LLM::Chat::ToolLoop.new(
    backend => $backend,
    tools => @tools,
    execute-tools => -> @calls {
        $mcp-server.execute-tool-calls(@calls)
    },
    # Defaults: 4 tool rounds, 12 total calls, 2 identical calls.
);

my $resp = $loop.chat-completion-stream(@messages);
until $resp.is-done { sleep 0.01 }
say $resp.msg if $resp.is-success;
```

For KoboldCpp, use the OpenAI-compatible chat endpoint `http://host:5001/v1`. Streaming tool calls arrive as `delta.tool_calls` chunks and are exposed through `.tool-calls` on the response before the loop executes them.

Retry Policy
------------

`LLM::Chat::Retry` is the shared retry/fallback policy: five pure subs that classify a failure, decide how long to wait, sleep without ignoring a cancel, and build the attempt/telemetry records. Pair it with `LLM::Chat::Retry::Exceptions` for the typed failures a chain throws when it gives up.

```raku
use LLM::Chat::Retry;
use LLM::Chat::Retry::Exceptions;

my @attempts;
my Int $retries-left = 2;

given classify-error(
    error-class  => $resp.error-class,
    error-status => $resp.error-status,
) {
    when 'abort'      { die "config/account error: {$resp.err}" }
    when 'retry-same' {
        my Num $wait = retry-backoff(3 - $retries-left);   # 1s, 2s, 4s ...
        $retries-left--;
        # Returns False the moment &cancelled flips — a cancelled run
        # never sits out a 16-second backoff.
        last unless sleep-with-cancel($wait, :&cancelled);
    }
    default { }   # 'advance' — try the next backend at once
}

@attempts.push: attempt-record(
    backend-index => 0, model => $backend.model, error => "{$resp.err}",
);

X::LLM::Chat::Retry::Exhausted.new(
    :@attempts, summary => 'all backends exhausted',
).throw;
```

Buckets: `'abort'` (HTTP 400/401/402/403/404 — config, account or access errors that repeat identically), `'retry-same'` (5xx, connection drops, anything unclassifiable — usually one upstream provider having a bad minute), `'advance'` (timeout, 429, malformed response, parser failure — model-specific pathologies).

The exception types are `Exhausted`, its subclasses `Truncated` (cut off by `max_tokens`) and `TimedOut` (missed a deadline), and `Cancelled` — which is deliberately **not** an `Exhausted`, so a user pressing Ctrl-C never lands in a dead-letter queue. `Truncated` declares `item-retryable` `False`, the duck-typed advice an orchestration layer reads as `$ex.?item-retryable // True ` before re-running failed work.

[LLM::Data::Inference::Task](https://raku.land/zef:apogee/LLM::Data::Inference) runs on this module, and its own exception types subclass these — so handlers written against either hierarchy match.

Conversation Management
-----------------------

```raku
use LLM::Chat::Conversation;

my $conv = LLM::Chat::Conversation.new;
$conv.add-message('system', 'You are helpful.');
$conv.add-message('user', 'Hello!');
$conv.add-message('assistant', 'Hi there!');

# Access messages
say $conv.messages;
```

Token Counting
--------------

```raku
use LLM::Chat::TokenCounter;

my $counter = LLM::Chat::TokenCounter.new(
    tokenizer => $tokenizer,
    template  => $template,
);

my $conversation-tokens = $counter.get-conversation-count(@messages);

# Exact selected-model request: [context head, messages, context tail],
# including the tool catalogue rendered by the model template.
my $request-tokens = $counter.get-request-count(
    @messages,
    :@tools,
    context-head => $run-context.head-message,
    context-tail => $run-context.tail-message,
);
```

`get-conversation-count` remains useful for stored-conversation and compaction accounting. Use `get-request-count` for a preflight that must match the complete wire prompt for one selected model. Undefined context ends and an empty tool catalogue are omitted without changing template bytes.

Dependencies
------------

  * [Cro::HTTP](Cro::HTTP) — HTTP client for API calls

  * [Template::Jinja2](https://raku.land/zef:apogee/Template::Jinja2) — Jinja2 template engine

  * [Tokenizers](Tokenizers) — HuggingFace tokenizers via Rust FFI

  * [JSON::Fast](JSON::Fast) — JSON parsing

Author
------

Matt Doughty

License
-------

Artistic-2.0

