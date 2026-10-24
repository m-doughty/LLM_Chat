=begin pod

=head1 NAME

LLM::Chat::Backend::OpenAICommon - Generic OpenAI-compatible chat backend

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Chat::Backend::OpenAICommon;
use LLM::Chat::Backend::Settings;

# Any OpenAI-compatible endpoint (Together, Groq, Fireworks, vLLM,
# llama.cpp's OAI server, ...). For OpenRouter specifically, prefer
# the L<LLM::Chat::Backend::OpenRouter> subclass — it adds the
# attribution headers, body extras, and cost/generation-id lifts.
my $backend = LLM::Chat::Backend::OpenAICommon.new(
    api_url  => 'https://api.together.xyz/v1',
    api_key  => %*ENV<TOGETHER_API_KEY>,
    model    => 'meta-llama/Llama-3.3-70B-Instruct-Turbo',
    settings => LLM::Chat::Backend::Settings.new(:max_tokens(4096)),
);

my $resp = $backend.chat-completion(@messages);
react {
    whenever $resp.supply -> $tok { print $tok }
    whenever $resp.supply.done    { say "done — {$resp.prompt-tokens} in / {$resp.completion-tokens} out" }
}

=end code

=head1 DESCRIPTION

OpenAI-compatible HTTP client. Uses C<Cro::HTTP::Client> against
C</chat/completions> and C</completions> endpoints, lifts the OAI-spec
C<usage> block onto the returned C<Response>, and classifies failures
into the categorical C<error-class> shape the L<LLM::Data::Inference>
fallback policy expects.

=head1 EXTENSION

Provider-specific subclasses extend this class to add wire fields,
headers, or Response shapes that aren't part of the OAI spec. To
keep that path clean, the following internal methods are
underscore-prefixed (rather than C<!>-private) so subclasses can
override them:

=item C<_get-api-settings>       — body params for every request.
=item C<_get-api-headers>        — HTTP headers for every request.
=item C<wire-message-hashes>     — pure chat-message serialization, including the opt-in system-message compatibility mode and L</MESSAGE NORMALIZATION>.
=item C<normalized-messages>     — the Message list the text paths hand their template, normalized the same way.
=item C<_finalize-request-body>  — last look at the assembled body, after messages / prompt / tools / stream are attached and before it goes on the wire.
=item C<_encode-request-body>    — turns the finished body into the exact bytes posted. See L</REQUEST BODY SERIALIZATION>.
=item C<_lift-usage>             — extract usage / model from a response body or stream chunk into the Response.
=item C<_reconcile-finish-reason> — decide which finish reason a completion really ended with, given the provider's. See L</Correcting a provider's finish reason>.
=item C<make-response>           — factory for non-streaming Response objects (used by C<chat-completion> / C<text-completion>).
=item C<make-stream-response>    — factory for streaming Response objects.
=item C<_on-blocking-complete>   — fires after a non-streaming completion's body has been parsed and lifted, before C<$response.done>. Subclasses use it to attach post-call metadata (e.g. OpenRouter's C</generation> cost lookup).
=item C<_on-stream-complete>     — same hook for the streaming path; fires after C<[DONE]>, before C<$response.done>.

=item C<probe-server-limits>     — ask the server for its context size and slot count. See L</REASONING, SLOTS AND SERVER LIMITS>.

L<LLM::Chat::Backend::OpenRouter> overrides the settings, headers,
finalization, lift, factory and completion hooks; it inherits
C<wire-message-hashes> and C<_encode-request-body> unchanged.
L<LLM::Chat::Backend::KoboldCpp> overrides C<_reconcile-finish-reason>
and C<probe-server-limits>.

C<_blob-text>, C<_body-text>, C<_decode-json-body> and
C<_stream-decoder> are also underscore-prefixed, but as shared
I<internals> rather than override points: they exist so subclasses
making their own HTTP calls (such as OpenRouter's C</generation>
lookup) read response bodies the same way the completion paths do. See
their declarations for why LLM::Chat decodes response bytes itself
instead of using Cro's C<body-text> / C<await .body>, and why a
streamed body needs an incremental decoder rather than a
C<.decode> per chunk.

C<_server-root> (the C<api_url> without its C</v1>), C<_probe-json> and
C<_probe-json-array> (one bounded, never-throwing C<GET> of a JSON object
or array there) are shared internals of the same kind, for a subclass's
own server probe.

C<!classify-exception> stays private — it's pure Raku/Cro mapping
with no provider-specific behaviour.

=head1 REASONING, SLOTS AND SERVER LIMITS

Three per-request settings (L<LLM::Chat::Backend::Settings>) go on the
wire only when they are set, so a server that knows none of them sees
the body it always saw:

=item C<reasoning_effort> — the top-level OpenAI field. llama.cpp's
server gives it to the chat template (C<'none'> turns thinking off);
a Mistral Small 4 template takes C<'none'> and C<'high'>.
=item C<reasoning_budget_tokens> — llama.cpp's per-request thinking
budget (it overrides the server's C<--reasoning-budget>; the server
forces the end-of-thinking tag once the budget is spent).
=item C<id_slot> — the llama.cpp slot the request runs on.

=begin code :lang<raku>

my $backend = LLM::Chat::Backend::OpenAICommon.new(
    api_url  => 'http://127.0.0.1:8080/v1',
    settings => LLM::Chat::Backend::Settings.new(
        max_tokens              => 1024 + 2048,  # the answer's room plus the thinking's
        reasoning_effort        => 'high',
        reasoning_budget_tokens => 2048,
        id_slot                 => 1,
    ),
);
my $resp = $backend.chat-completion(@messages);
# ... once it is done:
$resp.msg;              # the answer only
$resp.reasoning-text;   # the thinking, never sent back by this class
$resp.completion-tokens;  # includes the thinking tokens

=end code

The thinking arrives as C<reasoning_content> (C<reasoning> on
OpenRouter), on the final message or in stream deltas, and is kept on
the Response's C<reasoning-text>; it never enters the content, and
nothing here puts it into a later request. It is generated like any
other token, so it counts against C<max_tokens>: raise C<max_tokens> by
the budget you allow. A provider that breaks the count out
(C<usage.completion_tokens_details.reasoning_tokens>) has it lifted
onto C<reasoning-tokens>.

A llama.cpp server keeps each slot's last prompt in KV cache and reuses
the longest prefix the next request on that slot shares with it.
Requests that share a long prefix (the same rules in the same place)
are cache hits when they run on the same slot; left to itself the
server picks a slot by prompt similarity or idleness, and the hits
come and go. C<id_slot> pins them. Pinned requests on one slot run one
after the other.

C<probe-server-limits> asks the server what it runs with: llama.cpp
answers C<GET /props> (C<default_generation_settings.n_ctx> per slot,
and C<total_slots>); L<LLM::Chat::Backend::KoboldCpp> asks
C<GET /api/extra/true_max_context_length>. The result always has
C<source>, then C<context_length> (and C<slots>) or a C<note> saying
why nothing was learnt. It never throws and never takes longer than
C<server-probe-timeout> (3 seconds by default).

=head2 Request-body finalization

C<_get-api-settings> can only describe I<how> to generate — model,
samplers, response format — because it runs before the payload is
attached. Anything that has to look at the conversation itself needs
C<_finalize-request-body>, which every completion path calls with the
finished body just before the POST:

=begin code :lang<raku>

class MyBackend is LLM::Chat::Backend::OpenAICommon {
    # Some gateways bill a "priority" tier per request and want the
    # flag next to the payload rather than in the sampler block.
    method _finalize-request-body(%settings --> Hash) {
        my %out = %settings;
        %out<priority> = 'fast' if (%out<messages> // []).elems > 20;
        %out;
    }
}

=end code

Three rules make an override safe:

=item B<Match the signature exactly.> C«method _finalize-request-body(%settings --> Hash)», character for character. Raku treats a divergent signature as a I<new> method rather than an override, and the parent's no-op keeps answering the call with no error anywhere.
=item B<Return the body.> The caller replaces its body with your return value, so an override that mutates in place and returns something else (the last statement of an C<if>, say) throws the request away.
=item B<Build, don't reach back.> C«%settings<messages>» holds hashes minted by C<LLM::Chat::Conversation::Message.to-hash> for this one request. Rewriting them by constructing new hashes is fine; treating them as a handle on the caller's conversation is not.

Both chat paths and both text paths call it, so an override that only
makes sense for one shape must say so itself — check for
C«%settings<messages>:exists» (chat) or C«%settings<prompt>:exists»
(text) and return the body unchanged otherwise.
L<LLM::Chat::Backend::OpenRouter> does exactly that for its
C<cache_control> breakpoints.

=head1 REQUEST BODY SERIALIZATION

Every request body — chat and text, blocking and streaming, on this
class, L<LLM::Chat::Backend::OpenRouter> and
L<LLM::Chat::Backend::KoboldCpp> — is serialized by LLM::Chat itself and
posted as bytes with C<Content-Type: application/json>. The body is no
longer handed to Cro as a Hash, because a Hash has no member order: the
same request used to go out with its members in a different order on
every call, and that included the JSON Schema of a structured-output
request.

The order is not cosmetic there. llama.cpp and KoboldCpp compile the
schema into a sampling grammar that makes the model write an object's
fields in the order the schema lists them — so the model wrote its
fields in a random order per request, and an application could not ask
for, say, the evidence before the conclusion it supports.

The bytes are now fixed by one rule (full statement and edge cases in
L<LLM::Chat::WireJSON>):

=item B<Arrays keep their order.>
=item B<Every object's members are sorted> by code point (for ASCII names: digits, uppercase, C<_>, lowercase).
=item B<A schema's C<properties> map follows the schema's C<required> array> — required names first, in array order, then the optional properties, sorted. This holds at every depth: nested objects, C<items>, C<$defs>, C<anyOf> / C<oneOf> / C<allOf> branches, tool C<parameters>, C<response_format>'s schema, KoboldCpp's C<json_schema>.
=item B<The conversation is data.> Everything under C<messages> is emitted with sorted members at every depth; nothing in it is ever read as a schema. The values of C<const>, C<default>, C<enum> and C<examples> inside a schema are data in the same way.

So B<the order of C<required> is the order the model writes the
fields>:

=begin code :lang<raku>

my $settings = LLM::Chat::Backend::Settings.new(
    json_schema => %(
        type       => 'object',
        properties => %(
            change   => %( type => 'string' ),
            evidence => %( type => 'string', description => 'verbatim quote' ),
            note     => %( type => 'string' ),
        ),
        # evidence before the change it justifies; note is optional
        required   => [ 'evidence', 'change' ],
    ),
);

# response_format on the wire (one line; wrapped here):
#   {"json_schema":{"name":"response","schema":{"properties":{
#    "evidence":{"description":"verbatim quote","type":"string"},
#    "change":{"type":"string"},"note":{"type":"string"}},
#    "required":["evidence","change"],"type":"object"},"strict":false},
#    "type":"json_schema"}

=end code

Tool definitions get the same treatment, so a tool's C<parameters>
reach the model — and a grammar built from them — in C<required> order
too.

Beyond the order, what changed is only framing: the body is compact
JSON as before, it parses to the same data as before, and the same Hash
now produces the same bytes on every call and in every process — which
is also what lets a provider's prompt cache match a repeated request.
With C<LLM_CHAT_DEBUG> set, the chat paths log the body as those exact
bytes (compact, one line) rather than as a pretty-printed re-rendering,
so a logged request can be replayed as sent.

A subclass that needs different bytes overrides C<_encode-request-body>:

=begin code :lang<raku>

class PrettyWireBackend is LLM::Chat::Backend::OpenAICommon {
    # A debugging proxy that insists on sorted, pretty JSON.
    method _encode-request-body(%body --> Blob:D) {
        to-json(%body, :pretty, :sorted-keys).encode('utf-8');
    }
}

=end code

=head1 MESSAGE NORMALIZATION

Some chat templates accept only one conversation shape: an optional
system message, then user and assistant turns strictly alternating.
Mistral's refuse anything else outright —

    After the optional system message, conversation roles must
    alternate user and assistant roles except for tool calls and
    results.

— and a server that renders the model's own template (llama.cpp, or
KoboldCpp launched with C<--jinja>) passes that refusal straight back.
Applications build conversations that break the rule for good reasons:
input split into several user messages, an instruction appended as a
second user message, a repair packet after a bad reply, a system
message injected mid-conversation. Turn on C<message-normalization>
and the backend reshapes the conversation on the way out:

=begin code :lang<raku>

my $backend = LLM::Chat::Backend::KoboldCpp.new(
    api_url               => 'http://localhost:5001/v1',
    settings              => LLM::Chat::Backend::Settings.new,
    message-normalization => 'alternate-roles',
);

my @messages =
    LLM::Chat::Conversation::Message.new(role => 'system',    content => 'You are terse.'),
    LLM::Chat::Conversation::Message.new(role => 'user',      content => 'Part 1 of the document'),
    LLM::Chat::Conversation::Message.new(role => 'user',      content => 'Part 2 of the document'),
    LLM::Chat::Conversation::Message.new(role => 'assistant', content => 'Summary: ...'),
    LLM::Chat::Conversation::Message.new(role => 'system',    content => 'Reply in JSON.'),
    LLM::Chat::Conversation::Message.new(role => 'user',      content => 'Again, please.');

