=begin pod

=head1 NAME

LLM::Chat::Backend::KoboldCpp - KoboldCpp backend (OpenAI-compatible endpoints)

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Chat::Backend::KoboldCpp;
use LLM::Chat::Backend::Settings;

my $backend = LLM::Chat::Backend::KoboldCpp.new(
    api_url              => 'http://localhost:5001/v1',
    settings             => LLM::Chat::Backend::Settings.new(
        max_tokens => 1024,
        stop       => ["\nUser:"],
    ),
    request-stream-usage => True,   # token counts on streams
);

my $resp = $backend.chat-completion-stream(@messages);
until $resp.is-done { sleep 0.01 }

if $resp.is-success {
    say $resp.latest;
    # A reply that ended on "\nUser:" finishes as 'stop', even though
    # KoboldCpp put 'length' on the wire:
    say $resp.finish-reason;            # stop
    say $resp.provider-finish-reason;   # length
}

=end code

=head1 DESCRIPTION

Subclass of L<LLM::Chat::Backend::OpenAICommon> for KoboldCpp's
OpenAI-compatible C</v1/chat/completions> and C</v1/completions>
endpoints. It inherits the request, streaming, error and cancellation
behaviour of that class, and adds:

=item B<The full sampler surface.> C<min_p>, C<typical_p>, DRY, XTC,
C<rep_pen>, C<max_context_length> and friends go on every request, and
C<json_schema> goes out as KoboldCpp's native, grammar-enforced field.
=item B<Unbounded prefill.> The response-headers timeout is lifted
(when left at its default), because a long local context can spend
minutes in prompt processing before KoboldCpp answers.
=item B<An abort that reaches prefill.> C<cancel> also sends
C<POST /api/extra/abort>. See C<cancel>.
=item B<Truthful stop reasons.> A C<length> finish is checked against
KoboldCpp's own record of why the generation stopped. See below.
=item B<Thinking under KoboldCpp's names.> C<reasoning_effort> goes out
as is and C<reasoning_budget_tokens> as C<thinking_budget_tokens>
(KoboldCpp applies a budget only when the effort is not one of its
named levels, which set a budget of their own). C<id_slot> is never
sent: KoboldCpp has no slots.
=item B<Its own context size.> C<probe-server-limits> asks
C<GET /api/extra/true_max_context_length>.

=head1 TRUTHFUL STOP REASONS

KoboldCpp's OpenAI-compatible endpoints know three reasons a
generation stops, and put two finish reasons on the wire. From
C<koboldcpp.py> (1.121), in the streaming and the blocking completion
handlers alike:

=begin code :lang<python>

currfinishreason = "error" if sr==-2 else ("length" if (sr!=1) else "stop")

=end code

and the codes, from C<expose.h>:

=begin code :lang<c>

enum stop_reason
{
    ERROR_ENCOUNTERED=-2,
    INVALID=-1,
    OUT_OF_TOKENS=0,
    EOS_TOKEN_HIT=1,
    CUSTOM_STOPPER=2,
};

=end code

So a generation that ended on one of the request's C<stop> strings
(C<CUSTOM_STOPPER>, 2) is reported exactly like one that ran out of
budget (C<OUT_OF_TOKENS>, 0): C<finish_reason: "length">. The streaming
paths treat C<length> as a failure — a truncated reply must never pass
for a complete one — so complete replies were being thrown away. It is
common after a tool result, where KoboldCpp's emulated tool calling
often stops on a stop string with an output of C<""> or C<"\n">.

When C<verify-length-finish> is on (the default) and a completion
finishes with C<length>, the backend asks
C<GET /api/extra/perf> — at the server root, not under C</v1> — which
reports, among much else:

    stop_reason       the stop_reason code of the last generation
    last_token_count  how many tokens the last generation produced

The finish reason becomes C<stop> only when all of this holds:

