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
=item Adds C<HTTP-Referer> / C<X-Title> attribution headers when
      C<:http-referer> / C<:x-title> are configured. (See
      L<https://openrouter.ai/docs/api-reference/overview#headers>.)
=item Returns L<LLM::Chat::Backend::Response::OpenRouter> /
      L<LLM::Chat::Backend::Response::OpenRouter::Stream> so
      callers can read C<.cost>, C<.generation-id>,
      C<.provider-name>, and C<.is-byok>.
=item Lifts those fields off the response body / stream chunks via
      C<_lift-usage> (calls C<callsame> first to handle OAI-spec).
=item After a stream closes with a known C<generation-id>, fires a
      one-shot GET against C</generation?id=...> to populate
      C<.cost> / C<.provider-name> from OpenRouter's metadata
      endpoint. Replaces the inline C<usage.cost> we used to ask for
      via C<usage: { include: true }>; lookup is async and best-effort,
      so a failure leaves C<.cost> Nil rather than erroring the call.

Everything else — request shape, error classification, fallback /
retry interaction, streaming mechanics, cancel — is inherited
unchanged from C<OpenAICommon>.

=head1 ATTRIBUTES

=item C<$.api_url>     — base URL. Defaults to C<https://openrouter.ai/api/v1>.
=item C<$.api_key>     — bearer token (an OpenRouter inference key).
=item C<$.model>       — model id (e.g. C<anthropic/claude-opus-4-7>).
=item C<$.http-referer> — optional. Sent as the C<HTTP-Referer> header.
=item C<$.x-title>     — optional. Sent as the C<X-Title> header.

=head1 RESPONSE FIELDS

The Response objects returned by this backend are typed
L<LLM::Chat::Backend::Response::OpenRouter> (or its C<::Stream>
subclass) and carry, in addition to the inherited OAI-spec fields:

=item C<$.cost>           — USD spent (Num), from C<usage.cost>.
=item C<$.generation-id>  — OpenRouter's C<gen-XXXX> id, suitable for the C</generation> endpoint.
=item C<$.provider-name>  — provider that actually served the request (e.g. C<Anthropic>).
=item C<$.is-byok>        — True when the call used the user's BYOK keys.

All four are presence-gated — read with C<.cost.defined> etc.

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

#|( Post-stream metadata lookup. When the streaming response
    naturally finishes (`[DONE]` received and a generation-id was
    captured along the way), fire a one-shot GET against
    C</generation?id=...> to lift cost / provider-name from
    OpenRouter's metadata endpoint. This replaces the inline
    C<usage.cost> we used to ask for via C<usage: { include: true }>
    — which we no longer send because it triggered OpenRouter's
    upstream router to hold 200 OK headers indefinitely on some
    providers (the bug this whole change set targets).

    Runs synchronously inside the parent's streaming worker block so
    that consumers see C<.cost> populated by the time they observe
    C<.is-done = True>. Adds ~50–200 ms of latency between the final
    SSE chunk and C<.is-done>, which is well within the noise floor
    of an LLM round-trip and avoids a regression for Cantina
    (which reads C<.cost> the moment the stream completes).

    Best-effort: any failure (network, parse, missing fields) leaves
    C<.cost> Nil and is logged via LLM::Chat::Debug — the stream
    itself already succeeded. Skipped silently when the response
    isn't an OR-augmented type or no generation-id was captured
    (test mocks, malformed streams). )
method _on-stream-complete(LLM::Chat::Backend::Response::Stream $response) {
	callsame;

	return unless $response ~~ LLM::Chat::Backend::Response::OpenRouter::Augment;
	return unless $response.generation-id.defined && $response.generation-id.chars;

	my $gen-id = $response.generation-id;
	my $base   = $.api_url.subst(/'/' $/, '');
	my $url    = "$base/generation?id=$gen-id";
	my %hdrs   = self._get-api-headers;

	LLM::Chat::Debug.log('GENERATION LOOKUP', $url);

	# Same HTTP/1.1 pin as the parent's stream client — see
	# OpenAICommon.chat-completion-stream for the rationale.
	my $client = Cro::HTTP::Client.new:
		:http<1.1>,
		content-type => 'application/json',
		timeout      => $.request-timeout;

	my $res  = await $client.get($url, headers => %hdrs);
	my $data = await $res.body;

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

	# Token counts also arrive on the metadata endpoint and are
	# typically more accurate than the streaming usage frame for
	# providers that don't emit one. Lift them onto the OAI-spec
	# fields when we have them and they weren't already populated.
	my %oai-args;
	%oai-args<prompt>     = %payload<tokens_prompt>
		if %payload<tokens_prompt>:exists
		&& %payload<tokens_prompt>.defined
		&& !$response.prompt-tokens.defined;
	%oai-args<completion> = %payload<tokens_completion>
		if %payload<tokens_completion>:exists
		&& %payload<tokens_completion>.defined
		&& !$response.completion-tokens.defined;

	$response._set-usage(|%oai-args) if %oai-args.elems;

	CATCH {
		default {
			LLM::Chat::Debug.log('GENERATION LOOKUP FAILED',
				"{.^name}: {.message}");
			# Best-effort. Leave .cost Nil rather than escalating
			# to the user — the stream itself succeeded. The CATCH
			# returns normally (doesn't rethrow) so the parent's
			# CATCH treats this as a no-op for error-classification
			# purposes.
		}
	}
}