$backend.wire-message-hashes(@messages);
# [
#   { role => 'system',    content => "You are terse." },
#   { role => 'user',      content => "Part 1 of the document\n\nPart 2 of the document" },
#   { role => 'assistant', content => "Summary: ..." },
#   { role => 'user',      content => "[System message]\nReply in JSON.\n\nAgain, please." },
# ]

=end code

The default, C<'none'>, sends every message as given.

=head2 The rules

Only I<plain> messages take part: C<user>, C<assistant> and C<system>
messages made of a role and text and nothing else. A tool result, an
assistant turn carrying C<tool_calls>, or a message with any other key
is passed through exactly as it is, and nothing is ever merged into or
across it.

=item B<Adjacent plain messages of the same role merge> into one, their
contents joined with a blank line (C<"\n\n">) in their original order.
Two user messages become one user message; two assistant messages
without tool calls become one assistant message; a run of system
messages at the start becomes one system message.

=item B<The leading system message stays where it is.> Everything
before the first non-system message is the leading block, and it is
never rewritten beyond merging it into one message — it is the prefix
every request shares, and rewriting it would change every request.

=item B<A system message after the first turn becomes user text.> Its
content goes out as C<"[System message]\n"> followed by its text (the
marker line is C<folded-system-marker>; set it to C<''> for none), in
the place the system message stood. That text then merges like any
user message: into the user message right after it (as a prefix),
otherwise into the user message right before it (as a suffix),
otherwise it stands as a user turn of its own — between two assistant
turns, or after a tool result. It never moves past another message:
folding it into a I<later> user message across an assistant reply
would reorder the conversation, and would make an earlier request's
messages change when a later one appends to them.

=item B<Tool calls stay whole.> An assistant turn with C<tool_calls>
and the C<tool> results answering it are left as they are, in place.
A user message right after a tool result merges with user messages
after it, never with one before the tool call.

=item B<A user message right after tool results is acknowledged.> Once
the merges and folds above are done, a user message that directly
follows a tool result gets an assistant turn in front of it, with the
fixed text C<tool-result-acknowledgement> (C<'Understood.'>). See
L</Tool results are acknowledged>.

=item B<Nothing is reordered, and no text is dropped.> The one thing
removed is an empty system message, which carries nothing and would
fold into a bare marker line; the one thing added is the
acknowledgement above. An empty user or assistant message is kept:
merged into a same-role neighbour it adds nothing (no stray blank
line), and standing alone it is still a turn, which keeps the roles
alternating. Whitespace is text and is kept verbatim.

=head2 Tool results are acknowledged

A template that checks alternation skips tool turns first — Mistral's
drops every C<tool> message and every assistant turn carrying
C<tool_calls> before it looks — so a user message straight after tool
results reads as the user speaking twice:

    user        What's the weather in Paris?
    assistant   (tool_calls: get_weather)      skipped
    tool        18°C, cloudy                   skipped
    user        And in Rome?                   a second user turn: refused

That conversation comes about whenever the user speaks before the model
has answered the tool results: an application that stops a tool loop to
take new input, or one that appends a user message to a transcript
ending in tool results. The model has read the results; it has just not
said anything since. Normalization says it for the model: one assistant
turn, whose content is C<tool-result-acknowledgement>, goes between the
last tool result and the user message.

=begin code :lang<raku>

my $backend = LLM::Chat::Backend::KoboldCpp.new(
    api_url               => 'http://localhost:5001/v1',
    settings              => LLM::Chat::Backend::Settings.new,
    message-normalization => 'alternate-roles',
);

my %call = id => 'call-1', type => 'function',
    function => %( name => 'get_weather', arguments => '{"city":"Paris"}' );

my @messages =
    LLM::Chat::Conversation::Message.new(role => 'user', content => "What's the weather in Paris?"),
    LLM::Chat::Conversation::Message.new(role => 'assistant', tool-calls => [%call,]),
    LLM::Chat::Conversation::Message.new(role => 'tool', content => '18°C, cloudy', tool-call-id => 'call-1'),
    LLM::Chat::Conversation::Message.new(role => 'user', content => 'And in Rome?');

$backend.wire-message-hashes(@messages).map(*<role>);
# (user assistant tool assistant user)
#                      ^^^^^^^^^ { role => 'assistant', content => 'Understood.' }

=end code

Exactly:

=item A user message directly after a tool result, once merging and
folding are done, gets one acknowledgement in front of it. That user
message may be the caller's own, several merged into one, or a
mid-conversation system message folded into user text (so tool results
followed by a system message then an assistant reply become tool,
acknowledgement, folded user turn, assistant). A user message that
carries more than a role and text is still the user's turn and is
acknowledged the same way. Empty system messages are dropped before
this is decided, and with C<system-message-mode('leading')> the chat
paths have already lifted every system message to the front.

=item A run of tool results gets one acknowledgement, after the last
of them.

=item Nothing is inserted anywhere else. Tool results followed by an
assistant turn — the model's answer, or another tool call — need
nothing, and a conversation that I<ends> in tool results (the usual
request of a tool loop, asking the model to answer them) goes out as it
is.

=item The acknowledgement is the string, verbatim, as a plain
assistant message. It is inserted after every merge has been decided,
so it is never merged with anything, and the tool results, the
tool-call turn and the user message are left exactly as they would be
without it.

=item Set C<tool-result-acknowledgement> to other words, or to C<''>
to insert nothing — the template will then refuse such a conversation.
An undefined value dies when the backend is built.

=head3 Which tool results were acknowledged

A Response carries nothing about the request it was made from, so the
acknowledgements are not reported on it. They are a pure function of
the messages, though, and the acknowledgements are the only difference
between the list normalized with them and the list normalized without
them, each one standing where the list without them has the user
message it precedes. To log them:

=begin code :lang<raku>

my @sent = $backend.normalized-messages(@messages);
my @bare = $backend.clone(tool-result-acknowledgement => '')
                   .normalized-messages(@messages);

my @positions = gather {
    my $b = 0;
    for @sent.kv -> $p, $message {
        if $b < @bare.elems && $message.role eq @bare[$b].role { $b++ }
        else { take $p }
    }
}
# @positions indexes @sent, the messages a text path renders;
# @positions.elems is how many acknowledgements there are.

=end code

The same comparison between two C<wire-message-hashes> calls, reading
C<< .<role> >>, finds them in a chat body.

=head2 Deterministic, and friendly to prompt caches

Normalization is a pure function of the message list: the same
messages always produce the same messages, and so the same bytes (see
L</REQUEST BODY SERIALIZATION>). It is also I<prefix-stable>:
appending messages to a conversation never changes any normalized
message except the last one, and that one only grows — its new
content starts with its old content. So consecutive requests of a
growing conversation repeat each other's bytes up to the previous
request's last message, which is what a provider's prompt cache (or
KoboldCpp's context reuse) needs to match. The last message does grow
when the next request adds a message of its role — a second user
message, a trailing system instruction — so a request that ends on a
user message and is followed by another user message shares its
prefix only up to that message.

Acknowledgements keep this. One is decided by a tool result and the
message after it, and neither changes once both exist. A conversation
that ends in tool results normalizes to a list ending in its last tool
result; append a user message (or a system message, which folds into
one) and the next request repeats that list unchanged, the tool result
included, then carries two new messages: the acknowledgement and the
user message. An acknowledgement is never the last message, so it
never grows, and appending an assistant message after tool results
inserts none.

=head2 What it does not fix

=item A conversation whose first turn after the system message is an
assistant message. Normalization never invents a user message.
=item Assistant text on both sides of a tool call: a plain assistant
message written just before a tool-call turn, then the assistant's
answer after the tool results. A template that skips the tool-call
turn sees two assistant turns in a row. Joining them would mean
merging across the tool call, which is exactly what is not done.

=head2 Where it applies

Both chat paths (C<chat-completion>, C<chat-completion-stream>) on
this class and every subclass normalize the C<messages> they send,
inside C<wire-message-hashes>. With C<system-message-mode('leading')>
as well, the system messages are lifted to the front first, so there is
nothing mid-conversation left to fold, and normalization then merges
what remains.

Both text paths (C<text-completion>, C<text-completion-stream>) render
their prompt from a template on this side of the wire, and a
template — an L<LLM::Chat::Template::Jinja2> running the model's own
chat template, say — enforces the same rule locally. They hand the
template C<normalized-messages(@messages)>: the same normalization, as
C<LLM::Chat::Conversation::Message> objects. The text paths always hand
the template a fresh Array, normalized or not, because several built-in
templates C<pop> the last message when rendering a continuation.

The caller's messages are never modified. L<LLM::Chat::TokenCounter>
counts the conversation as given; with normalization on, the prompt
actually sent differs by the merge delimiters and marker lines.

=head1 STREAM TERMINATION CONTRACT

A streamed generation can end in exactly three ways, and both
C<chat-completion-stream> and C<text-completion-stream> route every
one of them through the same private C<!settle-stream>, so the
Response a consumer inspects means the same thing whichever method
produced it and whichever provider was on the other end.

=head2 The finish chunk is recorded, not acted on

A C<finish_reason> is stamped on the Response (C<.finish-reason> and
C<.provider-finish-reason>) the moment it arrives, and the chunk
carrying it is the last one whose content, reasoning and tool-call
deltas count. The stream is I<not> settled there. It keeps reading
until C<[DONE]> or the body closing, taking only usage and model from
what follows — because that is where the usage is: an OpenAI-style
stream with C<stream_options.include_usage> sends

    data: {"choices":[{"delta":{},"finish_reason":"length"}]}
    data: {"choices":[],"usage":{"prompt_tokens":900,"completion_tokens":64,...}}
    data: [DONE]

and a stream settled at the first line never read the second. Failed
streams — the ones whose token spend a caller most wants to see — used
to arrive with no usage at all, and so did every text stream.

A server that sends its finish chunk and then neither C<[DONE]> nor a
close is given C<stream-finish-grace> seconds (default 10), then
settled on the reason it gave, and its connection is dropped. Without
that bound such a server would hold the Response open for the body's
own timeout, which is unbounded by default.

Which way the stream settles is decided from the finish reason, after
C<_reconcile-finish-reason> has had its say (see
L</Correcting a provider's finish reason>):

=head2 1. The provider says it is finished

Either the C<[DONE]> sentinel arrives with no finish reason sent, or a
C<finish_reason> of C<stop> / C<tool_calls> arrived and then
C<[DONE]> or a close. This is the success path:
C<_on-stream-complete> fires I<first>, then the supply completes.

    .is-done      True
    .is-success   True
    .finish-reason  'stop' / 'tool_calls' / undefined ([DONE] with no
                    reason chunk — some providers send none)
    .error-class    undefined

=head2 2. The provider names a terminal failure

A C<finish_reason> of C<length> or C<content_filter>, or one this
library does not recognise, then C<[DONE]>, a close, or the grace
running out. C<[DONE]> does not rescue it — it only means the server
stopped talking.

    .is-done      True
    .is-success   False
    .finish-reason  'length' / 'content_filter' / whatever arrived
    .error-class    'response'
    .err            "Hit max tokens" / "Blocked by content filter" /
                    "Unknown finish reason: ..."
    .completion-tokens  (and the other usage fields) when the provider
                    sent a usage frame after the finish chunk

Note that C<length> is a I<failure> here. A generation stopped by the
completion budget is a truncated one, and the caller decides whether
a truncated answer is worth keeping — it never arrives labelled as a
complete one. The partial text is still on the Response
(C<.latest> / C<.msg>).

=head2 3. The body just stops

The connection closes with neither C<[DONE]> nor a finish reason: a
dropped connection, a killed upstream worker, a proxy that gave up
mid-stream. There is no way to tell a reply that ended early from one
that ended, so this fails.

    .is-done      True
    .is-success   False
    .finish-reason  undefined
    .error-class    'response'
    .err            'Stream closed without [DONE] or a finish reason'

The important half of this case is that the Response B<settles at
all>. It used to be left unterminated, and every consumer waiting on
C<.is-done> waited out its own timeout instead — minutes, per
occurrence, for a stream that had been over the whole time.

=head2 Cancelling between the finish chunk and the end

A C<cancel> that lands after the finish chunk but before the stream
settles is an ordinary cancel: the Response is cancelled at once, the
connection is dropped, and no finish reason is reconciled for it.
C<.finish-reason> still names the reason that had arrived.

=head2 Correcting a provider's finish reason

Some providers put the wrong reason on the wire. KoboldCpp reports a
stop on a custom stop sequence as C<length>. C<_reconcile-finish-reason>
is the hook for that: it sees every finish reason once, on all four
completion paths — at the settle point on a stream, so the usage frame
has been read by then — and returns the reason the Response should act
on. The default returns the provider's reason unchanged.

=begin code :lang<raku>

class MyGateway is LLM::Chat::Backend::OpenAICommon {
    # This gateway says 'eos' where OpenAI says 'stop'.
    method _reconcile-finish-reason(
        LLM::Chat::Backend::Response $response,
        Str:D $reason,
        %request,
        --> Str:D
    ) {
        $reason eq 'eos' ?? 'stop' !! $reason;
    }
}

=end code

The Response then carries both: C<.finish-reason> is the decided
reason, C<.provider-finish-reason> the one on the wire, and
C<.finish-reason-evidence> whatever the hook recorded about how it
decided. A hook that throws keeps the provider's reason.

=head2 Dropped frames

A C<data:> line that does not parse as JSON is skipped rather than
fatal — providers interleave error fragments and truncated frames
into otherwise healthy streams — but each one bumps
C<Response.dropped-frames>, and that counter changes how the stream
is allowed to end:

=item B<Prose only.> The stream terminates normally, per the three
cases above, and C<.dropped-frames> is left for the consumer to read.
A hole in prose costs a few words and is visible to whoever reads the
reply.

=item B<Tool calls assembled.> The stream fails with error-class
C<response>, whatever else was going on — including a perfectly
well-formed C<[DONE]>. Tool-call C<arguments> are streamed as JSON
fragments that are concatenated blind, so a hole in them produces
either a parse failure or, far worse, valid JSON that says something
the model never asked for. That is corruption no downstream consumer
can detect, so it never reaches C<is-success>.

=head1 CANCELLATION

There is a fourth way a generation can end, and it is not the
provider's decision: the consumer changes its mind. C<cancel> exists
for that, and on an OpenAI-compatible endpoint it has to do something
slightly counter-intuitive — B<close the connection> — because the
protocol has no abort message. A client that stops wanting a completion
hangs up, and llama.cpp's server, OpenRouter and the gateways between
them all stop generating when it does.

=begin code :lang<raku>

my $resp = $backend.chat-completion-stream(@messages);
# ... user hits escape ...
$backend.cancel($resp);      # or $resp.cancel — same thing

$resp.is-done             # True, immediately and synchronously
$resp.is-cancelled        # True
$resp.err                 # 'Cancelled by user'
$resp.error-class         # undefined — a cancel is not a failure
$resp.latest              # whatever had arrived, kept

=end code

What that buys is the difference between a cancel and the appearance of
one. Quitting only the local supply leaves this class's C<react> loop
draining the body to the end: the consumer sees nothing more, and the
model on the other side generates — and bills for — the entire reply
anyway. On a slow model with a consumer that cancels freely (a chat UI
where every re-roll supersedes the last request), that accumulates
zombie generations nobody will ever read.

Three properties are worth relying on:

=item B<The local close is synchronous and unconditional.> C<cancel> quits the supply before it touches the network, so a hung or already-dead endpoint cannot delay or prevent the consumer's cancel. Transport teardown is best-effort and swallows its own errors.
=item B<A cancel during prefill is not lost.> Before response headers arrive there is nothing to close — Cro's client exposes no handle on a request in flight. The Response records that a cancel was asked for and aborts the moment the transport exists, so the abort lands on the first response byte rather than never. This is the common case, not the corner one: prefill is exactly when a user gets bored.
=item B<A cancel after the generation finished is a no-op.> The aborter is dropped when the Response reaches any terminal state, so a late or duplicate cancel quits an already-quit supply and changes nothing — a completed Response keeps C<is-success>.

A cancelled Response is deliberately B<not> classified. Cro reports the
torn-down body as C<X::Cro::HTTP::Client::Timeout(phase => 'body')>,
which is indistinguishable from a genuinely stalled body, and filing it
as C<error-class 'timeout'> would tell a fallback policy to retry the
request the user just abandoned. C<!record-exception> checks
C<Response.cancel-requested> and leaves the terminal state that
C<cancel> already set.

The same mechanism covers deadlines. Cro's C<body> and C<total> request
timeouts cancel the response object themselves, so a request that runs
past C<request-timeout> drops its connection instead of leaving the
server generating into a socket nobody reads.

=head2 Subclasses

Neither L<LLM::Chat::Backend::OpenRouter> nor
L<LLM::Chat::Backend::KoboldCpp> overrides the streaming methods —
they extend settings, headers, Response shapes and the completion
hooks — so this contract is theirs too. A subclass that did override
a stream loop would have to settle the Response itself; the
straightforward way is to keep the C<react> block's structure and
settle in the same three places this class does (the C<[DONE]> arm,
the C<stream-finish-grace> timer, and once on the way out of the
C<react> block), recording a finish reason where it arrives rather
than acting on it there.

=end pod

use LLM::Chat::Backend;
use LLM::Chat::Conversation::Message;
use LLM::Chat::Backend::Response;
use LLM::Chat::Backend::Response::Stream;
use LLM::Chat::Debug;
use LLM::Chat::WireJSON;
use LLM::Chat::ExceptionText;

use Cro::HTTP::Client;
use JSON::Fast;
use UUID::V4;

unit class LLM::Chat::Backend::OpenAICommon is LLM::Chat::Backend;

has Str $.api_url is required;
has Str $.api_key is rw;
has Str $.model   is rw;
has Str $.system-message-mode = 'preserve';
#| Opt in to stream_options.include_usage on streaming requests. Providers
#| that implement the OpenAI usage chunk then populate the Response token
#| counters; the default preserves compatibility with other providers.
has Bool $.request-stream-usage = False;

#|( How the conversation is reshaped before it is sent: C<'none'> (the
    default) sends every message as given; C<'alternate-roles'> merges
    runs of same-role messages, folds mid-conversation system messages
    into user turns and has the assistant acknowledge tool results a
    user message follows, for chat templates that insist on strict
    user/assistant alternation. Applies to the chat paths' C<messages>
    and to the messages the text paths hand their template. See
    L</MESSAGE NORMALIZATION>. )
