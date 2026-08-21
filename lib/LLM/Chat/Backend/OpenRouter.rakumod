=begin pod

=head1 NAME

LLM::Chat::Backend::OpenRouter - OpenRouter-specific chat backend

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Chat::Backend::OpenRouter;
use LLM::Chat::Backend::Settings;

my $backend = LLM::Chat::Backend::OpenRouter.new(
    api_key  => %*ENV<OPENROUTER_API_KEY>,
    model    => 'anthropic/claude-opus-4-7',
    settings => LLM::Chat::Backend::Settings.new(:max_tokens(8192)),

    # Optional attribution headers — let your app appear on the
    # OpenRouter rankings page and in users' generation logs.
    http-referer => 'https://example.com/my-app',
    x-title      => 'My App',
);

my $resp = $backend.chat-completion(@messages);
react {
    whenever $resp.supply -> $tok { print $tok }
    whenever $resp.supply.done {
        say "cost: \${$resp.cost // 0}";
        say "served by: {$resp.provider-name // 'unknown'}";
        say "lookup: /generation?id={$resp.generation-id}" if $resp.generation-id.defined;
    }
}

=end code

=head1 DESCRIPTION

Subclass of L<LLM::Chat::Backend::OpenAICommon> that wires in
OpenRouter-specific behaviour without touching the generic
OpenAI-compatible code path:

=item Sends C<include_reasoning: True> + C<top_k> on every request,
      mirroring the body shape SillyTavern sends to OpenRouter. Adds
      C<reasoning: { effort: ... }> when C<settings.reasoning_effort>
      is set, again following SillyTavern's shape. Does I<not> send
      C<usage: { include: true }> or C<stream_options: { include_usage: true }>
      — those caused intermittent header-phase hangs against some
      upstream providers (DeepSeek-V3.2 mostly fine, others ~80 % fail).
=item Marks up to three C<cache_control> breakpoints on outgoing chat
      bodies (controlled by C<$.cache-breakpoints>, on by default) so
      providers that cache explicitly can reuse the prompt prefix
      between rounds — see B<Prompt caching> below.