=item C<stop_reason> is C<2> (C<CUSTOM_STOPPER>).
=item B<The count matches.> C</api/extra/perf> describes the server's
I<most recent> generation, and nothing ties it to this one — another
client's request could have finished in between. So C<last_token_count>
must equal the completion's own C<usage.completion_tokens>. KoboldCpp
fills both from the same count on the blocking path; on a stream its
usage frame counts the tokens it streamed, which is the same count in
every case read from its source — and a stream where they did differ
would simply stay C<length>, the safe direction.
=item B<Without usage, the count is well under the budget.> KoboldCpp
sends no usage on a stream unless asked (C<request-stream-usage>), and
never on the streams of its emulated tool calling. With no usage to
match, C<last_token_count> must be at most 90% of the request's
C<max_tokens>. That cannot prove the perf record is this generation's —
turn on C<request-stream-usage> where you can — but it rules out a
generation that used up its budget, which is the one being mistaken
for a stop.

Anything else leaves C<length>: another C<stop_reason>, a count that
does not match, a perf request that fails, answers something other than
a JSON object with integer fields, or takes longer than
C<verify-length-finish-timeout> seconds (default 2). The check runs once
per C<length> completion, after the usage has been read, and never for
C<stop> or C<tool_calls>.

The Response records what happened either way:

=begin code :lang<raku>

$resp.finish-reason;            # 'stop' — what the Response acted on
$resp.provider-finish-reason;   # 'length' — what KoboldCpp sent
$resp.finish-reason-evidence;
# {
#   source            => 'koboldcpp:/api/extra/perf',
#   verdict           => 'stop',
#   note              => 'custom stop sequence (stop_reason 2); last_token_count matches usage completion_tokens',
#   stop_reason       => 2,
#   last_token_count  => 3,
#   completion_tokens => 3,
# }

=end code

On a stream, C<stop> completes the Response successfully, with whatever
text arrived (possibly none). On the blocking paths, which do not fail
on C<length> in the first place, only C<finish-reason> changes.

B<Limits.> KoboldCpp's continuous-batching requests do not update the
counters C</api/extra/perf> reads, so with batching on, the record can
be an older generation's; the count match is what guards against that,
and without usage it is weaker. Turn C<verify-length-finish> off to take
C<length> at its word.

=head1 ATTRIBUTES

=item C<$.api_url> — the OpenAI-compatible base, e.g. C<http://localhost:5001/v1>. KoboldCpp's own endpoints (C</api/extra/abort>, C</api/extra/perf>) are addressed at the same URL with the C</v1> removed.
=item C<$.api_key> — sent as C<Authorization: Bearer ...> (KoboldCpp's C<--password>), on the perf and abort requests too.
=item C<$.model> — optional model name.
=item C<$.verify-length-finish> — C<Bool>, default C<True>. See L</TRUTHFUL STOP REASONS>.
=item C<$.verify-length-finish-timeout> — seconds, default C<2>; must be positive and finite.

Everything L<LLM::Chat::Backend::OpenAICommon> accepts —
C<request-stream-usage>, C<message-normalization>,
C<system-message-mode>, C<stream-finish-grace>, C<request-timeout> —
applies here too. KoboldCpp launched with C<--jinja> renders the
model's own chat template, which for Mistral-family models demands
strictly alternating roles; see C<message-normalization>.

=end pod

use LLM::Chat::Backend::OpenAICommon;
use LLM::Chat::Conversation::Message;
use LLM::Chat::Backend::Response;
use LLM::Chat::Backend::Response::Stream;
use LLM::Chat::Debug;
use LLM::Chat::ExceptionText;

use Cro::HTTP::Client;
use JSON::Fast;
use UUID::V4;

unit class LLM::Chat::Backend::KoboldCpp is LLM::Chat::Backend::OpenAICommon;

has Str $.api_url is required;
has Str $.api_key is rw;
has Str $.model   is rw;

#|( Whether a C<length> finish is checked against KoboldCpp's
    C<GET /api/extra/perf> before it is believed. On by default; see
    L</TRUTHFUL STOP REASONS>. With it off, C<length> is taken at its
    word, as every other OpenAI-compatible backend takes it. )
