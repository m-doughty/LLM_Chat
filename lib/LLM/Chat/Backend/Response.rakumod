unit class LLM::Chat::Backend::Response;

use JSON::Fast;

has Str      $.id        is required;
has Str      $.msg       = "";
has          $.err       = Nil;
has Bool     $.done      = False;
has Bool     $.success   = False;
has Bool     $.cancelled = False;
has          @.tool-calls;
has          %!tool-call-builders;
has Str      $.finish-reason;
has Supplier $.supplier  is required;
has Tap      $.tap       is required;
has Instant  $.last-activity-at;

# Structured error metadata. Populated by backend implementations
# alongside C<.quit(...)> via C<_set-error-info>. Lets consumers
# (Task fallback policy, retry classifiers) branch on error kind
# without regex-parsing the raw message. Both fields stay undefined
# on success; on failure at least one is set.
#
#   $.error-class — categorical string. Known values:
#     * 'http'       — HTTP-level error, $.error-status set
#     * 'timeout'    — request exceeded the client-side deadline
#     * 'connection' — network unreachable / connection reset / DNS
#     * 'response'   — HTTP succeeded but body was malformed or empty
#     * 'unknown'    — catch-all for exceptions that don't classify
#   $.error-status — HTTP status code when error-class is 'http'.
#                    Undefined for non-HTTP errors.
has Int      $.error-status;
has Str      $.error-class;

# Count of stream frames the backend received but could not parse.
# Streaming backends bump this via C<_note-dropped-frame> instead of
# failing the whole generation, because a provider that interleaves a
# malformed fragment mid-stream is usually still producing a usable
# reply. It stays 0 on every non-streaming path and on any stream that
# parsed cleanly, so a non-zero value always means "there is a hole in
# what we received" — see C<_note-dropped-frame>.
has Int      $.dropped-frames = 0;

# OAI-spec usage attrs. Populated by any OpenAI-compatible backend
# whose response body carries a `usage` block. Stay undefined on
# backends that don't emit one (mock / local / stream without
# include_usage) so callers can tell "unknown" from "zero" —
# "$.prompt-tokens.defined ?? 'known' !! 'unknown'".
#
# Provider-specific extras (OpenRouter's cost, generation-id, routed
# provider name, BYOK flag, ...) live on the provider's Response
# subclass — see C<LLM::Chat::Backend::Response::OpenRouter>.
has Int      $.prompt-tokens;
has Int      $.completion-tokens;
has Int      $.total-tokens;
has Str      $.model-used;

# Prompt tokens the provider served out of its own prompt cache
# instead of processing fresh — the OAI-spec
# `usage.prompt_tokens_details.cached_tokens` field, which every
# caching provider we target reports under that name. A SUBSET of
# C<$.prompt-tokens>, never an addition to it: a call billed
# "prompt 40_000, cached 38_000" processed 2_000 fresh tokens and
# read the rest back, which is what makes it worth reporting (cache
# reads bill at a fraction of fresh input).
#
# Undefined means "the provider said nothing about caching", which is
# NOT the same as "nothing was cached" — plenty of endpoints never
# emit the field at all. Gate on C<.defined> before doing arithmetic:
#
#   with $resp.cached-prompt-tokens -> $cached {
#       my $hit = $cached * 100 / ($resp.prompt-tokens || 1);
#       say "cache hit: {$hit.round}% of prompt";
#   }
has Int      $.cached-prompt-tokens;

# Reasoning trace from thinking-capable models (DeepSeek-R1, Claude
# with thinking enabled, OpenAI o-series, etc.). Streamed under
# `delta.reasoning` separately from `delta.content`, accumulated by
# the OAI-spec stream loop. Stays undefined for non-reasoning models
# so callers can distinguish "model emitted nothing" from "model
# doesn't support reasoning at all".
has Str      $.reasoning-text;

submethod BUILD(:$id) {
	$!id       := $id;
	$!supplier := Supplier.new;
	$!last-activity-at = now;

	$!tap = self.supply.tap(
		-> $e { self._emit($e) },
		done => -> { self._done },
		quit => -> $ex { self._quit($ex) },
	);
}

method is-done { 
	$!done;
}

method is-cancelled {
	$!cancelled;
}

method is-success {
	$!success;
}

method supply {
	$.supplier.Supply;
}

method _set-msg($msg) {
	$!msg = $msg;
}

method _set-tap($t) {
	$!tap = $t;
}

method _touch-activity(Instant :$at = now) {
	$!last-activity-at = $at;
	Nil;
}

method _emit($e) {
	$!msg = $e;
}

method _set-tool-calls(@calls) {
	@!tool-calls = @calls;
}

#|( Which builder a tool-call delta belongs to.

    The OAI streaming spec puts an C<index> on every C<tool_calls>
    fragment, and when one is there it is authoritative — it is the
    only thing that can describe parallel calls being streamed
    interleaved.

    Some providers omit it. The fallback then has to decide from the
    rest of the fragment whether this is a NEW call or the
    continuation of one already in flight, and the answer is C<id>:
    the spec only sends C<id> (and C<type>, and the function C<name>)
    on a call's FIRST fragment, with every argument fragment after it
    carrying nothing but C<function.arguments>. So:

      * an C<id> means a new call — one past the highest builder;
      * no C<id> means more arguments for the call in flight — the
        highest builder there is.

    The previous fallback used the builder COUNT as the index, which
    got the first fragment right and then routed every argument
    fragment after it to a fresh builder: one tool call arrived
    shattered into N calls, each holding a slice of the JSON, none of
    them parseable. )