=item Adds C<HTTP-Referer> / C<X-Title> attribution headers when
      C<:http-referer> / C<:x-title> are configured. (See
      L<https://openrouter.ai/docs/api-reference/overview#headers>.)
=item Returns L<LLM::Chat::Backend::Response::OpenRouter> /
      L<LLM::Chat::Backend::Response::OpenRouter::Stream> so
      callers can read C<.cost>, C<.generation-id>,
      C<.provider-name>, and C<.is-byok>.
=item Lifts those fields off the response body / stream chunks via
      C<_lift-usage> (calls C<callsame> first to handle OAI-spec).
=item After a completion finishes — streaming or blocking — fires a
      one-shot GET against C</generation?id=...> to populate
      C<.cost> / C<.provider-name> from OpenRouter's metadata
      endpoint. Replaces the inline C<usage.cost> we used to ask for
      via C<usage: { include: true }>; lookup is best-effort, so a
      failure leaves C<.cost> Nil rather than erroring the call.
      Wired in via the C<_on-stream-complete> /
      C<_on-blocking-complete> hooks that the parent class fires
      before C<$response.done>, so consumers see populated cost
      metadata by the time the response is observably done on
      either path.

Everything else — request shape, error classification, fallback /
retry interaction, streaming mechanics, cancel — is inherited
unchanged from C<OpenAICommon>.

=head2 Prompt caching

A long-running conversation re-sends its whole history every round,
and the input bill is the bulk of what that costs. Providers will
serve a repeated prefix out of cache at a fraction of the price —
some (OpenAI, DeepSeek, Moonshot, Z.AI, Grok) do it implicitly, and
some (Anthropic, Qwen, Gemini) only when the request says where the
reusable prefix ends, with a C<cache_control> marker on a
content-parts block.

This backend places those markers itself, on the head message and on
the last two C<user> / C<assistant> turns, so the marker written one
round ago still covers everything the next request shares with it:

=begin code :lang<raku>

# On by default — nothing to configure for the common case.
my $backend = LLM::Chat::Backend::OpenRouter.new(
    api_key => %*ENV<OPENROUTER_API_KEY>,
    model   => 'anthropic/claude-opus-4-7',
);

# Off: messages go on the wire as plain `content => 'text'` strings,
# byte for byte what earlier releases sent.
my $plain = LLM::Chat::Backend::OpenRouter.new(
    api_key           => %*ENV<OPENROUTER_API_KEY>,
    model             => 'anthropic/claude-opus-4-7',
    cache-breakpoints => False,
);

=end code

Implicit-caching routes ignore the markers, so the flag can stay on
across a mixed model fleet. Conversation state is untouched either
way — the rewrite happens on the serialized request body, so
C<Message.get-checksum> is unaffected by where a breakpoint landed.

Read the payoff back off the Response: C<.cached-prompt-tokens> is
the cached slice of C<.prompt-tokens> when the provider reports one.

=begin code :lang<raku>

with $resp.cached-prompt-tokens -> $cached {
    say "cache: $cached / {$resp.prompt-tokens} prompt tokens";
}

=end code

=head1 ATTRIBUTES

=item C<$.api_url>     — base URL. Defaults to C<https://openrouter.ai/api/v1>.
=item C<$.api_key>     — bearer token (an OpenRouter inference key).
=item C<$.model>       — model id (e.g. C<anthropic/claude-opus-4-7>).
=item C<$.http-referer> — optional. Sent as the C<HTTP-Referer> header.
=item C<$.x-title>     — optional. Sent as the C<X-Title> header.
=item C<$.cache-breakpoints> — C<Bool>, default C<True>. Whether chat bodies carry C<cache_control> breakpoints. Text-completion bodies are never annotated.

=head1 RESPONSE FIELDS

The Response objects returned by this backend are typed
L<LLM::Chat::Backend::Response::OpenRouter> (or its C<::Stream>
subclass) and carry, in addition to the inherited OAI-spec fields:

=item C<$.cost>           — USD spent (Num), from C<usage.cost>.
=item C<$.generation-id>  — OpenRouter's C<gen-XXXX> id, suitable for the C</generation> endpoint.
=item C<$.provider-name>  — provider that actually served the request (e.g. C<Anthropic>).
=item C<$.is-byok>        — True when the call used the user's BYOK keys.

All four are presence-gated — read with C<.cost.defined> etc.

The inherited C<$.cached-prompt-tokens> is filled in on this backend
from either end of the call: from the completion body's
C<usage.prompt_tokens_details.cached_tokens> when the route reports
it inline, and otherwise from the C</generation> poll that also
carries cost. The body's number always wins — the poll only fills a
field the body left unreported, which is what makes the streaming
path (no inline usage frame under this backend's request shape)
report cache hits at all.

=end pod

use LLM::Chat::Backend::OpenAICommon;
use LLM::Chat::Backend::Response::OpenRouter;
use LLM::Chat::Backend::Response::OpenRouter::Stream;
use LLM::Chat::Debug;

use Cro::HTTP::Client;
use JSON::Fast;
use UUID::V4;

unit class LLM::Chat::Backend::OpenRouter is LLM::Chat::Backend::OpenAICommon;

#|( Optional C<HTTP-Referer> attribution header. Lets your app appear
    on OpenRouter's rankings page and in users' generation logs.
    See L<https://openrouter.ai/docs/api-reference/overview#headers>. )
has Str $.http-referer;

#|( Optional C<X-Title> attribution header. Human-readable name of
    the client app, paired with C<$.http-referer>. )
has Str $.x-title;

#|( Whether to annotate outgoing chat requests with OpenRouter
    C<cache_control> breakpoints. On by default: providers that need
    explicit breakpoints (Anthropic, Qwen, Gemini) cannot cache a
    prompt without them, and providers that cache implicitly (OpenAI,
    DeepSeek, Moonshot, Z.AI, Grok) ignore the annotation entirely —
    so leaving it on costs nothing on any route and saves most of the
    input bill on some. Turn it off to send the plain-string message
    shape, e.g. when pinning a request's bytes for a diff or when a
    new route rejects the content-parts form. )