has Bool $.verify-length-finish = True;

#|( Upper bound, in seconds, on the C<GET /api/extra/perf> check —
    connection, headers and body together. A check that has not
    answered by then leaves the finish reason C<length>. )
has Real $.verify-length-finish-timeout = 2;

# KoboldCpp's `stop_reason` codes (enum stop_reason in its expose.h).
constant KCPP-STOP-OUT-OF-TOKENS  = 0;
constant KCPP-STOP-EOS-TOKEN-HIT  = 1;
constant KCPP-STOP-CUSTOM-STOPPER = 2;

# Without a usage count to match, `last_token_count` must be at most
# this fraction of max_tokens to be read as a stop sequence. See
# !length-verdict.
constant UNMATCHED-COUNT-CEILING = 0.9;

constant PERF-EVIDENCE-SOURCE = 'koboldcpp:/api/extra/perf';

submethod TWEAK() {
	die "KoboldCpp verify-length-finish-timeout must be a positive, "
		~ "finite number of seconds, not {$!verify-length-finish-timeout.raku}"
		unless $!verify-length-finish-timeout.defined
			&& !$!verify-length-finish-timeout.isNaN
			&& $!verify-length-finish-timeout > 0
			&& $!verify-length-finish-timeout != Inf;
}

#|( The server root, with the OAI-compat C</v1> suffix (and any slashes
    around it) stripped: KoboldCpp's own C</api/extra/...> endpoints
    live there, not under C</v1>. )
method !server-root(--> Str:D) {
	$.api_url.subst(/ '/'? 'v1' '/'? $/, '');
}

# Local dense models can spend well over 60s in prompt prefill on long
# context before the OAI-compatible endpoint sends response headers.
# Keep the parent's connection and total limits, but do not classify a
# healthy long-prefill KoboldCpp request as a headers timeout.
method _request-timeout(--> Hash) {
	my %timeout = callsame.Hash;
	%timeout<headers> = Inf if (%timeout<headers> // 60) == 60;
	%timeout;
}

#|( KoboldCpp accepts the OAI-spec body fields plus a long tail of
    sampler extras (top_k, min_p, typical_p, DRY, XTC, ...). Override
    of OpenAICommon's hook so the inherited chat / text completion
    methods send the full surface. )
method _get-api-settings(--> Hash) {
	my $s = self.settings;
	my %r;

	%r<model>                 = $!model if $!model.defined;
	%r<max_tokens>            = $s.max_tokens;
	%r<max_length>            = $s.max_tokens;
	%r<temperature>           = $s.temperature;
	%r<top_p>                 = $s.top_p;
	%r<top_k>                 = $s.top_k;
	%r<min_p>                 = $s.min_p;
	%r<typical_p>             = $s.typical_p;
	%r<repetition_penalty>    = $s.repetition_pen;
	%r<rep_pen>               = $s.repetition_pen;
	%r<presence_penalty>      = $s.presence_pen;
	%r<frequency_penalty>     = $s.frequency_pen;
	%r<max_context_length>    = $s.max_context;
	%r<stop>                  = $s.stop.Array;
	%r<dry_base>              = $s.dry_base;
	%r<dry_allowed_length>    = $s.dry_allowed_len;
	%r<dry_multiplier>        = $s.dry_multiplier;
	%r<dry_sequence_breakers> = $s.dry_seq_break.Array;
	%r<xtc_probability>       = $s.xtc_probability;
	%r<xtc_threshold>         = $s.xtc_threshold;

	# Structured outputs: KoboldCpp accepts a json_schema generate
	# field natively and compiles it to a grammar — sampler-level
	# enforcement, unlike the best-effort OpenAI response_format.
	# Older KoboldCpp builds ignore unknown fields harmlessly.
	%r<json_schema> = $s.json_schema with $s.json_schema;

	# Thinking, only when asked for. KoboldCpp reads the OpenAI
	# `reasoning_effort` field as a thinking level and takes a token
	# budget as llama.cpp's `thinking_budget_tokens` alias. It has no
	# slots, so `id_slot` is never sent.
	%r<reasoning_effort>       = $s.reasoning_effort        if $s.reasoning_effort.defined;
	%r<thinking_budget_tokens> = $s.reasoning_budget_tokens if $s.reasoning_budget_tokens.defined;

	return %r;
}