has Str $.message-normalization = 'none';

#|( Under C<message-normalization('alternate-roles')>, the line put in
    front of a mid-conversation system message's text when it is
    folded into a user turn, so the model can still tell an
    instruction from the user's words. The empty string folds the text
    in with no marker line. )
has Str $.folded-system-marker = '[System message]';

#|( Under C<message-normalization('alternate-roles')>, the text of the
    assistant turn put between tool results and a user message that
    directly follows them, so a template that skips tool turns does not
    see the user speak twice in a row. Inserted verbatim; the empty
    string inserts nothing. See L</Tool results are acknowledged>. )
has Str $.tool-result-acknowledgement = 'Understood.';

#|( Seconds a stream may take, after its finish reason arrives, to
    send C<[DONE]> or close. The usage frame and C<[DONE]> follow the
    finish chunk within milliseconds on every server this targets; a
    server that goes quiet instead is settled on the finish reason it
    gave once this runs out, and its connection is dropped. C<Inf>
    waits for as long as the body does. See
    L</STREAM TERMINATION CONTRACT>. )
has Real $.stream-finish-grace = 10;

#|( Upper bound, in seconds, on C<probe-server-limits> — connection,
    headers and body together. A server that has not answered by then
    is reported as unprobed; the probe never holds its caller longer. )
has Real $.server-probe-timeout = 3;

# Per-phase HTTP timeouts passed to Cro::HTTP::Client. The headers
# phase is when the upstream gateway (OpenRouter, Together, Groq,
# etc.) acknowledges the request with a 200 OK — it happens BEFORE
# any reasoning / content tokens stream over the body, so a long
# headers wait is almost always a queueing or routing stall rather
# than a slow model. 60s is enough grace for any healthy upstream;
# anything longer and the user is waiting for a request that's not
# coming. The body phase stays unbounded so reasoning models that
# take minutes to think still complete cleanly once headers land.
# Callers can override per-backend via C<request-timeout => %( ... )>.
has %.request-timeout = %(
	connection =>  30,
	headers    =>  60,
	body       => Inf,
	total      => 1800,
);

constant HTTP-ERROR-BODY-BYTES = 16 * 1024;
constant HTTP-ERROR-CAPTURE-TIMEOUT = 3;
constant SYSTEM-MESSAGE-MERGE-DELIMITER = "\n\n---\n\n";
# Joins the contents of messages merged by message-normalization.
constant ROLE-MERGE-DELIMITER = "\n\n";

submethod TWEAK() {
	die "OpenAICommon system-message-mode must be 'preserve' or 'leading'"
		unless $!system-message-mode eq 'preserve'
			|| $!system-message-mode eq 'leading';
	die "OpenAICommon message-normalization must be 'none' or "
		~ "'alternate-roles', not '$!message-normalization'"
		unless $!message-normalization eq 'none'
			|| $!message-normalization eq 'alternate-roles';
	die "OpenAICommon stream-finish-grace must be a positive number of "
		~ "seconds or Inf, not {$!stream-finish-grace.raku}"
		unless $!stream-finish-grace.defined
			&& !$!stream-finish-grace.isNaN
			&& $!stream-finish-grace > 0;
	die "OpenAICommon folded-system-marker must be a defined Str "
		~ "(the empty string for no marker)"
		unless $!folded-system-marker.defined;
	die "OpenAICommon tool-result-acknowledgement must be a defined Str "
		~ "(the empty string for no acknowledgement)"
		unless $!tool-result-acknowledgement.defined;
	die "OpenAICommon server-probe-timeout must be a positive, finite "
		~ "number of seconds, not {$!server-probe-timeout.raku}"
		unless $!server-probe-timeout.defined
			&& !$!server-probe-timeout.isNaN
			&& $!server-probe-timeout > 0
			&& $!server-probe-timeout != Inf;
}

method _request-timeout(--> Hash) {
	%!request-timeout.Hash;
}

#|( Decode response bytes as text ourselves rather than letting Cro
    do it.

    Cro asks C<body-text-encoding> for an encoding, and when the
    Content-Type names no charset that method returns the LIST
    C<('utf-8', 'latin-1')> (Cro::HTTP::Message). C<body-text> in
    Cro::MessageWithBody then loops over that list with no C<last>, so
    the latin-1 attempt — which cannot fail, whatever the bytes are —
    always overwrites the successful utf-8 decode. Plenty of
    OpenAI-compatible servers answer C<Content-Type: application/json>
    with no charset parameter, and model output is full of non-ASCII
    (names, curly quotes, emoji, CJK), so every one of those responses
    came back as mojibake: café -> cafÃ©.

    JSON is UTF-8 by definition (RFC 8259 §8.1), so utf-8 is the only
    correct reading of a JSON body. latin-1 survives only as a
    fallback for the non-JSON page a proxy sitting in front of the API
    might answer with, and is reached only when the utf-8 decode
    throws — never in preference to a decode that worked. )
method _blob-text($blob --> Str:D) {
	# Untyped on purpose: C<_body-text>'s caller-side C<try> hands us
	# Nil when the body could not be drained at all, and this is the
	# helper that must never be the thing that throws.
	return '' unless $blob ~~ Blob:D;
	(try $blob.decode('utf-8')) // (try $blob.decode('latin-1')) // '';
}

#|( C<_blob-text> over a whole message, for callers that want text and
    cannot afford to throw. Drains the body stream and decodes it;
    an already-drained, empty, or undecodable body reads as '', so
    callers can test C<.chars> without guarding. )
method _body-text($message --> Str:D) {
	self._blob-text(try await $message.body-blob);
}

#|( Parse a JSON response body, decoding the bytes via C<_blob-text>
    instead of going through C<await $response.body>.

    C<await .body> routes through Cro's response body-parser selector,
    which reaches the correct parser (Cro::HTTP::BodyParser::JSON,
    which decodes utf-8 itself) only while the server labels the body
    C<application/json>. A server that answers JSON as C<text/plain>
    falls through to TextFallback and its mojibake-producing
    C<body-text>; one that sends no Content-Type at all falls through
    to BlobFallback and hands back a Buf that the completion paths
    would then index as a Hash. Reading the bytes here makes the parse
    depend on the payload rather than on a header.

    C<await .body-blob> is left to propagate: a connection dropped
    mid-body must still surface as the transport exception
    C<!classify-exception> can recognise, not as a JSON parse failure.
    A malformed body throws from C<from-json>, exactly as
    C<await .body> did. Both land in the caller's CATCH. )
method _decode-json-body($message) {
	from-json(self._blob-text(await $message.body-blob));
}

#|( A fresh incremental UTF-8 decoder, one per streamed response body.

    The SSE paths cannot use C<_blob-text>: they see the body as a
    Supply of byte chunks whose boundaries are chosen by TCP, and a
    multi-byte character (an emoji, a CJK glyph, a curly quote — model
    output is full of them) is routinely split across two of them.
    C<$chunk.decode('utf-8')> on the half that ends mid-sequence
    THROWS, and since the streaming CATCH classifies and quits, that
    killed the generation mid-flight — intermittently, and only for
    non-ASCII output.

    An C<Encoding::Decoder> is fed bytes and asked for whatever
    characters are complete; an unfinished trailing sequence stays
    inside the decoder until the bytes that finish it arrive. Bytes
    that are not merely incomplete but genuinely invalid still throw,
    exactly as C<.decode> did, and land in the caller's CATCH — a body
    that isn't UTF-8 at all is not a stream we can parse.

    C<:translate-nl(False)> is load-bearing: SSE framing is defined in
    terms of the line endings on the wire (events end at C<\n\n> or
    C<\r\n\r\n>), so a decoder that quietly rewrote CRLF to LF would be
    editing the very bytes the framing reads. )