has Bool $.cache-breakpoints = True;

# OpenRouter's hard ceiling on `cache_control` markers in one
# request. The placement in _finalize-request-body can only ever
# reach three, but a body that exceeds this is rejected outright, so
# the walk enforces the ceiling rather than relying on the arithmetic
# staying true as the placement rules change.
constant MAX-CACHE-BREAKPOINTS = 4;

#|( Default C<api_url> to OpenRouter's production endpoint when the
    caller didn't supply one. The parent's C<api_url> attr is
    C<is required>, so we have to fill it in pre-bless rather than
    via attribute shadowing (which doesn't override the parent's
    required-ness). Callers can still pass C<:api_url(...)> to point
    at a regional endpoint, a self-hosted gateway, or a test mock. )
method new(*%args is copy) {
	%args<api_url> //= 'https://openrouter.ai/api/v1';
	self.bless(|%args);
}

#|( Mirror SillyTavern's request shape: C<include_reasoning> + C<top_k>
    on every request, optional C<reasoning: { effort: ... }> when the
    caller asked for graded reasoning. We deliberately do I<not> send
    C<usage: { include: true }> or C<stream_options: { include_usage: true }>:
    investigation against ~0 % SillyTavern failure vs ~80 % failure
    here pinned those two fields as the trigger for OpenRouter's
    upstream-router holding 200 OK indefinitely on some providers.
    Cost telemetry that those fields used to provide is now fetched
    via a post-stream GET against C</generation?id=...> — see
    C<chat-completion-stream> below.

    The C<reasoning> hash carries only C<effort> (no C<enabled> key);
    OpenRouter's docs accept either shape but mixing them was the same
    sort of speculative extra that the inline C<usage> block was, and
    we're matching ST's wire bytes verbatim. The field is omitted
    entirely when C<settings.reasoning_effort> is undefined, so
    non-reasoning models don't see an unsupported parameter. )
method _get-api-settings(--> Hash) {
	my %settings = callsame;
	%settings<include_reasoning> = $.settings.defined && $.settings.reasoning_effort.defined;
	if $.settings.defined && $.settings.reasoning_effort.defined {
		%settings<reasoning> = %(
			effort => $.settings.reasoning_effort,
		);
	}
	%settings;
}

#|( Place C<cache_control> breakpoints on the assembled chat body.

    OpenRouter's caching contract: a provider that does not cache
    implicitly only reuses a prompt prefix when the request marks
    where the reusable part ends, and the marker has to sit on a
    content-I<parts> block rather than on a plain string. So a
    marked message goes from

        { role => 'system', content => 'You are ...' }

    to

        {
            role    => 'system',
            content => [ {
                type          => 'text',
                text          => 'You are ...',
                cache_control => { type => 'ephemeral' },
            }, ],
        }

    Where the markers go is the whole design. A breakpoint says
    "everything up to and including this message is a cacheable
    prefix", so we mark:

      * the head message — a caller's system prompt, in every
        conversation shape we see. It is the same bytes on every
        round, which makes it the one prefix always worth a marker.
      * the last two C<user> / C<assistant> turns, found by walking
        backwards. Round N+1 re-sends round N's conversation with new
        turns appended, so the marker one round old covers everything
        the new request shares with the old one — a single trailing
        marker would only ever match a prefix that had already
        stopped growing.

    The backward walk skips two shapes on its own, which is why it
    tests content rather than only role: C<tool>-role results (whose
    text is a transient the next turn subsumes) and C<assistant>
    messages whose content C<to-hash> nulled because they carry
    C<tool_calls> instead. Widening to those — Anthropic does accept
    a marker on a tool result — waits on live verification against
    the providers that need markers at all; the conservative set
    already covers the expensive prefix.

    Inert unless C<$.cache-breakpoints> is on and the body is a chat
    body: a text-completion body carries C<prompt>, has no messages
    to annotate, and is passed straight back.

    The Message objects behind those hashes are never touched. Each
    promotion builds a fresh hash, so a message's C<to-hash> and
    C<get-checksum> read the same after a request as before it —
    which matters because breakpoints move every round and a checksum
    that moved with them would invalidate caller-side caches on every
    turn. )