#|( KoboldCpp's context size: C<GET /api/extra/true_max_context_length>
    at the server root, which answers C<{"value": N}> with the
    C<--contextsize> it was launched with. (C</api/v1/config/max_context_length>
    is not used: it answers the smaller Horde-advertised limit when one
    is set.) Same result shape and guarantees as
    L<LLM::Chat::Backend::OpenAICommon>'s C<probe-server-limits>; no
    slot count, since KoboldCpp has none to report. )
method probe-server-limits(--> Hash:D) {
	my %evidence = source => 'koboldcpp:/api/extra/true_max_context_length';
	my %reply = self._probe-json('/api/extra/true_max_context_length', %evidence);
	return %evidence unless %reply.elems;
	my $value = %reply<value>;
	unless $value ~~ Int:D && $value > 0 {
		%evidence<note> = '/api/extra/true_max_context_length reports no positive integer value';
		return %evidence;
	}
	%evidence<context_length> = $value.Int;
	%evidence;
}

method _get-api-headers(--> Hash) {
	my %h;
	%h<Authorization> = "Bearer {$!api_key}" if $!api_key.defined;
	return %h;
}

#|( Cancel an in-flight generation. The local response stream closes
    FIRST, synchronously — the consumer side sees the cancel
    immediately and unconditionally. The upstream abort
    (C<POST /api/extra/abort>) then fires on a worker thread,
    best-effort: a slow, hung, or unreachable KoboldCpp must never
    block the cancelling thread (this is reached from TUI keybind
    handlers), and a lost abort costs at most a few wasted tokens
    server-side since KoboldCpp also stops generating when the SSE
    connection drops. Network failures are swallowed. The previous
    ordering — await the abort, then close locally — meant a dead
    backend made C<cancel> throw before the local close ever ran.
    Returns the background Promise so tests can await the abort
    attempt deterministically; production callers may sink it.

    C<$resp.cancel> now also drops the HTTP connection carrying the
    generation (see C<LLM::Chat::Backend::Response.cancel>), which makes
    this backend belt-and-braces rather than redundant. The two stop
    different things: the connection close is instant, local, and cannot
    fail, but only bites once response headers exist; the abort POST
    survives a request still in prefill, which is where a long local
    context spends most of its time. Keeping both means neither window
    is uncovered, and KoboldCpp stopping twice costs nothing. )
method cancel(LLM::Chat::Backend::Response $resp --> Promise) {
	$resp.cancel;

	# Strip the OAI-compat /v1 suffix (and any slashes around it) —
	# the abort endpoint lives at the server root. The old pattern
	# left the slash BEFORE v1 in place, producing //api/extra/abort.
	my $url = self!server-root ~ "/api/extra/abort";
	my %headers = self._get-api-headers;

	start {
		# One request, so not persistent: a persistent client would keep
		# the connection open in a pool nobody uses again. See
		# OpenAICommon's chat-completion.
		my $client = Cro::HTTP::Client.new:
			:!persistent,
			content-type => 'application/json';
		try await $client.post: $url, headers => %headers;
	}
}

#|( Check a C<length> finish against KoboldCpp's own record of why the
    generation stopped, and finish it as C<stop> when that record says
    a stop sequence ended it. See L</TRUTHFUL STOP REASONS>.

    Only C<length> is ever questioned, and only with
    C<verify-length-finish> on. Any failure along the way — the check
    timing out, an HTTP error, a reply without the fields — keeps
    C<length>; the evidence says which. )