method _stream-decoder(--> Encoding::Decoder:D) {
	Encoding::Registry.find('utf-8').decoder(:translate-nl(False));
}

#|( Pure serialization of chat messages for an OpenAI-compatible wire body.
    In the default C<preserve> mode this is exactly
    C<@messages.map(*.to-hash)>, returned as detached JSON data. In
    C<leading> mode every system message's content is lifted into one first
    system message, joined in original relative order with
    C<SYSTEM-MESSAGE-MERGE-DELIMITER>; every non-system message remains in
    its original order with its tool-call fields untouched.

    With C<message-normalization('alternate-roles')> the result is then
    normalized as described in L</MESSAGE NORMALIZATION> — after the
    system-message mode, so C<leading> decides where system text goes
    and normalization only merges what is left. Both steps are pure: the
    same messages always produce the same hashes. )
method wire-message-hashes(@messages --> Array:D) {
	my @hashes = @messages.map(-> $message {
		my %hash = from-json(to-json($message.to-hash)).Hash;
		%hash;
	}).Array;
	@hashes = self!normalize-system-messages(@hashes)
		if $!system-message-mode eq 'leading';
	return @hashes unless $!message-normalization eq 'alternate-roles';
	alternate-role-groups(
		@hashes, $!folded-system-marker, $!tool-result-acknowledgement,
	).map(-> %group { group-message-hash(%group) }).Array;
}

#|( The messages the text-completion paths hand their template.

    With C<message-normalization('none')> this is a fresh Array holding
    the very Message objects passed in. With C<'alternate-roles'> the
    list is normalized exactly as C<wire-message-hashes> normalizes a
    chat body (see L</MESSAGE NORMALIZATION>): a message that survives
    untouched is the caller's own Message object, and a merged or
    folded one — or an inserted tool-result acknowledgement — is a new
    C<LLM::Chat::Conversation::Message> carrying only a role and its
    content.

    The Array is always a new one. Several built-in templates C<pop>
    the last message off the list they are given when rendering a
    continuation; handed the caller's own array, they used to remove
    the caller's last message, from a worker thread, while the request
    was in flight. )
method normalized-messages(@messages --> Array:D) {
	return @messages.Array unless $!message-normalization eq 'alternate-roles';
	my @hashes = @messages.map(*.to-hash);
	alternate-role-groups(
		@hashes, $!folded-system-marker, $!tool-result-acknowledgement,
	).map(-> %group {
		%group<rewritten>
			?? LLM::Chat::Conversation::Message.new(
				role    => %group<role>,
				content => %group<parts>.join(ROLE-MERGE-DELIMITER),
			)
			!! @messages[%group<sources>[0]]
	}).Array;
}

#|( Best-effort bounded capture for HTTP error responses. OpenAI-compatible
    APIs return JSON like C<{"error": {"message": "...", "code": "..."} }>
    on rejection; preserving that bounded body on the Response is the
    difference between "500 Internal Server Error" and the provider's
    actionable reason. The capture path never stores headers, auth or the
    request body, and any failure here leaves the primary exception intact. )
method !capture-http-error($exception --> Hash:D) {
	return %() unless $exception ~~ X::Cro::HTTP::Error;
	my $res = try { $exception.response };
	return %( body_available => False, capture_error => 'no-response' )
		unless $res.defined;

	my %out;
	with try { $res.status.Int } -> $status {
		%out<status> = $status;
	}
	with try { $res.header('content-type') } -> $content-type {
		%out<content_type> = self!bounded-str($content-type, 1024);
	}

	my %body = (try self!bounded-body-text($res)) // %(
		available => False,
		truncated => False,
		capture_error => 'body-capture-threw',
	);
	%out<body_available> = ?%body<available>;
	%out<body_bytes> = %body<body_bytes> if (%body<body_bytes>:exists);
	%out<retained_bytes> = %body<retained_bytes> if (%body<retained_bytes>:exists);
	%out<body_truncated> = ?%body<truncated>;
	if %body<text> ~~ Str:D && %body<text>.chars {
		%out<body_text> = %body<text>;
		my $parsed = try from-json(%body<text>);
		if $parsed ~~ Associative:D {
			my %parsed = $parsed.Hash;
			my $error = %parsed<error>;
			if $error ~~ Associative:D {
				my %error = $error.Hash;
				%out<error_message> = self!bounded-str(%error<message>, 1024)
					if %error<message> ~~ Str:D;
				%out<error_type> = self!bounded-str(%error<type>, 256)
					if %error<type> ~~ Str:D;
				%out<error_code> = self!bounded-str(%error<code>, 256)
					if %error<code> ~~ Str:D;
				%out<error_code> = %error<code>.Str
					if !(%out<error_code>:exists)
						&& %error<code> ~~ Numeric:D
						&& %error<code> !~~ Bool:D;
			}
		}
	}
	%out<capture_error> = %body<capture_error> if (%body<capture_error>:exists);
	%out<decode_error> = %body<decode_error> if (%body<decode_error>:exists);
	%out;
}

method !bounded-body-text($message --> Hash:D) {
	return %( available => False, truncated => False, capture_error => 'no-body-stream' )
		unless $message.defined && $message.can('body-byte-stream');

	my @bytes;
	my Int $seen = 0;
	my Bool $truncated = False;
	my Str $capture-error;
	my Bool $closed = False;
	my $lock = Lock.new;
	my $done = Promise.new;
	my $tap;
	my $close = -> {
		my $to-close;
		$lock.protect: {
			$closed = True;
			$to-close = $tap if $tap.defined;
		}
		try $to-close.close if $to-close.defined;
		Nil;
	};
	my $cancel-body = -> {
		if $message.can('cancel') {
			my Bool $cancelled = False;
			try {
				$message.cancel;
				$cancelled = True;
				CATCH { default { } }
			}
			unless $cancelled {
				$lock.protect: {
					$capture-error //= 'response-cancel-failed';
				}
			}
		}
		else {
			$lock.protect: {
				$capture-error //= 'response-cancel-unavailable';
			}
		}
		Nil;
	};
	my $finish = -> {
		$close();
		try $done.keep(True) if $done.status === Planned;
		Nil;
	};
	LEAVE { $close() }
	my $deadline = Promise.in(HTTP-ERROR-CAPTURE-TIMEOUT);
	$tap = $message.body-byte-stream.tap(
		-> $chunk {
			my Bool $must-cancel = False;
			if $chunk !~~ Blob:D {
				$lock.protect: {
					$capture-error = 'non-byte-body-chunk';
				}
				$cancel-body();
				$finish();
			}
			else {
				$lock.protect: {
					unless $closed {
						my Int $chunk-bytes = $chunk.elems;
						my Int $room = HTTP-ERROR-BODY-BYTES - @bytes.elems;
						@bytes.append: $chunk.list.head($room) if $room > 0;
						$seen += $chunk-bytes;
						if $seen > HTTP-ERROR-BODY-BYTES {
							$truncated = True;
							$must-cancel = True;
						}
					}
				}
				if $must-cancel {
					$cancel-body();
					$finish();
				}
			}
		},
		done => -> { $finish() },
		quit => -> $ {
			$lock.protect: {
				$capture-error = 'body-capture-failed';
			}
			$finish();
		},
	);
	my Bool $close-after-assign = $lock.protect: { $closed };
	try $tap.close if $close-after-assign;

	await Promise.anyof($done, $deadline);
	if $done.status === Planned {
		$lock.protect: {
			$truncated = True;
			$capture-error = 'body-capture-timeout';
		}
		$cancel-body();
		$finish();
	}

	my ($blob, $body-bytes, $retained-bytes, $was-truncated, $error) = $lock.protect: {
		my $b = Blob.new(|@bytes);
		($b, $seen, $b.elems, $truncated, $capture-error);
	};
	my %decoded = self!decode-bounded-utf8($blob);
	%(
		available => $retained-bytes > 0,
		body_bytes => $body-bytes,
		retained_bytes => $retained-bytes,
		truncated => $was-truncated,
		text => %decoded<text>,
		|($error.defined ?? (capture_error => $error) !! ()),
		|(%decoded<decode_error>.defined ?? (decode_error => %decoded<decode_error>) !! ()),
	);
}

method !decode-bounded-utf8(Blob:D $blob --> Hash:D) {
	return %( text => '' ) unless $blob.elems;
	my $decoded = try $blob.decode('utf-8');
	return %( text => $decoded ) if $decoded.defined;

	my @bytes = $blob.list;
	for 1 .. 4 -> $drop {
		last if @bytes.elems <= $drop;
		my $prefix = Blob.new(|@bytes.head(@bytes.elems - $drop));
		my $text = try $prefix.decode('utf-8');
		return %(
			text => self!bounded-str($text, HTTP-ERROR-BODY-BYTES - '�'.encode.bytes) ~ '�',
			decode_error => 'utf8-prefix-truncated',
		)
			if $text.defined;
	}
	%( text => '�', decode_error => 'utf8-invalid' );
}

method !bounded-str($value, Int:D $max-bytes --> Str:D) {
	return '' unless $value ~~ Str:D;
	my Str $out = '';
	my Int $bytes = 0;
	for $value.comb -> $char {
		my Int $size = $char.encode.bytes;
		last if $bytes + $size > $max-bytes;
		$bytes += $size;
		$out ~= $char;
	}
	$out;
}

method !provider-error-message($exception, %provider-error --> Str:D) {
	my Str:D $message = exception-text($exception);
	my @parts;
	@parts.push: self!bounded-str(%provider-error<error_message>, 512)
		if %provider-error<error_message> ~~ Str:D
			&& %provider-error<error_message>.chars;
	@parts.push: 'type=' ~ self!bounded-str(%provider-error<error_type>, 128)
		if %provider-error<error_type> ~~ Str:D
			&& %provider-error<error_type>.chars;
	@parts.push: 'code=' ~ self!bounded-str(%provider-error<error_code>, 128)
		if %provider-error<error_code> ~~ Str:D
			&& %provider-error<error_code>.chars;
	@parts.push: 'body=' ~ self!bounded-str(%provider-error<body_text>, 512)
		if !@parts.elems
			&& %provider-error<body_text> ~~ Str:D
			&& %provider-error<body_text>.chars;
	return $message unless @parts.elems;
	$message ~ ' — provider: ' ~ @parts.join(' ');
}

#|( Classify an exception caught during a completion call and record
    the structured error shape on the Response before C<.quit> is
    called. Distinguishes four buckets:
      * C<'http'>       — Cro raised X::Cro::HTTP::Error (4xx/5xx);
                          C<error-status> is populated with the code.
      * C<'timeout'>    — Cro raised X::Cro::HTTP::Client::Timeout in
                          its C<headers> or C<body> phase. The
                          exception class is the only signal — we
                          deliberately do I<not> string-match for
                          "timeout" in arbitrary messages, because
                          unrelated errors (JSON parse failures,
                          stream cancellation messages, etc.) often
                          mention the word and were being misclassified
                          as header timeouts, hiding the real bug.
      * C<'connection'> — socket / DNS failure (connection refused /
                          reset / host unreachable / resolve failure),
                          B<and> a Cro timeout whose phase is
                          C<connection>. The first group is detected
                          heuristically from the message, since Cro
                          surfaces those as plain exceptions from the
                          underlying transport.
      * C<'unknown'>    — catch-all for exceptions that don't match
                          the above patterns.

    B<Why a timeout is split by phase.> Cro tags every
    C<X::Cro::HTTP::Client::Timeout> with the phase it expired in —
    C<connection>, C<headers> or C<body> — and those are not the same
    failure. A C<connection>-phase timeout means the TCP connect never
    completed: nothing was sent, the endpoint said nothing, and the
    only evidence is that the network was unwell for 30 seconds. That
    is transient infrastructure, which is what C<'connection'> means,
    and it retries the same backend after a backoff. A C<headers> or
    C<body> timeout means the endpoint I<did> accept the connection
    and then failed to answer, which is a property of that backend
    worth moving away from — so those keep C<'timeout'>, the advance
    bucket.

    The distinction is load-bearing on a B<one-backend chain>: with
    everything filed as C<'timeout'>, a single flaky connect exhausted
    the chain and killed the run without one retry.

    The Task fallback policy reads these off the Response and decides
    between abort / retry-same / advance without parsing raw messages. )
