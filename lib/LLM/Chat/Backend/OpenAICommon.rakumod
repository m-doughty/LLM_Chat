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
=item C<_finalize-request-body>  — last look at the assembled body, after messages / prompt / tools / stream are attached and before it goes on the wire.
=item C<_lift-usage>             — extract usage / model from a response body or stream chunk into the Response.
=item C<make-response>           — factory for non-streaming Response objects (used by C<chat-completion> / C<text-completion>).
=item C<make-stream-response>    — factory for streaming Response objects.
=item C<_on-blocking-complete>   — fires after a non-streaming completion's body has been parsed and lifted, before C<$response.done>. Subclasses use it to attach post-call metadata (e.g. OpenRouter's C</generation> cost lookup).
=item C<_on-stream-complete>     — same hook for the streaming path; fires after C<[DONE]>, before C<$response.done>.

L<LLM::Chat::Backend::OpenRouter> overrides all of these.

C<_blob-text>, C<_body-text>, C<_decode-json-body> and
C<_stream-decoder> are also underscore-prefixed, but as shared
I<internals> rather than override points: they exist so subclasses
making their own HTTP calls (such as OpenRouter's C</generation>
lookup) read response bodies the same way the completion paths do. See
their declarations for why LLM::Chat decodes response bytes itself
instead of using Cro's C<body-text> / C<await .body>, and why a
streamed body needs an incremental decoder rather than a
C<.decode> per chunk.

C<!classify-exception> stays private — it's pure Raku/Cro mapping
with no provider-specific behaviour.

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

=head1 STREAM TERMINATION CONTRACT

A streamed generation can end in exactly three ways, and both
C<chat-completion-stream> and C<text-completion-stream> route every
one of them through the same private C<!settle-stream>, so the
Response a consumer inspects means the same thing whichever method
produced it and whichever provider was on the other end.

=head2 1. The provider says it is finished

Either the C<[DONE]> sentinel arrives, or a C<finish_reason> of
C<stop> / C<tool_calls> does and the body then closes. This is the
success path: C<_on-stream-complete> fires I<first>, then the supply
completes.

    .is-done      True
    .is-success   True
    .finish-reason  'stop' / 'tool_calls' / undefined ([DONE] with no
                    reason chunk — some providers send none)
    .error-class    undefined

=head2 2. The provider names a terminal failure

A C<finish_reason> of C<length> or C<content_filter>, or one this
library does not recognise. The supply is quit where the reason is
read; C<!settle-stream> sees an already-terminal Response and does
nothing.

    .is-done      True
    .is-success   False
    .finish-reason  'length' / 'content_filter' / whatever arrived
    .error-class    'response'
    .err            "Hit max tokens" / "Blocked by content filter" /
                    "Unknown finish reason: ..."

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

=head2 Subclasses

Neither L<LLM::Chat::Backend::OpenRouter> nor
L<LLM::Chat::Backend::KoboldCpp> overrides the streaming methods —
they extend settings, headers, Response shapes and the completion
hooks — so this contract is theirs too. A subclass that did override
a stream loop would have to settle the Response itself; the
straightforward way is to keep the C<react> block's structure and
call C<!settle-stream> the same three places this class does (the
C<[DONE]> arm, a C<stop>-family arm that wants to close early, and
once on the way out of the C<react> block).

=end pod

use LLM::Chat::Backend;
use LLM::Chat::Conversation::Message;
use LLM::Chat::Backend::Response;
use LLM::Chat::Backend::Response::Stream;
use LLM::Chat::Debug;

use Cro::HTTP::Client;
use JSON::Fast;
use UUID::V4;

unit class LLM::Chat::Backend::OpenAICommon is LLM::Chat::Backend;

has Str $.api_url is required;
has Str $.api_key is rw;
has Str $.model   is rw;

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