method _reconcile-finish-reason(
	LLM::Chat::Backend::Response $response,
	Str:D $reason,
	%request,
	--> Str:D
) {
	return $reason unless $reason eq 'length' && $!verify-length-finish;

	my %evidence = source => PERF-EVIDENCE-SOURCE;
	my %perf = self!fetch-perf(%evidence);
	my Str:D $verdict = %perf
		?? self!length-verdict(%perf, $response, %request, %evidence)
		!! 'length';
	%evidence<verdict> = $verdict;
	$response._set-finish-reason-evidence(%evidence);
	LLM::Chat::Debug.log('FINISH REASON CHECK',
		"length -> $verdict: {%evidence<note> // ''}");
	$verdict;
}

#|( C<GET /api/extra/perf>, bounded by C<verify-length-finish-timeout>.
    Returns the parsed reply, or an empty Hash after writing what went
    wrong into C<%evidence<note>>. Never throws. )
method !fetch-perf(%evidence --> Hash:D) {
	my $limit = $!verify-length-finish-timeout;
	my $url = self!server-root ~ '/api/extra/perf';
	my %headers = self._get-api-headers;

	my $work = start {
		# One request, so not persistent: see the abort above.
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
	# there so nothing about the transport can hold a finished
	# generation's settle for longer than the limit.
	await Promise.anyof($work, Promise.in($limit));

	given $work.status {
		when Kept {
			my $perf = $work.result;
			return $perf.Hash if $perf ~~ Associative:D;
			%evidence<note> = "perf reply was not a JSON object";
		}
		when Broken {
			my $cause = $work.cause;
			%evidence<note> = "perf request failed: {$cause.^name}: "
				~ ((exception-message($cause) // '(no message)').lines.head // '');
		}
		default {
			%evidence<note> = "perf request did not answer within {$limit}s";
		}
	}
	%();
}

#|( Decide C<stop> or C<length> from a perf reply. See
    L</TRUTHFUL STOP REASONS> for why each guard exists. Writes the
    numbers it compared and its reasoning into C<%evidence>. )
method !length-verdict(
	%perf,
	LLM::Chat::Backend::Response $response,
	%request,
	%evidence,
	--> Str:D
) {
	my $stop-reason = %perf<stop_reason>;
	my $last-count  = %perf<last_token_count>;
	unless $stop-reason ~~ Int:D && $last-count ~~ Int:D {
		%evidence<note> = 'perf reply has no integer stop_reason / last_token_count';
		return 'length';
	}
	%evidence<stop_reason>      = $stop-reason;
	%evidence<last_token_count> = $last-count;

	unless $stop-reason == KCPP-STOP-CUSTOM-STOPPER {
		%evidence<note> = "stop_reason $stop-reason is not a custom stop "
			~ "sequence ({KCPP-STOP-CUSTOM-STOPPER})";
		return 'length';
	}

	with $response.completion-tokens -> $completion {
		%evidence<completion_tokens> = $completion;
		if $last-count == $completion {
			%evidence<note> = "custom stop sequence (stop_reason 2); "
				~ "last_token_count matches usage completion_tokens";
			return 'stop';
		}
		%evidence<note> = "last_token_count $last-count does not match usage "
			~ "completion_tokens $completion: perf describes another generation";
		return 'length';
	}

	my $max = %request<max_tokens> // %request<max_length>;
	unless $max ~~ Int:D && $max > 0 {
		%evidence<note> = 'no usage to match and no max_tokens in the request';
		return 'length';
	}
	%evidence<max_tokens> = $max;
	if $last-count >= 0 && $last-count <= $max * UNMATCHED-COUNT-CEILING {
		%evidence<note> = "custom stop sequence (stop_reason 2); no usage "
			~ "reported, last_token_count well under max_tokens";
		return 'stop';
	}
	%evidence<note> = "no usage reported and last_token_count $last-count is "
		~ "not well under max_tokens $max";
	'length';
}
