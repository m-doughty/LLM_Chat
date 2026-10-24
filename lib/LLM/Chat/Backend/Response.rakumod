unit class LLM::Chat::Backend::Response;

use JSON::Fast;

use LLM::Chat::Debug;
use LLM::Chat::ExceptionText;

has Str      $.id        is required;
has Str      $.msg       = "";
has          $.err       = Nil;
has Bool     $.done      = False;
has Bool     $.success   = False;
has Bool     $.cancelled = False;
has          @.tool-calls;
has          %!tool-call-builders;
has Str      $.finish-reason;
# The finish reason exactly as the provider put it on the wire, before a
# backend corrected it. See C<provider-finish-reason>.
has Str      $!provider-finish-reason;
# How a backend decided the finish reason, when it checked. See
# C<finish-reason-evidence>.
has          %!finish-reason-evidence;
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
has          %!provider-error;

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

# Completion tokens the provider reports as thinking — the OAI-spec
# `usage.completion_tokens_details.reasoning_tokens`. A SUBSET of
# C<$.completion-tokens>, never an addition to it: thinking is
# generated like any other token and counts against max_tokens.
# Undefined means the provider did not break it out (llama.cpp's
# server does not; its completion_tokens already include the
# thinking), which is NOT the same as "no thinking happened".
has Int      $.reasoning-tokens;

# Transport teardown for the request that is filling this Response, and
# the record of whether a cancel has been asked for. See
# C<_attach-aborter> / C<cancel>.
#
# Guarded by C<$!abort-lock> rather than left bare, because the two
# threads involved are genuinely concurrent: the backend's worker
# attaches the aborter the instant response headers land, while
# C<cancel> is reached from whatever thread the consumer cancels on (a
# TUI keybind handler, a job supervisor, a timeout watchdog). Either
# ordering has to end with the transport torn down exactly once.
has Lock     $!abort-lock = Lock.new;
has          $!abort;
has Bool     $!cancel-requested = False;

# Publishes the terminal state. The backend's worker settles a Response
# while a consumer on another thread polls C<is-done> and then reads
# C<is-success>, C<is-cancelled>, C<.err> and C<.msg>; C<is-done> used to
# turn True one assignment before C<is-success> did, so a poll landing in
# between saw a finished Response that had not succeeded. Now the
# terminal fields are written first and C<$!done> last, inside this lock,
# and C<is-done> reads C<$!done> through it: once a consumer sees True,
# every write that came before it is visible too.
has Lock     $!state-lock = Lock.new;

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
	$!state-lock.protect: { $!done }
}

method is-cancelled {
	$!state-lock.protect: { $!cancelled }
}

#|( True once C<cancel> has been called on this Response, whether or not
    the generation had a transport to tear down at the time.

    Distinct from C<is-cancelled>, which is set by the supply's quit
    handler and is therefore true for I<any> failure — a 429, a dropped
    connection, a stream that ended without C<[DONE]>. This one answers
    the narrower question a backend's error handling needs: "did the
    consumer ask for this?", so an exception that is merely the wreckage
    of our own abort is not reported as a generation failure.

    Read under the same lock that C<cancel> writes it under, so the
    thread that observes the torn-down transport sees the flag that
    explains it. )
method cancel-requested(--> Bool:D) {
	$!abort-lock.protect: { $!cancel-requested }
}