method !classify-exception($exception, LLM::Chat::Backend::Response $response) {
	given $exception {
		when X::Cro::HTTP::Error {
			my $status = try { .response.status.Int };
			$response._set-error-info(
				class  => 'http',
				status => $status,
			);
		}
		when X::Cro::HTTP::Client::Timeout {
			# `.phase` comes from X::Cro::Policy::Timeout and Cro has
			# always set it at every throw site; the `try` is there so a
			# Cro that ever stopped would degrade to the old, coarser
			# answer rather than throwing from inside a CATCH.
			my $phase = (try .phase) // '';
			$response._set-error-info(
				class => $phase eq 'connection' ?? 'connection' !! 'timeout',
			);
		}
		default {
			my $msg = (exception-message($_) // '').lc;
			if $msg ~~ / :i [ 'connection' | 'refused' | 'reset'
			                | 'unreachable' | 'could not' \s+ 'resolve'
			                | 'dns' | 'network is' | 'no route' ] / {
				$response._set-error-info(class => 'connection');
			}
			else {
				$response._set-error-info(class => 'unknown');
			}
		}
	}
}

#|( Hand a Response the means to terminate its own HTTP exchange.

    Called on every completion path the moment C<await $client.post>
    yields, which is the earliest instant a request becomes abortable at
    all: before response headers there is no C<Cro::HTTP::Response> and
    Cro's client offers no handle on the request in flight. (A cancel
    raised in that window is not lost — C<Response._attach-aborter>
    fires an already-requested abort as soon as the handle exists, so
    the abort lands on the first byte instead of never.)

    C<Cro::HTTP::Response.cancel> is the mechanism, and it is the right
    one for a reason worth writing down: it does not merely stop the
    client reading. It keeps the response's cancellation vow, which
    makes Cro's response parser quit the raw body stream and close its
    own supply, which drops the underlying connection — the server sees
    its next write fail. That is the whole point. Simply closing our tap
    on C<body-byte-stream> would leave Cro draining the body to
    completion on a pooled connection, which is precisely the cosmetic
    cancel this replaced: the consumer stops looking, the model keeps
    generating, and the bill keeps running.

    It is also the same mechanism Cro uses for its own C<body> / C<total>
    request timeouts (C<Promise.in($body-timeout).then: { .cancel }> in
    C<Cro::HTTP::Client>), so a deadline expiring and a consumer
    cancelling now terminate the upstream generation the same way. )
method !attach-aborter(
	LLM::Chat::Backend::Response $response,
	$res,
	--> Nil
) {
	$response._attach-aborter({ $res.cancel });
	Nil;
}

#|( Record an exception raised by a completion path, unless we caused it.

    The single place all four completion paths land their failures, and
    the only place that knows the difference between "the generation
    broke" and "we broke the generation on purpose".

    C<Response.cancel> tears the transport down, and Cro reports that
    torn-down body to the read loop as
    C<X::Cro::HTTP::Client::Timeout(phase => 'body')> — the very
    exception a genuine stalled body raises, because it is the very
    mechanism Cro's own body timeout uses. Classifying it would file a
    deliberate cancel as C<error-class 'timeout'>, which is the advance
    bucket: the consumer's fallback policy would read a cancelled
    generation as a flaky backend and retry the request the user just
    abandoned. So a Response that asked to be cancelled keeps the
    terminal state C<cancel> already gave it, and the wreckage is logged
    rather than diagnosed. )
method !record-exception(
	$exception,
	LLM::Chat::Backend::Response $response,
	Str:D $detail,
	--> Nil
) {
	if $response.cancel-requested {
		LLM::Chat::Debug.log('CANCELLED', $detail);
	}
	else {
		LLM::Chat::Debug.log('EXCEPTION', $detail);
		my %provider-error = (try self!capture-http-error($exception)) // %(
			body_available => False,
			capture_error => 'provider-error-capture-threw',
		);
		try $response._set-provider-error(%provider-error) if %provider-error.elems;
		try self!classify-exception($exception, $response);
		my Str:D $message = (try self!provider-error-message($exception, %provider-error))
			// exception-text($exception);
		$response.quit($message);
	}
	Nil;
}

#|( Bring a streaming Response to its terminal state — the single
    place either streaming path ends.

    Both stream loops reach this from three directions: the C<[DONE]>
    sentinel (C<:saw-done>), the body stream closing under them (which
    is what a provider that never sends C<[DONE]> looks like from
    here), and the C<stream-finish-grace> timer running out on a
    server that went quiet after its finish chunk. It decides, in
    order:

      * B<Already terminal> — a consumer's cancel, or an earlier call
        to this method. Nothing to do; this is a no-op, which is what
        makes it safe to call unconditionally on the way out of the
        C<react> block.
      * B<Dropped frames while tool calls were being assembled> —
        fail, error-class C<response>. A hole in a stream of prose
        costs a few words; a hole in a tool call's C<arguments>
        silently changes what the model asked for, and the
        concatenated remains can still be valid JSON. That is
        undetectable corruption downstream, so it never reaches
        C<is-success>. Prose-only streams keep their success and
        expose C<.dropped-frames> for the consumer to judge.
      * B<A finish reason arrived> — it is put through
        C<_reconcile-finish-reason> first. C<stop> / C<tool_calls>
        fire C<_on-stream-complete> and complete the supply, in that
        order, so subclass post-stream metadata is readable by the
        time consumers observe C<.is-done>. C<length>,
        C<content_filter> and unknown reasons fail the stream,
        error-class C<response>, with the message the finish chunk
        used to raise directly. A C<[DONE]> never overrides a failure
        reason: it only means the server finished talking.
      * B<[DONE] with no finish reason> — a clean end; some providers
        send no reason chunk at all.
      * B<Anything else> — the body closed with neither C<[DONE]>
        nor a finish reason. The generation was cut off in transit
        (dropped connection, killed upstream worker, proxy timeout),
        so it fails with error-class C<response> rather than being
        passed off as a complete reply. Before this existed the
        Response was simply never settled: consumers waiting on
        C<.is-done> waited until their own timeout.

    Deciding here rather than at the finish chunk is what lets a
    failed stream still carry its usage: the usage frame
    (C<stream_options.include_usage>) comes I<after> the finish chunk,
    and a stream quit at the finish chunk never read it. )
method !settle-stream(
	LLM::Chat::Backend::Response::Stream $response,
	Bool:D :$saw-done = False,
	:%request,
	--> Nil
) {
	return if $response.is-done;

	if $response.dropped-frames && $response.has-tool-calls {
		$response._set-error-info(class => 'response');
		$response.quit(
			"Stream dropped {$response.dropped-frames} unparseable "
			~ "frame(s) while assembling tool calls — the assembled "
			~ "arguments cannot be trusted"
		);
		return;
	}

	with $response.finish-reason -> $wire-reason {
		my Str:D $reason = self!apply-finish-reason($response, $wire-reason, %request);
		# A consumer's cancel can land while a subclass's reconcile hook
		# is off asking its server a question; the cancel has settled
		# the Response by then, and it keeps that state.
		return if $response.is-done;
		if $reason eq 'stop' || $reason eq 'tool_calls' {
			self._on-stream-complete($response);
			$response.done;
			return;
		}
		$response._set-error-info(class => 'response');
		$response.quit(finish-failure-message($reason));
		return;
	}

	if $saw-done {
		self._on-stream-complete($response);
		$response.done;
		return;
	}

	$response._set-error-info(class => 'response');
	$response.quit('Stream closed without [DONE] or a finish reason');
	Nil;
}

#|( The error a terminal, non-success finish reason quits a stream
    with. Unchanged wording from when these were raised at the finish
    chunk itself, so consumers matching on C<.err> keep working. )
my sub finish-failure-message(Str:D $reason --> Str:D) {
	given $reason {
		when 'length'         { 'Hit max tokens' }
		when 'content_filter' { 'Blocked by content filter' }
		default               { "Unknown finish reason: $reason" }
	}
}

#|( Stamp a finish reason read off the wire onto the Response, both as
    the working C<finish-reason> and as the verbatim
    C<provider-finish-reason>. )
method !note-finish-reason(
	LLM::Chat::Backend::Response $response,
	Str:D $reason,
	--> Nil
) {
	$response._set-finish-reason($reason);
	$response._set-provider-finish-reason($reason);
	Nil;
}

#|( Settle which finish reason a completion ended with: run the
    C<_reconcile-finish-reason> hook over the provider's reason and
    stamp the answer on the Response. Returns the reason to act on.

    A hook that throws, or returns something that is not a defined
    Str, leaves the provider's reason in force — a diagnostic probe is
    never a reason to fail or re-label a generation. )
method !apply-finish-reason(
	LLM::Chat::Backend::Response $response,
	Str:D $reason,
	%request,
	--> Str:D
) {
	$response._set-provider-finish-reason($reason);
	my $decided;
	{
		CATCH {
			default {
				LLM::Chat::Debug.log('FINISH REASON HOOK FAILED',
					"{.^name}: {exception-message($_) // '(no message)'}");
				$decided = $reason;
			}
		}
		$decided = self._reconcile-finish-reason($response, $reason, %request);
	}
	$decided = $reason unless $decided ~~ Str:D;
	$response._set-finish-reason($decided);
	$decided;
}

#|( Decide which finish reason a completion really ended with, given
    the one the provider sent. The default trusts the provider and
    returns C<$reason> unchanged; a subclass whose provider is known to
    mislabel a stop overrides it.

    Called once per completion that carries a finish reason, on all
    four paths: the blocking ones right after the body is parsed and
    its usage lifted, the streaming ones at the settle point — after
    the usage frame that follows the finish chunk has been read, so
    C<$response.completion-tokens> is populated whenever the provider
    sent it. C<%request> is the request body that was posted
    (C<max_tokens> and all), for comparing against.

    The return value is what the Response acts on: on a stream, C<stop>
    and C<tool_calls> complete it, anything else fails it (see
    L</STREAM TERMINATION CONTRACT>); on every path it becomes
    C<finish-reason>, while the provider's original stays readable as
    C<provider-finish-reason>. Record what the decision was based on
    with C<$response._set-finish-reason-evidence(%evidence)>.

    Runs synchronously on the request's worker thread; anything slow
    here delays C<.is-done>. A throw, or a return that is not a defined
    Str, keeps the provider's reason. The signature must match exactly
    in an override:

        method _reconcile-finish-reason(
            LLM::Chat::Backend::Response $response,
            Str:D $reason,
            %request,
            --> Str:D
        ) { ... }

    L<LLM::Chat::Backend::KoboldCpp> overrides it to recover a stop
    sequence that KoboldCpp reported as C<length>. )
method _reconcile-finish-reason(
	LLM::Chat::Backend::Response $response,
	Str:D $reason,
	%request,
	--> Str:D
) {
	$reason;
}

#|( Drop the connection under a stream that was settled without the
    server closing it — the C<stream-finish-grace> timer ran out after
    the finish chunk. Leaving the C<react> block only closes our tap on
    the body; Cro would otherwise keep reading the connection for as
    long as the server holds it open. The Response's own aborter has
    already been dropped by the settle, so this goes to the Cro
    response directly. Best-effort, like every other teardown here. )
#|( The server root: C<api_url> with the OAI-compat C</v1> suffix (and
    any slashes around it) stripped. llama.cpp's C</props> and
    KoboldCpp's C</api/extra/...> endpoints live there, not under
    C</v1>. )
method _server-root(--> Str:D) {
	$.api_url.subst(/ '/'? 'v1' '/'? $/, '');
}

#|( C<GET> one JSON document from the server root, bounded by
    C<server-probe-timeout>. Returns the parsed reply when it is a JSON
    object; otherwise an empty Hash, after writing what went wrong
    into C<%evidence<note>>. Never throws: a probe that fails is a
    probe that learnt nothing. )
method _probe-json(Str:D $path, %evidence --> Hash:D) {
	my $reply = self!probe-reply($path, %evidence);
	return $reply.Hash if $reply ~~ Associative:D;
	%evidence<note> = "$path reply was not a JSON object" if $reply.defined;
	%();
}

#|( As C<_probe-json>, for a document that is a JSON array: the parsed
    array, or an empty List after writing what went wrong into
    C<%evidence<note>>. )
method _probe-json-array(Str:D $path, %evidence --> List:D) {
	my $reply = self!probe-reply($path, %evidence);
	return $reply.List if $reply ~~ Positional:D;
	%evidence<note> = "$path reply was not a JSON array" if $reply.defined;
	();
}