method _finalize-request-body(%settings --> Hash) {
	return %settings unless $!cache-breakpoints;
	return %settings unless %settings<messages>:exists;

	my @out;
	@out.push($_) for %settings<messages>.list;
	return %settings unless @out.elems;

	my $placed = 0;

	# (a) The head message — a system prompt in every conversation
	# shape we see, and the longest-lived prefix either way.
	if self!cacheable(@out[0]) {
		@out[0] = self!promote-cache-block(@out[0]);
		$placed++;
	}
	my $head-promoted = $placed > 0;

	# (b) The tail — the last two turns that can carry a marker.
	my $tail = 0;
	for (^@out.elems).reverse -> $i {
		last if $tail >= 2;
		last if $placed >= MAX-CACHE-BREAKPOINTS;
		next if $i == 0 && $head-promoted;
		next unless @out[$i] ~~ Associative;

		my $role = @out[$i]<role>;
		next unless $role.defined && ($role eq 'user' || $role eq 'assistant');
		next unless self!cacheable(@out[$i]);

		@out[$i] = self!promote-cache-block(@out[$i]);
		$placed++;
		$tail++;
	}

	return %settings unless $placed;

	my %out = %settings;
	%out<messages> = @out;
	%out;
}

#|( Whether a serialized message hash can carry a breakpoint: it has
    to have text for the marker to sit on. False for the
    C«content => Any» shape C<to-hash> produces for a tool-calling
    assistant, for a message already promoted to a parts array, and
    for empty content (which providers reject as a cache block). )
method !cacheable($message --> Bool:D) {
	return False unless $message ~~ Associative;
	my $content = $message<content>;
	$content ~~ Str:D && $content.chars > 0;
}

#|( Build the content-parts form of one serialized message, with the
    breakpoint on its single text part. Returns a NEW hash — the
    input belongs to the request body the caller assembled from the
    conversation's Messages, and nothing here may write through it. )
method !promote-cache-block(%message --> Hash) {
	my %promoted = %message;
	%promoted<content> = [
		%(
			type          => 'text',
			text          => %message<content>,
			cache_control => %( type => 'ephemeral' ),
		),
	];
	%promoted;
}

#|( Add the OpenRouter attribution headers when configured.
    Both are individually optional; sending only one is fine.
    Empty / undefined values are skipped so missing config doesn't
    leak as an empty header. )
method _get-api-headers(--> Hash) {
	my %headers = callsame;
	%headers<HTTP-Referer> = $!http-referer if $!http-referer.defined && $!http-referer.chars;
	%headers<X-Title>      = $!x-title      if $!x-title.defined      && $!x-title.chars;
	%headers;
}

#|( Construct an OpenRouter-flavoured Response so callers can read
    cost, generation-id, provider-name, and is-byok. )
method make-response(--> LLM::Chat::Backend::Response::OpenRouter) {
	LLM::Chat::Backend::Response::OpenRouter.new(id => uuid-v4());
}

#|( Streaming counterpart to C<make-response>. )
method make-stream-response(--> LLM::Chat::Backend::Response::OpenRouter::Stream) {
	LLM::Chat::Backend::Response::OpenRouter::Stream.new(id => uuid-v4());
}