#|( Register a way to tear down the in-flight transport carrying this
    Response.

    B<Why this exists.> C<cancel> on its own only quits the local
    supply: the consumer stops seeing tokens, and the backend's read
    loop goes on draining the socket to the end. On an OpenAI-compatible
    server that means the model keeps generating a reply nobody will
    ever read — the cancel is cosmetic, and it is billed. The fix is to
    close the exchange at the socket, which llama.cpp's server,
    OpenRouter and every openai-compat gateway we target treat as
    "client is gone, stop generating".

    Backends call this as soon as they hold something that can do that
    — for the Cro-based backends, the C<Cro::HTTP::Response>, whose own
    C<.cancel> quits the body stream and drops the underlying
    connection:

    =begin code :lang<raku>
    my $res = await $client.post: $url, |%args;
    $response._attach-aborter({ $res.cancel });
    =end code

    The aborter is invoked at most once, from C<cancel>, and is dropped
    the moment the Response reaches a terminal state — so a cancel that
    arrives after the generation finished has nothing left to close and
    is a genuine no-op rather than a connection reset landing on a
    pooled socket somebody else is now using.

    B<The pre-headers race is handled here, not by the caller.> A
    consumer can cancel while the server is still prefilling, before a
    single response byte exists and therefore before any backend has a
    handle to register. Attaching an aborter to a Response that has
    already been cancelled runs it immediately, so the abort lands the
    instant the transport becomes abortable instead of being lost. That
    window is not hypothetical — it is exactly the "big slow model,
    user changed their mind" case that motivated all of this.

    The rule is simply whether this Response still wants its body. If it
    does, the aborter is held for C<cancel>; if it is already terminal —
    cancelled, or quit for any other reason before the transport
    appeared — nobody will read what is coming, so it is torn down here
    and never retained. A terminal Response never keeps a handle on a
    live connection. )
method _attach-aborter(&aborter --> Nil) {
	my Bool $abort-now = False;
	$!abort-lock.protect: {
		if $!cancel-requested || $!done {
			$abort-now = True;
		}
		else {
			$!abort = &aborter;
		}
	}
	self!run-aborter(&aborter) if $abort-now;
	Nil;
}

#|( Take the registered aborter, clearing it, so exactly one caller can
    ever run it. )
method !take-aborter() {
	$!abort-lock.protect: {
		my $aborter = $!abort;
		$!abort = Nil;
		$aborter;
	}
}

#|( Run a transport teardown, best-effort.

    Aborting is a courtesy to the server and to the bill; it is never
    the point of the call. A backend whose socket is already half-dead,
    a Cro response that turns out not to be cancellable, a subclass
    aborter that throws — none of those may propagate, because the
    thread underneath is a TUI keybind handler or a job supervisor that
    has already been told the cancel succeeded. Failures go to the
    debug log and no further. )
method !run-aborter($aborter --> Nil) {
	return unless $aborter.defined;
	{
		CATCH {
			default {
				LLM::Chat::Debug.log('ABORT FAILED',
					"{.^name}: {exception-message($_) // '(no message)'}");
			}
		}
		$aborter();
	}
	Nil;
}

method is-success {
	$!state-lock.protect: { $!success }
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
					# Sorted so the same arguments always read back as the
					# same string: it is echoed into the next request
					# (assistant tool_calls), where a reordering would
					# change the prompt bytes and miss the prefix cache.
					%state-fn<arguments> = to-json(%fn<arguments>, :sorted-keys);
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

#|( The finish reason the provider sent, verbatim — as opposed to
    C<finish-reason>, which is the one this library acted on.

    The two differ only when a backend knows its provider mislabels a
    stop. KoboldCpp reports every stop that is not an end-of-sequence
    token as C<length>, including a custom stop sequence; its backend
    checks C<GET /api/extra/perf> and, when the generation really
    ended on a stop sequence, finishes it as C<stop>. Then:

        $resp.finish-reason;            # 'stop'   — what LLM::Chat acted on
        $resp.provider-finish-reason;   # 'length' — what the wire said
        $resp.finish-reason-evidence;   # why, see below

    Falls back to C<finish-reason> when no backend recorded a wire
    value separately (the Mock backend, a blocking path of a
    third-party subclass), so the two can always be compared.
    Undefined only when no finish reason is known at all. )
method provider-finish-reason(--> Str) {
	$!provider-finish-reason // $!finish-reason;
}

method _set-provider-finish-reason(Str $reason --> Nil) {
	$!provider-finish-reason = $reason;
	Nil;
}

#|( What a backend looked at when it decided C<finish-reason>, as a
    detached copy of plain JSON data. Empty unless the backend checked
    — only L<LLM::Chat::Backend::KoboldCpp> does, and only for a
    C<length> finish; see its C<verify-length-finish>.

    The keys are the backend's to choose; every checked answer carries
    C<source> (where the evidence came from), C<verdict> (the finish
    reason decided on) and C<note> (why, in words). KoboldCpp adds the
    numbers it compared:

        {
            source           => 'koboldcpp:/api/extra/perf',
            verdict          => 'stop',
            note             => 'custom stop sequence (stop_reason 2); ...',
            stop_reason      => 2,
            last_token_count => 3,
            completion_tokens => 3,
        }

    Written for logs and bug reports; branch on C<finish-reason>, not
    on these keys. )