# The parsed reply of one bounded GET, or Any with %evidence<note> saying
# why there is none.
method !probe-reply(Str:D $path, %evidence --> Mu) {
	my $limit = $!server-probe-timeout;
	my $url = self._server-root ~ $path;
	my %headers = self._get-api-headers;
	my $work = start {
		# One request, so not persistent: see chat-completion.
		my $client = Cro::HTTP::Client.new:
			:!persistent,
			:http<1.1>,
			timeout => %(
				connection => $limit,
				headers    => $limit,
				body       => $limit,
				total      => $limit,
			);
		my $res = await $client.get: $url, headers => %headers;
		self._decode-json-body($res);
	};
	# Cro's `total` should end the call on time; the outer deadline is
	# there so nothing about the transport can hold the caller longer.
	await Promise.anyof($work, Promise.in($limit));
	given $work.status {
		when Kept {
			my $reply = $work.result;
			return $reply if $reply.defined;
			%evidence<note> = "$path reply was empty";
		}
		when Broken {
			my $cause = $work.cause;
			%evidence<note> = "$path request failed: {$cause.^name}: "
				~ ((exception-message($cause) // '(no message)').lines.head // '');
		}
		default {
			%evidence<note> = "$path request did not answer within {$limit}s";
		}
	}
	Any;
}

#|( Ask the server how large a context it runs, and how many parallel
    slots it has, where the server says. Returns a Hash that always
    has C<source> (the endpoint asked, or C<'none'>) and then either
    C<context_length> (tokens, per slot) — plus C<slots> when the
    server reports its slot count — or C<note>, saying why nothing
    was learnt. Bounded by C<server-probe-timeout>; never throws.

    This class asks llama.cpp's server: C<GET /props>, reading
    C<default_generation_settings.n_ctx> (a top-level C<n_ctx> is also
    accepted) and C<total_slots>; when C</props> gives no slot count,
    C<GET /slots> does (one entry per slot; C<slots_source> says which
    answered, and C<slots_note> why neither did). The C<n_ctx> there is
    the context of one slot: with C<--kv-unified> every slot may use the
    whole pool, so C<-c 524288 -np 4 --kv-unified> reports 524,288. Any other OpenAI-compatible server answers C</props>
    with an error or a document without those fields, and the probe
    says so in C<note>. L<LLM::Chat::Backend::KoboldCpp> asks
    KoboldCpp's own endpoint instead; L<LLM::Chat::Backend::OpenRouter>
    asks nothing.

        my %limits = $backend.probe-server-limits;
        with %limits<context_length> -> $n {
            say "server context: $n tokens ({%limits<source>})";
        }
        else {
            say "unknown: %limits<note>";
        }

    A model can advertise more context than it was trained to use,
    and a server can be started with more or less than either; what
    to do with the number is the caller's decision. )
method probe-server-limits(--> Hash:D) {
	my %evidence = source => 'llama.cpp:/props';
	my %props = self._probe-json('/props', %evidence);
	return %evidence unless %props.elems;
	my $settings = %props<default_generation_settings>;
	my $n-ctx = $settings ~~ Associative:D ?? $settings<n_ctx> !! Any;
	$n-ctx = %props<n_ctx> unless $n-ctx.defined;
	unless $n-ctx ~~ Int:D && $n-ctx > 0 {
		%evidence<note> = '/props reports no positive integer n_ctx';
		return %evidence;
	}
	%evidence<context_length> = $n-ctx.Int;
	if %props<total_slots> ~~ Int:D && %props<total_slots> > 0 {
		%evidence<slots> = %props<total_slots>.Int;
		%evidence<slots_source> = '/props';
		return %evidence;
	}
	my %slots-evidence;
	my @slots = self._probe-json-array('/slots', %slots-evidence);
	if @slots.elems {
		%evidence<slots> = @slots.elems;
		%evidence<slots_source> = '/slots';
	}
	else {
		%evidence<slots_note> = %slots-evidence<note> // '/slots lists no slots';
	}
	%evidence;
}

method !abandon-transport($res --> Nil) {
	{
		CATCH {
			default {
				LLM::Chat::Debug.log('ABANDON FAILED',
					"{.^name}: {exception-message($_) // '(no message)'}");
			}
		}
		$res.cancel;
	}
	Nil;
}

#|( Build the request body shared across all completion calls.
    Subclasses override to add provider-specific extras (e.g.
    OpenRouter's C<include_reasoning>) — call C<callsame> first,
    then mutate the returned hash.

    C<repetition_penalty> is gated on the caller having set a
    non-default value: the OAI spec doesn't define this field, so
    sending it always made some upstreams (notably OpenRouter routes)
    behave unexpectedly. C<top_k> is sent unconditionally because every
    OAI-compatible endpoint we target either honours it or quietly
    ignores it. )
method _get-api-settings(--> Hash) {
	my $s = self.settings;
	my %r;

	%r<model>              = $!model if $!model.defined;
	%r<max_tokens>         = $s.max_tokens;
	%r<temperature>        = $s.temperature;
	%r<top_p>              = $s.top_p;
	%r<top_k>              = $s.top_k;
	%r<presence_penalty>   = $s.presence_pen;
	%r<frequency_penalty>  = $s.frequency_pen;
	%r<stop>               = $s.stop.Array;

	%r<repetition_penalty> = $s.repetition_pen
		if $s.repetition_pen.defined && $s.repetition_pen != 1.0;

	# Reasoning and slot pinning go out only when asked for, so an
	# endpoint that knows neither sees exactly the body it always saw.
	# `reasoning_effort` is the OpenAI field (llama.cpp hands it to the
	# chat template); `reasoning_budget_tokens` and `id_slot` are
	# llama.cpp's own. See L<LLM::Chat::Backend::Settings>.
	%r<reasoning_effort>        = $s.reasoning_effort        if $s.reasoning_effort.defined;
	%r<reasoning_budget_tokens> = $s.reasoning_budget_tokens if $s.reasoning_budget_tokens.defined;
	%r<id_slot>                 = $s.id_slot                 if $s.id_slot.defined;

	# Structured outputs: OpenAI-style response_format wrapper around
	# the caller-supplied JSON Schema. strict => False deliberately —
	# strict mode demands exhaustive additionalProperties/required
	# annotations and narrows provider routing; shape guidance plus
	# caller-side parse validation is the contract here.
	with $s.json_schema {
		%r<response_format> = %(
			type        => 'json_schema',
			json_schema => %(
				name   => $s.json_schema_name,
				strict => False,
				schema => $s.json_schema,
			),
		);
	}

	return %r;
}

#|( Last-chance rewrite of a fully-assembled request body.
    C<_get-api-settings> runs I<before> the payload is attached, so it
    can only add sampler-level fields; this hook runs after
    C<messages> / C<prompt> / C<tools> / C<stream> are all in place
    and immediately before the POST, which makes it the only place a
    subclass can shape the request as a whole — annotate messages,
    reorder them, drop a field for one provider, and so on.

    Fires on all four completion paths (chat and text, blocking and
    streaming) with the body about to be sent. Returns the body to
    send; the default returns its argument untouched, so vanilla
    OAI-compatible endpoints see exactly the bytes they saw before
    the hook existed.

    Implementations must be pure with respect to everything upstream
    of them. The C<messages> array holds hashes freshly built by
    C<LLM::Chat::Conversation::Message.to-hash>, but the Message
    objects themselves are the caller's conversation state — rewrite
    by building new hashes, never by reaching back through them:

        method _finalize-request-body(%settings --> Hash) {
            return %settings unless %settings<messages>:exists;

            my %out = %settings;
            %out<messages> = %settings<messages>.map(-> %m {
                %m<role> eq 'system' ?? %( |%m, name => 'sys' ) !! %m
            }).Array;
            %out;
        }

    The signature has to match this one exactly in an override.
    A mismatched one is not an override at all — Raku installs it as
    a separate candidate and the parent's no-op keeps winning the
    dispatch, silently. )
method _finalize-request-body(%settings --> Hash) {
	%settings;
}

#|( Serialize a finished request body to the exact bytes that go on the
    wire: compact UTF-8 JSON from L<LLM::Chat::WireJSON>'s
    C<to-wire-json>, with the C<messages> member treated as data. Every
    object's members are sorted, except a JSON Schema property map,
    which follows its schema's C<required> order — see
    L</REQUEST BODY SERIALIZATION>.

    All four completion paths call this once, after
    C<_finalize-request-body>, and post the returned bytes as the body
    with C<Content-Type: application/json>. The same Hash always
    produces the same bytes, in any process.

    An override must return the complete body as UTF-8 bytes, and must
    match this signature exactly — a divergent signature is a separate
    method, and this one keeps answering. )
method _encode-request-body(%body --> Blob:D) {
	to-wire-json(%body, :data-members<messages>).encode('utf-8');
}

method !with-stream-usage-request(%settings --> Hash) {
	return %settings unless $!request-stream-usage;
	return %settings unless (%settings<stream>:exists) && %settings<stream>.so;

	my %out = %settings;
	my %stream-options = (%out<stream_options> ~~ Associative:D)
		?? %out<stream_options>.Hash
		!! %();
	%stream-options<include_usage> = True;
	%out<stream_options> = %stream-options;
	%out;
}

method !normalize-system-messages($messages --> Array:D) {
	my @systems;
	my @non-system;
	for $messages.list -> $message {
		if $message ~~ Associative:D {
			my %message = $message.Hash;
			if (%message<role> // '') eq 'system' {
				my $content = %message<content>;
				@systems.push: $content if $content ~~ Str:D;
				next;
			}
			@non-system.push: %message;
			next;
		}
		@non-system.push: $message;
	}
	return $messages.Array unless @systems.elems;
	[
		%(role => 'system', content => @systems.join(SYSTEM-MESSAGE-MERGE-DELIMITER)),
		|@non-system,
	]
}

#|( True for a message that is nothing but a role and its text: a
    C<user>, C<assistant> or C<system> hash with no key besides C<role>
    and C<content>, and string (or absent) content. Only these take
    part in C<alternate-roles> normalization. Anything else — a tool
    result (C<tool_call_id>), an assistant turn carrying C<tool_calls>,
    a message some subclass decorated with extra keys — is passed
    through exactly as it is and is never merged with anything, because
    merging it would have to drop or reconcile data it carries. )
my sub plain-message($message --> Bool:D) {
	return False unless $message ~~ Associative:D;
	my %message = $message.Hash;
	my $role = %message<role>;
	return False unless $role ~~ Str:D
		&& ($role eq 'user' || $role eq 'assistant' || $role eq 'system');
	return False if %message.keys.first({ $_ ne 'role' && $_ ne 'content' }).defined;
	my $content = %message<content>;
	!$content.defined || $content ~~ Str:D;
}

#|( True for a group holding a tool result: a message passed through
    as it is whose role is C<tool>. )