method !delta-index(%delta --> Int:D) {
	return %delta<index>.Int
		if %delta<index>:exists && %delta<index>.defined;

	my $highest = %!tool-call-builders.elems
		?? %!tool-call-builders.keys.map(*.Int).max
		!! -1;

	%delta<id>:exists && %delta<id>.defined
		?? $highest + 1
		!! max($highest, 0);
}

method _append-tool-call-deltas(@deltas) {
	for @deltas -> $delta {
		next unless $delta ~~ Associative;

		my $index = self!delta-index($delta);
		my %call = %!tool-call-builders{$index}:exists
			?? %!tool-call-builders{$index}
			!! %(index => $index, function => %(arguments => ''));

		%call<id>   = $delta<id>   if $delta<id>:exists   && $delta<id>.defined;
		%call<type> = $delta<type> if $delta<type>:exists && $delta<type>.defined;

		if $delta<function> ~~ Associative {
			my %fn = $delta<function>;
			my %state-fn = %call<function> ~~ Associative
				?? %call<function>
				!! %(arguments => '');

			%state-fn<name> = %fn<name>
				if %fn<name>:exists && %fn<name>.defined;

			if %fn<arguments>:exists && %fn<arguments>.defined {
				if %fn<arguments> ~~ Associative {
					%state-fn<arguments> = to-json(%fn<arguments>);
				} else {
					%state-fn<arguments> = (%state-fn<arguments> // '')
						~ %fn<arguments>.Str;
				}
			}

			%call<function> = %state-fn;
		}

		%!tool-call-builders{$index} = %call;
	}

	self._set-tool-calls(
		%!tool-call-builders.keys.sort(*.Int).map({
			%!tool-call-builders{$_}
		}).list
	) if %!tool-call-builders.elems;
}

method _set-finish-reason(Str $reason) {
	$!finish-reason = $reason;
}

#|( Record categorical + HTTP-code info about a failure. Call from a
    backend's CATCH block BEFORE C<$response.quit(...)> so consumers
    reading the error off the done response see both the raw message
    (via C<.err>) and the classified shape (via C<.error-class> +
    C<.error-status>). Idempotent — repeated calls just overwrite,
    which matches the "last error wins" shape of CATCH blocks.
    C<$status> is only meaningful for C<error-class eq 'http'>;
    omit it for other classes. )
method _set-error-info(Str :$class, Int :$status) {
	$!error-class  = $class  if $class.defined;
	$!error-status = $status if $status.defined;
}

#|( Record that one frame of a streamed body could not be parsed.
    Call from a streaming backend's SSE-parse CATCH block, at the
    point where the malformed frame is skipped.

    Skipping is the right default — providers interleave error
    fragments, keep-alive junk and occasional truncated frames into
    otherwise healthy streams, and killing a generation over one of
    them loses a reply that was fine. But "we skipped something" is
    information the consumer needs, because what it costs depends
    entirely on what was in the hole:

      * prose loses a few tokens in the middle. Unpleasant,
        detectable by a human, and not worth failing the call over.
      * a tool call's C<arguments> lose a slice of JSON. The
        fragments either side are concatenated, and the result is
        either a parse failure or — worse — still-valid JSON that
        says something the model never asked for.

    So the counter is exposed rather than acted on here: the backend's
    stream-termination path decides, and does fail a stream that
    dropped frames while assembling tool calls. See
    C<LLM::Chat::Backend::OpenAICommon>'s stream termination contract. )
method _note-dropped-frame(--> Nil) {
	$!dropped-frames++;
	Nil;
}

#|( Partial-update OAI-spec usage attrs from whatever a provider
    sent us. Every parameter is optional; only defined values are
    written, so a late-arriving streaming chunk can fill in fields
    an earlier chunk left undefined without ever clearing them.
    Idempotent when called with the same payload twice.

    Provider-specific extras go through the provider's own setter
    on its Response subclass (e.g.
    C<Response::OpenRouter._set-or-usage>). Backends should call
    this for OAI-spec fields and the provider-specific setter for
    anything beyond that.

    C<:cached-prompt> is the cache-hit slice of C<:prompt>. It is
    presence-gated like everything else here, so a provider that
    reports a genuine zero ("nothing was cached this call") is
    recorded as 0 and stays distinguishable from one that never
    mentioned caching at all. )
method _set-usage(
	:$prompt, :$completion, :$total, :$model, :$cached-prompt,
) {
	$!prompt-tokens        = $prompt.Int        if $prompt.defined;
	$!completion-tokens    = $completion.Int    if $completion.defined;
	$!total-tokens         = $total.Int         if $total.defined;
	$!model-used           = $model.Str         if $model.defined;
	$!cached-prompt-tokens = $cached-prompt.Int if $cached-prompt.defined;
}

#|( Append a chunk of reasoning text. Streaming reasoning models emit
    one C<delta.reasoning> fragment per chunk before they switch to
    emitting C<delta.content>; backends call this once per chunk and
    the response carries the concatenated trace by the time the
    stream closes. Idempotent on the empty string, so calling it on
    every chunk regardless of whether reasoning was present is safe. )
method _append-reasoning(Str:D $chunk) {
	return unless $chunk.chars;
	$!reasoning-text //= '';
	$!reasoning-text ~= $chunk;
}

method has-tool-calls(--> Bool:D) {
	@!tool-calls.elems > 0;
}

method _done {
	$!done    = True;
	$!success = True;
	$!tap.close;
}

method _quit($ex) {
	$!err       = $ex;
	$!done      = True;
	$!cancelled = True;
	$!tap.close;
}

method emit($e) { 
	self._touch-activity;
	$.supplier.emit($e);
}

method done {
	self._touch-activity;
	$.supplier.done;
}

method cancel {
	self._touch-activity;
	$.supplier.quit("Cancelled by user");
}

method quit($err) {
	self._touch-activity;
	$.supplier.quit($err);
}
