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

my $template = LLM::Chat::Template::ChatML.new;
```

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

### OpenAI-compatible

Any OpenAI-compatible API (vLLM, Ollama, etc.):

```raku
use LLM::Chat::Backend::OpenAICommon;

my $backend = LLM::Chat::Backend::OpenAICommon.new(
    api_url => 'http://localhost:8000/v1',
    model   => 'my-model',
);
```

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
$resp.cost;                # Num (credits)
$resp.model-used;          # Str, provider-reported routed model
$resp.provider-id;         # Str, provider-assigned request id
$resp.finish-reason;       # Str ('stop' / 'length' / 'content_filter' / ...)
```

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
    tokenizer-path => 'path/to/tokenizer.json',
    template       => $template,
);

my $count = $counter.count-messages(@messages);
```

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