#|( Lift OpenRouter-specific extras off the response body or a
    streaming chunk. Calls C<callsame> first so OAI-spec fields
    (prompt/completion/total tokens, model) flow through unchanged.

    Wire → Response field mapping:
      * C<usage.cost>     → C<.cost>
      * top-level C<id>   → C<.generation-id>  (OR's C<gen-XXXX>)
      * top-level C<provider> → C<.provider-name>
      * C<usage.is_byok>  → C<.is-byok>

    Defensive: only lifts when the Response actually consumes the
    OR Augment role, so a base C<Response> passed in (shouldn't
    happen with this backend, but the parent's hook is generic)
    is left untouched. )
method _lift-usage($response, $payload) {
	callsame;

	return unless $payload ~~ Associative;
	return unless $response ~~ LLM::Chat::Backend::Response::OpenRouter::Augment;

	my %args;
	if $payload<usage>:exists && $payload<usage> ~~ Associative {
		my %u = $payload<usage>;
		%args<cost>    = %u<cost>     if %u<cost>:exists     && %u<cost>.defined;
		%args<is-byok> = %u<is_byok>  if %u<is_byok>:exists  && %u<is_byok>.defined;
	}
	if $payload<id>:exists && $payload<id>.defined && $payload<id>.Str.chars {
		%args<generation-id> = $payload<id>;
	}
	if $payload<provider>:exists && $payload<provider>.defined && $payload<provider>.Str.chars {
		%args<provider-name> = $payload<provider>;
	}

	$response._set-or-usage(|%args) if %args.elems;
}

#|( Post-completion metadata lookup. Fired from both the streaming
    and blocking completion paths via C<_on-stream-complete> /
    C<_on-blocking-complete>. When a known C<generation-id> has been
    captured (top-level C<id> on the response body, or a stream
    chunk carrying it), fires a one-shot GET against
    C</generation?id=...> to lift cost / provider-name from
    OpenRouter's metadata endpoint. Replaces the inline
    C<usage.cost> we used to ask for via C<usage: { include: true }>
    — which we no longer send because it triggered OpenRouter's
    upstream router to hold 200 OK headers indefinitely on some
    providers (the bug this whole change set targets).

    Runs synchronously inside the parent's request-worker block so
    that consumers see C<.cost> populated by the time they observe
    the response as done. Adds ~50–200 ms of latency on top of the
    primary call, which is well within the noise floor of an LLM
    round-trip.

    Best-effort: any failure (network, parse, missing fields) leaves
    C<.cost> Nil and is logged via LLM::Chat::Debug — the primary
    call itself already succeeded. Skipped silently when the
    response isn't an OR-augmented type or no generation-id was
    captured (test mocks, malformed bodies). )