my sub tool-result-group(%group --> Bool:D) {
	return False if %group<plain>;
	my $message = %group<message>;
	$message ~~ Associative:D && ($message<role> // '') eq 'tool';
}

#|( True for a group that goes out as a user message: a plain user
    message (the caller's, a merged run, or system text folded into
    user text), or a user message passed through as it is because it
    carries more than a role and text. A template counts either as the
    user's turn. )
my sub user-group(%group --> Bool:D) {
	return %group<role> eq 'user' if %group<plain>;
	my $message = %group<message>;
	$message ~~ Associative:D && ($message<role> // '') eq 'user';
}

#|( The C<alternate-roles> normalization, as a pure function of the
    message list. Returns one group per outgoing message, in order:

        { role, plain, message, parts, sources, rewritten, acknowledgement }

    C<sources> lists the input indexes the group was built from;
    C<rewritten> is False only for a group that is a single input
    message passed through untouched (C<message> is then that input).
    C<acknowledgement> is True only for an assistant turn inserted
    between tool results and the user message after them; it has no
    C<sources> and its one part is C<$acknowledgement>. Acknowledgements
    are inserted after every merge and fold has been decided, so one is
    never merged with anything. The empty C<$acknowledgement> inserts
    none. The rules — and why they keep a repeated prefix
    byte-identical — are in L</MESSAGE NORMALIZATION>. )
my sub alternate-role-groups(
	@messages, Str:D $marker, Str:D $acknowledgement --> Array:D
) {
	# Everything before the first non-system message is the leading
	# system block; a system message after it is mid-conversation.
	my Int $first-turn = @messages.first(
		{ !($_ ~~ Associative:D) || ($_<role> // '') ne 'system' },
		:k,
	) // @messages.elems;

	my @groups;
	for @messages.kv -> Int $index, $message {
		my Bool $plain = plain-message($message);
		my Str  $role  = $plain ?? $message<role>.Str !! '';
		my Str  $text  = $plain ?? ($message<content> // '').Str !! '';
		my Bool $rewritten = False;

		if $plain && $role eq 'system' {
			# An empty system message carries nothing: there is no text
			# to keep and nothing to fold, and a bare marker line would
			# be noise the caller never wrote.
			next unless $text.chars;
			if $index > $first-turn {
				$role      = 'user';
				$text      = $marker.chars ?? "$marker\n$text" !! $text;
				$rewritten = True;
			}
		}

		my $last = @groups.elems ?? @groups.tail !! Nil;
		if $plain && $last.defined && $last<plain> && $last<role> eq $role {
			# Empty text joins nothing: merged into a neighbour, an empty
			# turn adds no stray delimiter.
			$last<parts>.push($text) if $text.chars;
			$last<sources>.push($index);
			$last<rewritten> = True;
		}
		else {
			@groups.push: %(
				role            => $role,
				plain           => $plain,
				message         => $message,
				parts           => ($text.chars ?? [$text] !! []),
				sources         => [$index],
				rewritten       => $rewritten,
				acknowledgement => False,
			);
		}
	}
	return @groups unless $acknowledgement.chars;

	# A template that skips tool turns — Mistral's drops every tool
	# result and every assistant turn carrying tool calls before it
	# checks alternation — sees a user message straight after tool
	# results as the user speaking twice. The assistant answers the
	# tool results first. Only the pair (tool result, user message)
	# decides this, and neither ever changes once both exist, so the
	# acknowledgement appears exactly when the user message does and
	# never moves or changes afterwards.
	my @out;
	for @groups -> %group {
		@out.push: %(
			role            => 'assistant',
			plain           => True,
			message         => Nil,
			parts           => [$acknowledgement],
			sources         => [],
			rewritten       => True,
			acknowledgement => True,
		) if @out.elems && tool-result-group(@out.tail) && user-group(%group);
		@out.push: %group;
	}
	@out;
}

#|( The wire hash for one C<alternate-role-groups> group: the input
    message itself when it passed through untouched, otherwise a fresh
    C<{ role, content }>. )
my sub group-message-hash(%group --> Hash:D) {
	return %group<message>.Hash unless %group<rewritten>;
	%(
		role    => %group<role>,
		content => %group<parts>.join(ROLE-MERGE-DELIMITER),
	);
}

#|( Build the request headers shared across all completion calls.
    Subclasses override to add provider-specific headers (e.g.
    OpenRouter's C<HTTP-Referer> / C<X-Title> attribution) — call
    C<callsame> first, then add to the returned hash. )
method _get-api-headers(--> Hash) {
	my %h;
	%h<Authorization> = "Bearer {$!api_key}" if $!api_key.defined;
	return %h;
}

#|( Factory for the non-streaming Response object returned by
    C<chat-completion> / C<text-completion>. Subclasses override
    to return a provider-specific Response subclass (e.g.
    C<LLM::Chat::Backend::Response::OpenRouter>). )
method make-response(--> LLM::Chat::Backend::Response) {
	LLM::Chat::Backend::Response.new(id => uuid-v4());
}

#|( Factory for the streaming Response object returned by
    C<chat-completion-stream> / C<text-completion-stream>.
    Subclasses override to return a provider-specific streaming
    Response subclass. )
method make-stream-response(--> LLM::Chat::Backend::Response::Stream) {
	LLM::Chat::Backend::Response::Stream.new(id => uuid-v4());
}

#|( Lift the OAI-spec C<usage> block + top-level C<model> off a
    parsed response body (or a single stream chunk) into the
    Response object. Every extraction is presence-guarded so missing
    keys leave Response attrs undefined — callers read
    C<.prompt-tokens.defined> to distinguish "unknown" from "zero".
    Idempotent on repeated calls with the same chunk, so streaming
    can invoke this per-chunk without worrying about stomping
    already-set values.

    Subclasses override to lift provider-specific extras: call
    C<callsame> first to handle the OAI-spec fields, then pull any
    extras off C<$payload> into the provider's Response subclass. )
method _lift-usage($response, $payload) {
	return unless $payload ~~ Associative;
	my %args;
	if $payload<usage>:exists && $payload<usage> ~~ Associative {
		my %u = $payload<usage>;
		%args<prompt>     = %u<prompt_tokens>     if %u<prompt_tokens>:exists;
		%args<completion> = %u<completion_tokens> if %u<completion_tokens>:exists;
		%args<total>      = %u<total_tokens>      if %u<total_tokens>:exists;

		# Cache telemetry. The OAI spec nests it one level down, under
		# `usage.prompt_tokens_details.cached_tokens`, and every
		# OAI-compatible provider that reports prompt caching uses that
		# name — so this belongs here rather than on a provider
		# subclass. Doubly guarded: the details block is absent on most
		# calls, and providers that send it sometimes send it with a
		# null `cached_tokens` (which must stay "unreported", not 0).
		if %u<prompt_tokens_details> ~~ Associative {
			my %d = %u<prompt_tokens_details>;
			%args<cached-prompt> = %d<cached_tokens>
				if %d<cached_tokens>:exists && %d<cached_tokens>.defined;
		}

		# Thinking tokens, when the provider breaks them out
		# (`usage.completion_tokens_details.reasoning_tokens`, the OAI
		# name). They are a SUBSET of completion_tokens, like cached
		# tokens are of prompt_tokens; undefined means unreported.
		if %u<completion_tokens_details> ~~ Associative {
			my %d = %u<completion_tokens_details>;
			%args<reasoning> = %d<reasoning_tokens>
				if %d<reasoning_tokens>:exists && %d<reasoning_tokens>.defined;
		}
	}
	%args<model> = $payload<model> if $payload<model>:exists
	                               && $payload<model>.defined
	                               && $payload<model>.Str.chars;
	$response._set-usage(|%args) if %args.elems;
}

method chat-completion(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	:@tools,
	--> LLM::Chat::Backend::Response
) {
	my $response = self.make-response;

	start {
		my %settings = self._get-api-settings;
		%settings<messages> = self.wire-message-hashes(@messages);
		%settings<tools> = @tools if @tools.elems > 0;
		%settings = self._finalize-request-body(%settings);
		%settings = self!with-stream-usage-request(%settings);

		# Pin HTTP/1.1. Cro defaults to ALPN-negotiated HTTP version
		# for HTTPS, which means it can pick HTTP/2 against gateways
		# that advertise it (OpenRouter does). node-fetch — and
		# therefore SillyTavern, which doesn't see this bug — is
		# HTTP/1.1 only. Cro's HTTP/2 client appears to silently hang
		# waiting for headers against some upstream-routed providers,
		# producing the 60s X::Cro::HTTP::Client::Timeout we've been
		# chasing. Forcing 1.1 brings us into parity with fetch.
		#
		# Not persistent, either: this client serves one request and is
		# then dropped. A persistent client keeps the connection in its
		# own pool once the response is in — a pool nothing draws on or
		# closes again — so every request used to leave a socket open for
		# the life of the process, and a long session or a busy batch ran
		# out of file descriptors. A client that is not persistent asks
		# the server to close the connection after the response
		# (Connection: close).
		my $client = Cro::HTTP::Client.new:
			:!persistent,
			:http<1.1>,
			content-type => 'application/json',
			timeout      => self._request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/chat/completions";

		my Blob:D $body = self._encode-request-body(%settings);

		LLM::Chat::Debug.log('REQUEST URL (chat-completion)', $url);
		LLM::Chat::Debug.log-headers('REQUEST HEADERS', self._get-api-headers);
		LLM::Chat::Debug.log-bytes('REQUEST BODY', $body);

		my $res = await $client.post:
			$url,
			body    => $body,
			headers => self._get-api-headers;

		self!attach-aborter($response, $res);

		my $data = self._decode-json-body($res);
		LLM::Chat::Debug.log-json('RESPONSE BODY (chat-completion)', $data);

		# Usage + routed-model metadata lifted before touching
		# choices, so a malformed choices[] doesn't shadow otherwise-
		# good telemetry. Presence-gated: absent keys stay Nil on
		# Response and propagate as "unknown" to the sink. Dispatches
		# through subclass overrides so provider-specific extras
		# (e.g. OpenRouter's cost / generation-id) get lifted too.
		self._lift-usage($response, $data);

		my $choice = $data<choices>[0];
		my Str $finish = ($choice<finish_reason> // '').Str;
		$response._set-finish-reason($finish);
		# After _lift-usage on purpose: a reconcile hook compares the
		# provider's reason against the usage it reported.
		$finish = self!apply-finish-reason($response, $finish, %settings)
			if $finish.chars;

		if $finish eq 'tool_calls' && $choice<message><tool_calls>.defined {
			$response._set-tool-calls($choice<message><tool_calls>.list);
			# Also capture any content the model produced alongside tool calls
			my $msg = $choice<message><content> // '';
			$response.emit($msg);
		} else {
			my $msg = $choice<message><content> // '';
			$response.emit($msg);
		}

		# Non-streaming reasoning lands on the final message rather
		# than on per-chunk deltas. Capture it here for parity with
		# the stream path so callers can read .reasoning-text either
		# way. OpenRouter names it `reasoning`; llama.cpp and
		# KoboldCpp name it `reasoning_content`.
		my $reasoning = $choice<message><reasoning> // $choice<message><reasoning_content> // '';
		$response._append-reasoning($reasoning.Str) if $reasoning.defined && $reasoning.Str.chars;

		# Hook fires before $response.done so any subclass-supplied
		# post-call metadata (e.g. OpenRouter's /generation cost
		# lookup, which is the only place blocking-path callers can
		# pick up usage.cost since we no longer ask for it inline)
		# is populated by the time consumers see the final body.
		# See _on-blocking-complete docs.
		self._on-blocking-complete($response);
		$response.done;

		CATCH {
			default {
				self!record-exception($_, $response,
					"{.^name}: {exception-message($_) // '(no message)'}");
			}
		};
	}

	return $response;
}

method chat-completion-stream(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	:@tools,
	--> LLM::Chat::Backend::Response::Stream
) {
	my $response = self.make-stream-response;

	start {
		my $start-time = now;
		my %settings = self._get-api-settings;
		%settings<messages> = self.wire-message-hashes(@messages);
		%settings<stream> = True;
		%settings<tools> = @tools if @tools.elems > 0;
		%settings = self._finalize-request-body(%settings);
		%settings = self!with-stream-usage-request(%settings);

		# Pin HTTP/1.1. Cro defaults to ALPN-negotiated HTTP version
		# for HTTPS, which means it can pick HTTP/2 against gateways
		# that advertise it (OpenRouter does). node-fetch — and
		# therefore SillyTavern, which doesn't see this bug — is
		# HTTP/1.1 only. Cro's HTTP/2 client appears to silently hang
		# waiting for headers against some upstream-routed providers,
		# producing the 60s X::Cro::HTTP::Client::Timeout we've been
		# chasing. Forcing 1.1 brings us into parity with fetch. Not
		# persistent: see chat-completion.
		my $client = Cro::HTTP::Client.new:
			:!persistent,
			:http<1.1>,
			content-type => 'application/json',
			timeout      => self._request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/chat/completions";

		my Blob:D $body = self._encode-request-body(%settings);

		LLM::Chat::Debug.log('REQUEST URL (chat-completion-stream)', $url);
		LLM::Chat::Debug.log-headers('REQUEST HEADERS', self._get-api-headers);
		LLM::Chat::Debug.log-bytes('REQUEST BODY', $body);

		my $res = await $client.post:
			$url,
			body             => $body,
			headers          => self._get-api-headers;

		self!attach-aborter($response, $res);

		$response._touch-activity;
		LLM::Chat::Debug.log('HEADERS RECEIVED',
			"+{((now - $start-time) * 1000).Int}ms status={$res.status}");

		# Set when the grace timer, not the server, ended the stream:
		# the connection is still open and must be dropped.
		my Bool $abandoned = False;
		react {
			# Buffer SSE bytes across TCP chunk boundaries, at two
			# levels. SSE events end with a blank line ("\n\n" /
			# "\r\n\r\n"); a single `data: {...}` JSON object can be
			# split across multiple body-byte-stream emissions, so
			# $buffer holds an incomplete event back until it is whole
			# (parsing each emission independently made from-json throw
			# on the truncated half). The split can just as easily land
			# inside a multi-byte character, which no amount of
			# character-level buffering can recover from — the decode
			# throws before $buffer ever sees the text — so the bytes
			# go through an incremental decoder that holds the
			# unfinished sequence itself. See _stream-decoder.
			my Bool              $first-byte-seen = False;
			my Str               $buffer          = '';
			my Encoding::Decoder $decoder         = self._stream-decoder;
			# Set by the first finish_reason. From then on a chunk is
			# read for usage only — see the finish-reason arm below.
			my Bool              $finished        = False;
			whenever $res.body-byte-stream -> $data {
				$response._touch-activity;
				unless $first-byte-seen {
					$first-byte-seen = True;
					LLM::Chat::Debug.log('FIRST BODY BYTE',
						"+{((now - $start-time) * 1000).Int}ms bytes={$data.elems}");
				}
				$decoder.add-bytes($data);
				$buffer ~= $decoder.consume-available-chars;
				my @events = $buffer.split(/\n\n | \r\n\r\n/);
				$buffer = @events.pop;   # incomplete tail held back

				for @events -> $event {
					for $event.lines -> $raw-line {
						my $clean = $raw-line.trim;
						# SSE comment lines start with ":" — heartbeats
						# like `: OPENROUTER PROCESSING` keep the
						# connection alive and carry no data. Skip them
						# silently per spec.
						next if $clean.starts-with(':');
						next unless $clean.starts-with('data:');

						my $line = $clean.substr(5).trim;
						# `data:` with nothing after it carries no
						# data by definition. Skipped BEFORE the
						# parser, so it is not counted as a dropped
						# frame — that counter can fail a tool-call
						# stream, and a keep-alive must never do that.
						next unless $line.chars;
						LLM::Chat::Debug.log('SSE LINE', $line);
						if $line eq '[DONE]' {
							# Terminal states all go through
							# !settle-stream — including the hook /
							# .done ordering. See its docs for the
							# full contract.
							self!settle-stream($response, :saw-done, :request(%settings));
							done;
						}

						my $chunk;
						{
							CATCH {
								default {
									LLM::Chat::Debug.log('SSE PARSE ERROR',
										"line={$line} error={exception-text($_)}");
									# Skip malformed chunks; OR
									# occasionally interleaves error
									# fragments mid-stream that aren't
									# our problem to surface as fatals.
									# Counted, though: a hole in a
									# tool call's arguments is not
									# survivable the way a hole in
									# prose is, and !settle-stream
									# fails the stream over it.
									$response._note-dropped-frame;
								}
							}
							$chunk = from-json($line);
						}
						next without $chunk;

						# Usage chunks arrive as the terminal
						# frame (choices=[] + usage populated);
						# also snag model / id off the first
						# chunk that carries them. Subclass
						# override (e.g. OpenRouter) lifts any
						# provider-specific extras alongside.
						self._lift-usage($response, $chunk);

						# The finish chunk is the last word on the
						# reply; what follows it (the include_usage
						# frame, OpenRouter's trailing id/provider
						# chunk) is metadata, lifted above and read
						# for nothing else.
						next if $finished;

						my $choice = $chunk<choices>[0] // {};
						my $delta-payload = $choice<delta> ~~ Associative
							?? $choice<delta>
							!! {};

						if $delta-payload<tool_calls>:exists
						&& $delta-payload<tool_calls> ~~ Positional {
							$response._append-tool-call-deltas(
								$delta-payload<tool_calls>.list
							);
						}

						my $delta = $delta-payload<content>:exists
							?? ($delta-payload<content> // "")
							!! "";
						$response.emit($delta) if $delta.chars;

						# Reasoning trace, when the model emits
						# one. Accumulated separately from the
						# content supply so consumers that just
						# want the visible reply still get a
						# clean stream.
						my $reasoning = '';
						if $delta-payload<reasoning>:exists {
							$reasoning = $delta-payload<reasoning> // '';
						} elsif $delta-payload<reasoning_content>:exists {
							$reasoning = $delta-payload<reasoning_content> // '';
						}
						$response._append-reasoning($reasoning) if $reasoning.chars;

						my $reason = $choice<finish_reason> // Nil;
						if $reason.defined {
							# Recorded, not acted on. Whatever the
							# reason — stop, tool_calls, length,
							# content_filter, one we don't know — the
							# stream is settled by [DONE], the body
							# closing, or the grace timer, all through
							# !settle-stream. Quitting here, as the
							# failure reasons used to, dropped the
							# usage frame that comes next.
							$finished = True;
							self!note-finish-reason($response, $reason.Str);
							# A server that says it is finished and then
							# neither sends [DONE] nor closes gets
							# stream-finish-grace seconds, not the
							# body's own (unbounded) timeout.
							if $!stream-finish-grace != Inf {
								whenever Promise.in($!stream-finish-grace) {
									LLM::Chat::Debug.log('STREAM FINISH GRACE EXPIRED',
										"no [DONE] or close {$!stream-finish-grace}s after "
										~ "finish_reason {$response.finish-reason}");
									$abandoned = True;
									self!settle-stream($response, :request(%settings));
									done;
								}
							}
						}
					}
				}
				# The body closed. End the react now rather than when
				# the grace timer, if one is running, fires.
				LAST { done }
			}
		}

		# The body stream closed under us, or [DONE] / the grace timer
		# ended the react. !settle-stream is a no-op once the Response
		# is terminal. What this exists for is the provider that closes
		# the connection without ever sending [DONE]: before it, such a
		# Response was never settled at all, and consumers waiting on
		# .is-done waited out their own timeout.
		self!settle-stream($response, :request(%settings));
		self!abandon-transport($res) if $abandoned;

		CATCH {
			default {
				self!record-exception($_, $response,
					"+{((now - $start-time) * 1000).Int}ms {.^name}: "
					~ (exception-message($_) // '(no message)'));
			}
		};
	}

	return $response;
}

#|( Hook called when a streaming response naturally completes
    (`[DONE]` received, or `finish_reason: stop` for text completions).
    Fires I<before> C<$response.done>, so any subclass-supplied
    metadata (e.g. OpenRouter's /generation cost lookup) is readable
    by the time consumers observe C<.is-done = True>.

    Hooks run synchronously inside the streaming worker's C<start { }>
    block — blocking the main reactor isn't a concern, but anything
    that takes much over ~200 ms here will visibly delay
    C<.is-done> for the consumer. Hooks should swallow their own
    exceptions; an unhandled throw will land in the caller's CATCH
    and be classified as a generic stream failure.

    Default is a no-op for vanilla OAI-compatible endpoints. )
method _on-stream-complete(LLM::Chat::Backend::Response::Stream $response) {
	# No-op — subclasses (e.g. OpenRouter) override.
}

#|( Hook called when a non-streaming chat-completion successfully
    completes — body parsed, usage / generation-id lifted onto the
    Response by C<_lift-usage>. Fires I<before> C<$response.done>,
    so any subclass-supplied post-call metadata (e.g. OpenRouter's
    C</generation> cost lookup, which is the only place a blocking
    caller can pick up C<usage.cost> since we no longer ask for it
    inline) is readable by the time consumers observe the final
    body.

    Symmetric counterpart to C<_on-stream-complete>: same contract,
    same timing, same exception handling — runs synchronously inside
    the request worker's C<start { }> block, hooks swallow their own
    exceptions, an unhandled throw lands in the caller's CATCH and
    is classified as a generic failure.

    Default is a no-op for vanilla OAI-compatible endpoints. )
method _on-blocking-complete(LLM::Chat::Backend::Response $response) {
	# No-op — subclasses (e.g. OpenRouter) override.
}

method text-completion(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	Bool $continuation = False,
	--> LLM::Chat::Backend::Response
) {
	my $response = self.make-response;

	unless (self.template.defined) {
		$response._set-error-info(class => 'unknown');
		$response.quit("Must define template in backend to use text completion");

		return $response;
	}

	start {
		my %settings = self._get-api-settings;
		my $template = self.template;
		%settings<prompt> = $template.render(
			self.normalized-messages(@messages),
			$continuation,
		);
		%settings = self._finalize-request-body(%settings);
		%settings = self!with-stream-usage-request(%settings);

		# Pin HTTP/1.1. Cro defaults to ALPN-negotiated HTTP version
		# for HTTPS, which means it can pick HTTP/2 against gateways
		# that advertise it (OpenRouter does). node-fetch — and
		# therefore SillyTavern, which doesn't see this bug — is
		# HTTP/1.1 only. Cro's HTTP/2 client appears to silently hang
		# waiting for headers against some upstream-routed providers,
		# producing the 60s X::Cro::HTTP::Client::Timeout we've been
		# chasing. Forcing 1.1 brings us into parity with fetch. Not
		# persistent: see chat-completion.
		my $client = Cro::HTTP::Client.new:
			:!persistent,
			:http<1.1>,
			content-type => 'application/json',
			timeout      => self._request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/completions";

		my Blob:D $body = self._encode-request-body(%settings);

		my $res = await $client.post:
			$url,
			body    => $body,
			headers => self._get-api-headers;

		self!attach-aborter($response, $res);

		my $data = self._decode-json-body($res);

		# Usage and the finish reason, as on the chat path. This path
		# used to read the text and nothing else, so a blocking text
		# completion never reported token counts or why it stopped.
		self._lift-usage($response, $data);
		my $choice = $data<choices>[0];
		with $choice<finish_reason> -> $reason {
			self!note-finish-reason($response, $reason.Str);
			self!apply-finish-reason($response, $reason.Str, %settings);
		}

		my $msg  = $choice<text>;

		$response.emit($msg);
		$response.done;

		CATCH {
			default {
				self!record-exception($_, $response,
					"{.^name}: {exception-message($_) // '(no message)'}");
			}
		};
	}

	return $response;
}

method text-completion-stream(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	Bool $continuation = False,
	--> LLM::Chat::Backend::Response::Stream
) {
	my $response = self.make-stream-response;

	unless self.template.defined {
		$response._set-error-info(class => 'unknown');
		$response.quit("Must define template in backend to use text completion stream");
		return $response;
	}

	start {
		my %settings = self._get-api-settings;
		my $template = self.template;
		%settings<prompt> = $template.render(
			self.normalized-messages(@messages),
			$continuation,
		);
		%settings<stream> = True;
		%settings = self._finalize-request-body(%settings);
		%settings = self!with-stream-usage-request(%settings);

		# Pin HTTP/1.1. Cro defaults to ALPN-negotiated HTTP version
		# for HTTPS, which means it can pick HTTP/2 against gateways
		# that advertise it (OpenRouter does). node-fetch — and
		# therefore SillyTavern, which doesn't see this bug — is
		# HTTP/1.1 only. Cro's HTTP/2 client appears to silently hang
		# waiting for headers against some upstream-routed providers,
		# producing the 60s X::Cro::HTTP::Client::Timeout we've been
		# chasing. Forcing 1.1 brings us into parity with fetch. Not
		# persistent: see chat-completion.
		my $client = Cro::HTTP::Client.new:
			:!persistent,
			:http<1.1>,
			content-type => 'application/json',
			timeout      => self._request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/completions";

		my Blob:D $body = self._encode-request-body(%settings);

		my $res = await $client.post:
			$url,
			body    => $body,
			headers => self._get-api-headers;

		self!attach-aborter($response, $res);

		$response._touch-activity;
		my Bool $abandoned = False;
		react {
			# Same two-level buffering as chat-completion-stream:
			# $buffer holds an incomplete SSE event back, the decoder
			# holds an incomplete UTF-8 sequence back. See
			# _stream-decoder.
			my Str               $buffer   = '';
			my Encoding::Decoder $decoder  = self._stream-decoder;
			# As in chat-completion-stream: after the first finish
			# reason a chunk is read for usage only, and a server that
			# then goes quiet is dropped after stream-finish-grace.
			my Bool              $finished = False;
			whenever $res.body-byte-stream -> $data {
				$response._touch-activity;
				$decoder.add-bytes($data);
				$buffer ~= $decoder.consume-available-chars;
				my @events = $buffer.split(/\n\n | \r\n\r\n/);
				$buffer = @events.pop;

				for @events -> $event {
					for $event.lines -> $raw-line {
						my $clean = $raw-line.trim;
						next if $clean.starts-with(':');
						next unless $clean.starts-with('data:');

						my $payload = $clean.substr(5).trim;
						# See chat-completion-stream: an empty data
						# line is a keep-alive, not frame loss.
						next unless $payload.chars;
						if $payload eq '[DONE]' {
							# Was `.done` BEFORE the hook here — the
							# opposite of the documented contract and
							# of what the chat path does, so a
							# subclass's post-stream metadata landed
							# after consumers had already seen
							# .is-done. !settle-stream owns the
							# ordering now.
							self!settle-stream($response, :saw-done, :request(%settings));
							done;
						}

						my $chunk;
						{
							CATCH {
								default {
									LLM::Chat::Debug.log('SSE PARSE ERROR',
										"line={$payload} error={exception-text($_)}");
									# See the chat path: skipped, but
									# counted.
									$response._note-dropped-frame;
								}
							}
							$chunk = from-json($payload);
						}
						next without $chunk;

						self._lift-usage($response, $chunk);
						next if $finished;

						my $text = $chunk<choices>[0]<text> // "";
						$response.emit($text);

						my $reason = $chunk<choices>[0]<finish_reason> // Nil;
						if $reason.defined {
							# Recorded, not acted on — see
							# chat-completion-stream. This arm used to
							# settle on `stop` and quit on everything
							# else right here, which lost the usage
							# frame on every text stream, successful
							# or not.
							$finished = True;
							self!note-finish-reason($response, $reason.Str);
							if $!stream-finish-grace != Inf {
								whenever Promise.in($!stream-finish-grace) {
									LLM::Chat::Debug.log('STREAM FINISH GRACE EXPIRED',
										"no [DONE] or close {$!stream-finish-grace}s after "
										~ "finish_reason {$response.finish-reason}");
									$abandoned = True;
									self!settle-stream($response, :request(%settings));
									done;
								}
							}
						}
					}
				}
				LAST { done }
			}
		}

		# Same fall-through as chat-completion-stream: the body closed,
		# for whatever reason, and the Response has to end up somewhere.
		self!settle-stream($response, :request(%settings));
		self!abandon-transport($res) if $abandoned;

		CATCH {
			default {
				self!record-exception($_, $response,
					"{.^name}: {exception-message($_) // '(no message)'}");
			}
		}
	}

	return $response;
}

#|( Abandon an in-flight generation, on the wire as well as locally.

    A thin delegate on purpose. There is no OAI-spec abort endpoint to
    call — the OpenAI-compatible protocol says a client that no longer
    wants a completion closes the connection, and llama.cpp's server,
    OpenRouter and the gateways in between all stop generating when it
    does. C<Response.cancel> owns both halves of that (quit the local
    supply, then run the aborter this class registered with the
    Cro response), which also means a consumer holding only the Response
    can cancel correctly without reaching back for the backend.

    Contrast L<LLM::Chat::Backend::KoboldCpp>, which overrides this to
    B<add> an explicit C<POST /api/extra/abort> on top: KoboldCpp does
    have an abort endpoint, and it stops a generation that is mid-prefill
    — before there is a response to close. )
method cancel(LLM::Chat::Backend::Response $resp) {
	$resp.cancel;
}