method finish-reason-evidence(--> Hash:D) {
	from-json(to-json(%!finish-reason-evidence)).Hash;
}

method _set-finish-reason-evidence(%evidence --> Nil) {
	%!finish-reason-evidence = from-json(to-json(%evidence)).Hash;
	Nil;
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

method provider-error(--> Hash:D) {
	from-json(to-json(%!provider-error)).Hash;
}

method _set-provider-error(%error --> Nil) {
	my $int-keys = <status body_bytes retained_bytes>.Set;
	my $bool-keys = <body_truncated body_available>.Set;
	my $str-keys = <content_type body_text error_message error_type error_code capture_error decode_error>.Set;
	my %clean;
	for %error.kv -> $key, $value {
		if ($int-keys{$key}:exists) {
			next unless $value ~~ Int:D && $value !~~ Bool:D && $value >= 0;
			%clean{$key} = $value.Int;
		}
		elsif ($bool-keys{$key}:exists) {
			next unless $value ~~ Bool:D;
			%clean{$key} = $value;
		}
		elsif ($str-keys{$key}:exists) {
			next unless $value ~~ Str:D;
			next if $key ne 'body_text' && $value.encode.bytes > 1024;
			next if $key eq 'body_text' && $value.encode.bytes > 16 * 1024;
			%clean{$key} = $value;
		}
	}
	%!provider-error = %clean;
	Nil;
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
	:$prompt, :$completion, :$total, :$model, :$cached-prompt, :$reasoning,
) {
	$!prompt-tokens        = $prompt.Int        if $prompt.defined;
	$!completion-tokens    = $completion.Int    if $completion.defined;
	$!total-tokens         = $total.Int         if $total.defined;
	$!model-used           = $model.Str         if $model.defined;
	$!cached-prompt-tokens = $cached-prompt.Int if $cached-prompt.defined;
	$!reasoning-tokens     = $reasoning.Int     if $reasoning.defined;
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
	# $!done last: see $!state-lock.
	$!state-lock.protect: {
		$!success = True;
		$!done    = True;
	};
	# Nothing left to abort: the body arrived. Dropped rather than kept
	# so a late cancel cannot reset a connection that has since been
	# handed back to Cro's pool.
	self!take-aborter;
	$!tap.close;
}

method _quit($ex) {
	# $!done last: see $!state-lock.
	$!state-lock.protect: {
		$!err       = $ex;
		$!cancelled = True;
		$!done      = True;
	};
	self!take-aborter;
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

#|( Abandon this generation: close the consumer's side of it, then stop
    the server producing the rest of it.

    Order matters and is fixed. The local supply is quit B<first> and
    synchronously, so the caller — a keybind handler, usually — sees the
    cancel take effect immediately and unconditionally, whatever the
    network is doing. Only then is the transport torn down, best-effort,
    through the aborter a backend registered with C<_attach-aborter>.

    Without that second half a cancel is decorative. The consumer stops
    reading, the backend's react loop keeps draining the body to the
    end, and the model on the other side generates — and bills for — the
    entire reply for a request nobody is waiting on. Closing the socket
    is what makes an openai-compatible server stop.

    Safe to call more than once, and safe to call on a generation that
    already finished: the aborter is taken exactly once and is dropped
    when the Response reaches a terminal state, so a second cancel (or
    one that lost the race to C<[DONE]>) quits an already-quit supply,
    finds nothing to close, and changes nothing about the Response — a
    completed generation keeps C<is-success>. )
method cancel {
	self._touch-activity;

	my $aborter = $!abort-lock.protect: {
		$!cancel-requested = True;
		my $registered = $!abort;
		$!abort = Nil;
		$registered;
	};

	$.supplier.quit("Cancelled by user");

	self!run-aborter($aborter);
}

method quit($err) {
	self._touch-activity;
	$.supplier.quit($err);
}