method !fetch-generation-metadata(LLM::Chat::Backend::Response $response) {
	return unless $response ~~ LLM::Chat::Backend::Response::OpenRouter::Augment;
	return unless $response.generation-id.defined && $response.generation-id.chars;

	my $gen-id = $response.generation-id;
	my $base   = $.api_url.subst(/'/' $/, '');
	my $url    = "$base/generation?id=$gen-id";
	my %hdrs   = self._get-api-headers;

	LLM::Chat::Debug.log('GENERATION LOOKUP', $url);

	# Same HTTP/1.1 pin as the parent's request clients — see
	# OpenAICommon.chat-completion / chat-completion-stream for the
	# rationale.
	my $client = Cro::HTTP::Client.new:
		:http<1.1>,
		content-type => 'application/json',
		timeout      => $.request-timeout;

	my $res  = await $client.get($url, headers => %hdrs);
	my $data = self._decode-json-body($res);

	LLM::Chat::Debug.log-json('GENERATION RESPONSE', $data);

	# OpenRouter wraps the metadata in `{ data: { ... } }`. Field
	# names on the wire are snake_case; some are absent for free /
	# BYOK calls so every lift is presence-gated.
	my %payload = $data ~~ Associative && $data<data> ~~ Associative
		?? $data<data>
		!! ();

	my %args;
	%args<cost> = %payload<total_cost>
		if %payload<total_cost>:exists && %payload<total_cost>.defined;
	%args<provider-name> = %payload<provider_name>
		if %payload<provider_name>:exists
		&& %payload<provider_name>.defined
		&& %payload<provider_name>.Str.chars;

	$response._set-or-usage(|%args) if %args.elems;

	# Token counts also arrive on the metadata endpoint. The
	# blocking path already lifted them off the response body's
	# `usage` block (OAI spec, present even without
	# `usage: { include: true }`); the streaming path under our
	# current request shape doesn't get a usage frame at all, so
	# this is the only place the stream picks them up. Presence-
	# gated against an already-populated field so the blocking
	# path never overwrites with the metadata endpoint's value
	# (which is occasionally rounded for cached / cancelled gens). )
	my %oai-args;
	%oai-args<prompt>     = %payload<tokens_prompt>
		if %payload<tokens_prompt>:exists
		&& %payload<tokens_prompt>.defined
		&& !$response.prompt-tokens.defined;
	%oai-args<completion> = %payload<tokens_completion>
		if %payload<tokens_completion>:exists
		&& %payload<tokens_completion>.defined
		&& !$response.completion-tokens.defined;

	# Cache-hit telemetry, same never-overwrite-a-body-value rule as
	# the token counts above: a `usage.prompt_tokens_details` block on
	# the completion body is the provider's own number and always wins.
	#
	# Which key the metadata endpoint uses for it is the one thing here
	# we cannot pin from the docs, so the lift probes an ordered
	# candidate list and takes the first defined numeric value:
	# OpenRouter's own `native_tokens_*` family first, then the plain
	# `tokens_cached` that matches the `tokens_prompt` naming beside
	# it, then the OAI-spec nesting in case the payload passes the
	# upstream usage block straight through. Order awaits live
	# verification against a generation that actually hit a cache;
	# until then a wrong guess costs nothing — every candidate is
	# absent and the field simply stays unreported.
	unless $response.cached-prompt-tokens.defined {
		my @candidates = %payload<native_tokens_cached>, %payload<tokens_cached>;
		@candidates.push(%payload<prompt_tokens_details><cached_tokens>)
			if %payload<prompt_tokens_details> ~~ Associative;

		with @candidates.first({ .defined && $_ ~~ Numeric }) -> $cached {
			%oai-args<cached-prompt> = $cached;
		}
	}

	$response._set-usage(|%oai-args) if %oai-args.elems;

	CATCH {
		default {
			LLM::Chat::Debug.log('GENERATION LOOKUP FAILED',
				"{.^name}: {.message}");
			# Best-effort. Leave .cost Nil rather than escalating
			# to the user — the primary call itself already
			# succeeded. CATCH returns normally (doesn't rethrow)
			# so the parent's CATCH treats this as a no-op for
			# error-classification purposes.
		}
	}
}

#|( Streaming-path post-completion hook. Fires after C<[DONE]>,
    before C<$response.done>; delegates to
    C<!fetch-generation-metadata> for the actual lookup so the
    blocking path can share the same code. )
method _on-stream-complete(LLM::Chat::Backend::Response::Stream $response) {
	callsame;
	self!fetch-generation-metadata($response);
}

#|( Blocking-path post-completion hook. Fires after the response
    body has been parsed and OAI/OR usage fields lifted, before
    C<$response.done>; delegates to C<!fetch-generation-metadata>
    so consumers of C<chat-completion> see C<.cost> populated by
    the time the response is observably done. )
method _on-blocking-complete(LLM::Chat::Backend::Response $response) {
	callsame;
	self!fetch-generation-metadata($response);
}
