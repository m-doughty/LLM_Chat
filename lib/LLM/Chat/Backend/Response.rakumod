unit class LLM::Chat::Backend::Response;

has Str      $.id        is required;
has Str      $.msg       = "";
has          $.err       = Nil;
has Bool     $.done      = False;
has Bool     $.success   = False;
has Bool     $.cancelled = False;
has          @.tool-calls;
has Str      $.finish-reason;
has Supplier $.supplier  is required;
has Tap      $.tap       is required;

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

method _emit($e) {
	$!msg = $e;
}

method _set-tool-calls(@calls) {
	@!tool-calls = @calls;
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

#|( Partial-update OAI-spec usage attrs from whatever a provider
    sent us. Every parameter is optional; only defined values are
    written, so a late-arriving streaming chunk can fill in fields
    an earlier chunk left undefined without ever clearing them.
    Idempotent when called with the same payload twice.

    Provider-specific extras go through the provider's own setter
    on its Response subclass (e.g.
    C<Response::OpenRouter._set-or-usage>). Backends should call
    this for OAI-spec fields and the provider-specific setter for
    anything beyond that. )
method _set-usage(
	:$prompt, :$completion, :$total, :$model,
) {
	$!prompt-tokens     = $prompt.Int         if $prompt.defined;
	$!completion-tokens = $completion.Int     if $completion.defined;
	$!total-tokens      = $total.Int          if $total.defined;
	$!model-used        = $model.Str          if $model.defined;
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
	$.supplier.emit($e);
}

method done {
	$.supplier.done;
}

method cancel {
	$.supplier.quit("Cancelled by user");
}

method quit($err) {
	$.supplier.quit($err);
}