#|( Best-effort: when a 4xx response triggers an
    X::Cro::HTTP::Error::Client, fetch the response body and write it
    to LLM::Chat::Debug. OpenAI-compatible APIs (OpenRouter included)
    return JSON like C<{"error": {"message": "...", "code": "..."}}>
    on rejection — surfacing that text is the difference between
    "401 Unauthorized" and "your key is rate-limited on this model".
    The body is awaited synchronously inside the caller's start { }
    block; if it's already been drained, malformed, or the await
    itself fails, we silently move on rather than masking the
    original error. Gated on LLM_CHAT_DEBUG like the rest of the
    debug log. )
method !log-error-body($exception) {
	return unless $exception ~~ X::Cro::HTTP::Error::Client;
	my $status = try { $exception.response.status.Int } // 0;
	my $body   = try { self._body-text($exception.response) };
	if $body.defined && $body.chars {
		LLM::Chat::Debug.log("HTTP $status BODY", $body);
	}
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
			my $msg = (.message // '').lc;
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

#|( Bring a streaming Response to its terminal state — the single
    place either streaming path ends.

    Both stream loops reach this from two directions: the C<[DONE]>
    sentinel (C<:saw-done>), and the body stream closing under them,
    which is what a provider that never sends C<[DONE]> looks like
    from here. It decides, in order:

      * B<Already terminal> — a C<length> / C<content_filter> /
        unknown-reason arm has already quit the supply. Nothing to
        do; this is a no-op, which is what makes it safe to call
        unconditionally on the way out of the C<react> block.
      * B<Dropped frames while tool calls were being assembled> —
        fail, error-class C<response>. A hole in a stream of prose
        costs a few words; a hole in a tool call's C<arguments>
        silently changes what the model asked for, and the
        concatenated remains can still be valid JSON. That is
        undetectable corruption downstream, so it never reaches
        C<is-success>. Prose-only streams keep their success and
        expose C<.dropped-frames> for the consumer to judge.
      * B<A clean end> — C<[DONE]>, or a C<stop> / C<tool_calls>
        finish reason with the body then closing. Fires
        C<_on-stream-complete> and completes the supply, in that
        order, so subclass post-stream metadata is readable by the
        time consumers observe C<.is-done>.
      * B<Anything else> — the body closed with neither C<[DONE]>
        nor a finish reason. The generation was cut off in transit
        (dropped connection, killed upstream worker, proxy timeout),
        so it fails with error-class C<response> rather than being
        passed off as a complete reply. Before this existed the
        Response was simply never settled: consumers waiting on
        C<.is-done> waited until their own timeout. )
method !settle-stream(
	LLM::Chat::Backend::Response::Stream $response,
	Bool:D :$saw-done = False,
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

	my $reason = $response.finish-reason // '';
	if $saw-done || $reason eq 'stop' || $reason eq 'tool_calls' {
		self._on-stream-complete($response);
		$response.done;
		return;
	}

	$response._set-error-info(class => 'response');
	$response.quit('Stream closed without [DONE] or a finish reason');
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
		%settings<messages> = @messages.map(*.to-hash).Array;
		%settings<tools> = @tools if @tools.elems > 0;
		%settings = self._finalize-request-body(%settings);

		# Pin HTTP/1.1. Cro defaults to ALPN-negotiated HTTP version
		# for HTTPS, which means it can pick HTTP/2 against gateways
		# that advertise it (OpenRouter does). node-fetch — and
		# therefore SillyTavern, which doesn't see this bug — is
		# HTTP/1.1 only. Cro's HTTP/2 client appears to silently hang
		# waiting for headers against some upstream-routed providers,
		# producing the 60s X::Cro::HTTP::Client::Timeout we've been
		# chasing. Forcing 1.1 brings us into parity with fetch.
		my $client = Cro::HTTP::Client.new:
			:http<1.1>,
			content-type => 'application/json',
			timeout      => self._request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/chat/completions";

		LLM::Chat::Debug.log('REQUEST URL (chat-completion)', $url);
		LLM::Chat::Debug.log-headers('REQUEST HEADERS', self._get-api-headers);
		LLM::Chat::Debug.log-json('REQUEST BODY', %settings);

		my $res = await $client.post:
			$url,
			body    => %settings,
			headers => self._get-api-headers;

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
		my $finish = $choice<finish_reason> // '';
		$response._set-finish-reason($finish);

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
		# way.
		my $reasoning = $choice<message><reasoning> // '';
		$response._append-reasoning($reasoning) if $reasoning.chars;

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
				LLM::Chat::Debug.log('EXCEPTION', "{.^name}: {.message}");
				self!log-error-body($_);
				self!classify-exception($_, $response);
				$response.quit($_.message);
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
		%settings<messages> = @messages.map(*.to-hash).Array;
		%settings<stream> = True;
		%settings<tools> = @tools if @tools.elems > 0;
		%settings = self._finalize-request-body(%settings);

		# Pin HTTP/1.1. Cro defaults to ALPN-negotiated HTTP version
		# for HTTPS, which means it can pick HTTP/2 against gateways
		# that advertise it (OpenRouter does). node-fetch — and
		# therefore SillyTavern, which doesn't see this bug — is
		# HTTP/1.1 only. Cro's HTTP/2 client appears to silently hang
		# waiting for headers against some upstream-routed providers,
		# producing the 60s X::Cro::HTTP::Client::Timeout we've been
		# chasing. Forcing 1.1 brings us into parity with fetch.
		my $client = Cro::HTTP::Client.new:
			:http<1.1>,
			content-type => 'application/json',
			timeout      => self._request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/chat/completions";

		LLM::Chat::Debug.log('REQUEST URL (chat-completion-stream)', $url);
		LLM::Chat::Debug.log-headers('REQUEST HEADERS', self._get-api-headers);
		LLM::Chat::Debug.log-json('REQUEST BODY', %settings);

		my $res = await $client.post:
			$url,
			body             => %settings,
			headers          => self._get-api-headers;

		$response._touch-activity;
		LLM::Chat::Debug.log('HEADERS RECEIVED',
			"+{((now - $start-time) * 1000).Int}ms status={$res.status}");

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
							self!settle-stream($response, :saw-done);
							done;
						}

						my $chunk;
						{
							CATCH {
								default {
									LLM::Chat::Debug.log('SSE PARSE ERROR',
										"line={$line} error={.message}");
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
							$response._set-finish-reason($reason);
							given $reason {
								when 'stop' {
									# Don't close yet — `[DONE]` or a
									# naturally-closed body terminates
									# us, and OpenRouter occasionally
									# emits a final id/provider chunk
									# after finish_reason but before
									# the SSE close.
								}
								when 'tool_calls' {
									# Tool-call deltas are assembled
									# above. Wait for `[DONE]` so the
									# stream closes through the same
									# hook path as normal completions.
								}
								when 'length' {
									$response._set-error-info(class => 'response');
									$response.quit("Hit max tokens");
									done;
								}
								when 'content_filter' {
									$response._set-error-info(class => 'response');
									$response.quit("Blocked by content filter");
									done;
								}
								default {
									$response._set-error-info(class => 'response');
									$response.quit("Unknown finish reason: $reason");
									done;
								}
							}
						}
					}
				}
			}
		}

		# The body stream closed under us. Reached whenever the react
		# block ends without throwing — a `done` from one of the
		# terminal arms above lands here too, and !settle-stream is a
		# no-op once the Response is terminal. What this exists for is
		# the provider that closes the connection without ever sending
		# [DONE]: before it, such a Response was never settled at all,
		# and consumers waiting on .is-done waited out their own
		# timeout.
		self!settle-stream($response);

		CATCH {
			default {
				LLM::Chat::Debug.log('EXCEPTION',
					"+{((now - $start-time) * 1000).Int}ms {.^name}: {.message}");
				self!log-error-body($_);
				self!classify-exception($_, $response);
				$response.quit($_.message);
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
			@messages,
			$continuation,
		);
		%settings = self._finalize-request-body(%settings);

		# Pin HTTP/1.1. Cro defaults to ALPN-negotiated HTTP version
		# for HTTPS, which means it can pick HTTP/2 against gateways
		# that advertise it (OpenRouter does). node-fetch — and
		# therefore SillyTavern, which doesn't see this bug — is
		# HTTP/1.1 only. Cro's HTTP/2 client appears to silently hang
		# waiting for headers against some upstream-routed providers,
		# producing the 60s X::Cro::HTTP::Client::Timeout we've been
		# chasing. Forcing 1.1 brings us into parity with fetch.
		my $client = Cro::HTTP::Client.new:
			:http<1.1>,
			content-type => 'application/json',
			timeout      => self._request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/completions";

		my $res = await $client.post:
			$url,
			body    => %settings,
			headers => self._get-api-headers;

		my $data = self._decode-json-body($res);

		my $msg  = $data<choices>[0]<text>;

		$response.emit($msg);
		$response.done;

		CATCH {
			default {
				LLM::Chat::Debug.log('EXCEPTION', "{.^name}: {.message}");
				self!log-error-body($_);
				self!classify-exception($_, $response);
				$response.quit($_.message);
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
			@messages,
			$continuation,
		);
		%settings<stream> = True;
		%settings = self._finalize-request-body(%settings);

		# Pin HTTP/1.1. Cro defaults to ALPN-negotiated HTTP version
		# for HTTPS, which means it can pick HTTP/2 against gateways
		# that advertise it (OpenRouter does). node-fetch — and
		# therefore SillyTavern, which doesn't see this bug — is
		# HTTP/1.1 only. Cro's HTTP/2 client appears to silently hang
		# waiting for headers against some upstream-routed providers,
		# producing the 60s X::Cro::HTTP::Client::Timeout we've been
		# chasing. Forcing 1.1 brings us into parity with fetch.
		my $client = Cro::HTTP::Client.new:
			:http<1.1>,
			content-type => 'application/json',
			timeout      => self._request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/completions";

		my $res = await $client.post:
			$url,
			body    => %settings,
			headers => self._get-api-headers;

		$response._touch-activity;
		react {
			# Same two-level buffering as chat-completion-stream:
			# $buffer holds an incomplete SSE event back, the decoder
			# holds an incomplete UTF-8 sequence back. See
			# _stream-decoder.
			my Str               $buffer  = '';
			my Encoding::Decoder $decoder = self._stream-decoder;
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
							self!settle-stream($response, :saw-done);
							done;
						}

						my $chunk;
						{
							CATCH {
								default {
									LLM::Chat::Debug.log('SSE PARSE ERROR',
										"line={$payload} error={.message}");
									# See the chat path: skipped, but
									# counted.
									$response._note-dropped-frame;
								}
							}
							$chunk = from-json($payload);
						}
						next without $chunk;

						my $text = $chunk<choices>[0]<text> // "";
						$response.emit($text);

						my $reason = $chunk<choices>[0]<finish_reason> // Nil;
						if $reason.defined {
							# Stamp the reason on the Response BEFORE
							# acting on it — the 'length' /
							# 'content_filter' arms quit the supply,
							# and a consumer inspecting the quit
							# Response must still be able to tell
							# WHICH terminal reason produced it.
							# Mirrors chat-completion-stream.
							$response._set-finish-reason($reason);
							given $reason {
								when 'stop' {
									self!settle-stream($response);
									done;
								}
								when 'length' {
									$response._set-error-info(class => 'response');
									$response.quit("Hit max tokens");
									done;
								}
								when 'content_filter' {
									$response._set-error-info(class => 'response');
									$response.quit("Blocked by content filter");
									done;
								}
								default {
									$response._set-error-info(class => 'response');
									$response.quit("Unknown finish reason: $reason");
									done;
								}
							}
						}
					}
				}
			}
		}

		# Same fall-through as chat-completion-stream: the body closed,
		# for whatever reason, and the Response has to end up somewhere.
		self!settle-stream($response);

		CATCH {
			default {
				LLM::Chat::Debug.log('EXCEPTION', "{.^name}: {.message}");
				self!log-error-body($_);
				self!classify-exception($_, $response);
				$response.quit($_.message);
			}
		}
	}

	return $response;
}

method cancel(LLM::Chat::Backend::Response $resp) {
	$resp.cancel;
}
