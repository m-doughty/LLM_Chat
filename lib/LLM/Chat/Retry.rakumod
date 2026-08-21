=begin pod

=head1 NAME

LLM::Chat::Retry - the shared retry/fallback policy primitives

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Chat::Retry;
use LLM::Chat::Retry::Exceptions;

my @attempts;
my Int $retries-left = 2;

for @backends.kv -> $i, $backend {
    loop {
        my $resp = call-somehow($backend);
        last if $resp.is-success;   # advance on success is the caller's job

        @attempts.push: attempt-record(
            backend-index => $i,
            model         => $backend.model,
            error         => "[backend $i] {$resp.err}",
        );

        given classify-error(
            error-class  => $resp.error-class,
            error-status => $resp.error-status,
        ) {
            when 'abort'      { die "aborting: {$resp.err}" }
            when 'retry-same' {
                last unless $retries-left > 0;
                my Num $wait = retry-backoff(3 - $retries-left);
                $retries-left--;
                # Cancel-aware: returns False the moment the hook flips.
                last unless sleep-with-cancel($wait, cancelled => &cancelled);
                next;
            }
            default { last }        # 'advance'
        }
    }
}

X::LLM::Chat::Retry::Exhausted.new(
    :@attempts, summary => @attempts.map({ "  $_<error>" }).join("\n"),
).throw;

=end code

=head1 DESCRIPTION

Five small, pure, side-effect-light subs that together are the retry
policy L<LLM::Data::Inference::Task> has run in production since 0.5:
how to B<classify> a failure, how long to B<wait> before retrying, how
to B<sleep> without ignoring a cancel, and what shape the B<attempt>
and B<telemetry> records have.

They were factored out of that Task verbatim so a second executor
(C<LLM::Agent::Loop>, an app's own chain runner) gets the same
behaviour without copying it — and, more importantly, so that fixing
the policy fixes it in one place. Everything here is deliberately a
free function: no state, no I/O beyond C<sleep>, no knowledge of
backends, responses or HTTP clients.

=head2 What is NOT here, deliberately

The loop itself. Bucket handling is I<policy shaped by the caller>: the
C<'abort'> bucket dies with a message only the caller can compose, the
exhaustion hook's payload differs per layer, hook-shielding is the
caller's contract with its own users, and the shape of "advance"
depends on what a backend even is in that layer. Trying to share the
loop would force one caller's error strings and hook semantics onto
every other — so the primitives are shared and the loop is not.

C<telemetry-payload> also does not import
C<LLM::Chat::Backend::Response>: it probes whatever it is handed with
C<.?>, so a caller can pass a real Response, a subclass with provider
extras, a test double, or nothing at all.

=head2 Error buckets

C<classify-error> maps a structured failure (as recorded on a Response
by C<_set-error-info>) to one of three strings:

=begin table

Bucket      | Meaning                              | What the caller should do
============|======================================|==========================
abort       | config / account / access error      | stop the whole chain now
retry-same  | probably transient                   | retry THIS backend after a backoff
advance     | model-specific pathology             | move to the NEXT backend at once

=end table

The full rule table, in evaluation order:

=begin table

Condition                        | Bucket
=================================|============
parser-failed => True (any class) | advance
http 400 / 401 / 402 / 403 / 404  | abort
http 429                          | advance
http 500..599                     | retry-same
http, any other or missing status | advance
timeout                           | advance
connection                        | retry-same
response                          | advance
anything else (incl. no class)    | retry-same

=end table

The two classes worth reading closely are C<'timeout'> and
C<'connection'>, because the same Cro exception can produce either and
the difference is B<which phase> it expired in — see below.

The reasoning behind the less obvious rows:

=item B<parser-failed wins over everything.> The transport succeeded;
what came back was unusable. A different model may well produce
parseable output, the same one just proved it does not — so advance,
and never spend the transient-retry budget on it.

=item B<429 advances rather than retrying.> A rate limit is per-account
per-provider; the next backend in the chain is usually a different one
and answers immediately, which beats sleeping out someone else's quota.

=item B<5xx retries the same backend.> Against an aggregator like
OpenRouter, a 5xx is one upstream provider failing — the retry
frequently routes to a different one and succeeds on the same backend
config.

=item B<An unclassifiable error retries the same backend.> The
conservative reading: an error nobody has classified yet is more often
a hiccup than a permanent property of the model.

=item B<An C<'http'> class with no status advances.> There is no
evidence for a retry, and no evidence it will abort either; moving on
is the cheap, safe move.

=item B<A C<'timeout'> advances, but a failed I<connect> is not one.>
C<'timeout'> means the endpoint accepted the connection and then did
not answer inside the deadline. That is a statement about I<that>
backend, and the next one in the chain will answer sooner than a
backoff would end — so, advance.

A connect that never completed is a different animal, and
L<LLM::Chat::Backend::OpenAICommon> files it as C<'connection'>
accordingly: nothing was sent, the endpoint said nothing, and all that
is known is that the network was unwell for thirty seconds. Retrying
the same backend after a backoff is the correct response, and on a
B<one-backend chain> it is the only one that is not "give up" — which
is exactly what filing it under C<'timeout'> used to mean there.

=head2 Backoff

C<retry-backoff($n)> is C<min(2 ** ($n - 1) + jitter, $cap)> seconds,
with C<$n> the 1-based retry number and C<jitter> drawn from
C<[0, 0.5)> when the caller does not supply one:

=begin table

retry-n | range (default cap 30)
========|========================
1       | 1.0 .. 1.5 s
2       | 2.0 .. 2.5 s
3       | 4.0 .. 4.5 s
4       | 8.0 .. 8.5 s
5       | 16.0 .. 16.5 s
6+      | 30 s (capped)

=end table

The jitter exists because these chains are run by batch workers: N
processes that hit the same rate limit in the same second would
otherwise all retry in the I<same> second, forever. Half a second of
spread is enough to decorrelate them without meaningfully changing the
wait. Pass C<:jitter(0e0)> for deterministic tests, or a bigger jitter
for bigger fleets.

=head2 Sleeping without ignoring a cancel

C<sleep-with-cancel> is the reason a cancelled run does not sit out a
16-second backoff. It sleeps in C<$chunk> slices (default 0.25 s),
checking C<&cancelled> B<before every slice, including the first>, and
returns C<False> the moment the hook says stop — so worst-case latency
between a cancel flipping and the caller noticing is one chunk, not one
backoff.

It returns a C<Bool>, it does not throw: only the caller knows which
exception type its layer promises (C<X::LLM::Chat::Retry::Cancelled>,
a subclass, or something else entirely), so it reports and lets the
caller decide.

=begin code :lang<raku>

throw-cancelled unless sleep-with-cancel($wait, cancelled => &cancelled-now);

=end code

A C<&cancelled> callback that throws propagates: the callback is the
caller's own code, and swallowing an exception from it would silently
turn a broken cancel hook into "never cancels".

=head2 Record shapes

C<attempt-record> builds the entries of C<X::LLM::Chat::Retry::Exhausted>'s
C<@.attempts>:

=begin table

Key           | Type | Presence
==============|======|==========================================
backend-index | Int  | always
model         | Str  | always
error         | Str  | always
raw-text      | Str  | ONLY when :raw-text was passed (key absent otherwise)

=end table

C<telemetry-payload> builds the per-round-trip hook payload:

=begin table

Key                                                  | Presence
=====================================================|==========================================
attempt, backend-index, model-name, latency-ms       | always
success, stage                                       | always
error, error-class, error-status                     | always (value may be undefined)
prompt-tokens, completion-tokens, total-tokens       | when :$response exposes them, defined
model-used, finish-reason                            | when :$response exposes them, defined
cost, generation-id, provider-name, is-byok          | when :$response exposes them, defined

=end table

Note the asymmetry, which is the pre-existing contract: the C<error*>
keys are always present (undefined on success) so a sink can index them
unconditionally, while the response-derived keys are B<presence-gated>
so a sink can distinguish "the provider reported 0 completion tokens"
from "the provider reported nothing". An empty-string C<error> is
normalised to an undefined C<Str> for the same reason.

Response probing is duck-typed C<.?> throughout, so a backend whose
Response lacks C<cost> / C<generation-id> / C<provider-name> /
C<is-byok> (everything that is not OpenRouter) simply omits them, and a
test double needs only the accessors it wants to exercise.

=head1 CONSUMERS

=item L<LLM::Data::Inference::Task> — the original home of this code;
its C<classify-error> method now delegates here, and its exception
types subclass L<LLM::Chat::Retry::Exceptions>'.

=item C<LLM::Agent::Loop> — per-round-trip retry/fallback inside the
agent loop, including mid-stream failures.

=item Any caller that wants Task's policy without Task's dependencies.

=head1 SEE ALSO

L<LLM::Chat::Retry::Exceptions>, L<LLM::Chat::Backend::Response>
(the C<error-class> / C<error-status> pair this classifies).

=end pod

unit module LLM::Chat::Retry;

#|( Classify a failure by its structured error shape (as set on
    C<Response._set-error-info> by the backend) into one of three
    buckets: C<'abort'>, C<'retry-same'>, or C<'advance'>. See the
    module Pod for the full rule table. Pure function: same inputs,
    same answer, no state.

    C<:$error-class> and C<:$error-status> are both allowed to be
    undefined — an absent class is treated as 'unknown' (retry-same)
    and an absent status inside an 'http' class as 0 (advance), so a
    caller can forward a Response's fields blind. )
our sub classify-error(
	Str :$error-class,
	Int :$error-status,
	Bool :$parser-failed = False,
	--> Str
) is export {
	return 'advance' if $parser-failed;
	given $error-class // 'unknown' {
		when 'http' {
			given $error-status // 0 {
				when 400 | 401 | 402 | 403 | 404 { return 'abort' }
				when 429                         { return 'advance' }
				when 500..599                    { return 'retry-same' }
				default                          { return 'advance' }
			}
		}
		when 'timeout'    { return 'advance' }
		when 'connection' { return 'retry-same' }
		when 'response'   { return 'advance' }
		default           { return 'retry-same' }
	}
}

#|( Seconds to wait before retry number C<$retry-n> (1-based):
    C<min(2 ** ($retry-n - 1) + jitter, $cap)>.

    C<:$jitter> defaults to a fresh C<rand * 0.5> draw per call — the
    anti-thundering-herd spread that keeps N batch workers from
    retrying the same upstream in the same second. Pass an explicit
    C<:jitter(0e0)> for deterministic tests, or a larger value for
    larger fleets. C<:$cap> (default 30 s) bounds the exponential so a
    long chain cannot sleep for hours. )
our sub retry-backoff(
	Int:D $retry-n where * >= 1,
	Num(Real) :$cap = 30e0,
	Num(Real) :$jitter,
	--> Num:D
) is export {
	my Num $spread = $jitter // rand * 0.5;
	min((2 ** ($retry-n - 1)).Num + $spread, $cap);
}

#|( Sleep C<$seconds>, in C<$chunk>-sized slices, checking C<&cancelled>
    before every slice INCLUDING the first. Returns True when the full
    duration was served and False the moment C<&cancelled> returns
    True — worst-case cancel latency is one chunk rather than one
    backoff.

    Never throws on its own account (an exception from C<&cancelled>
    itself propagates, deliberately: that hook is the caller's code and
    a broken one must not silently mean "never cancels"). Reporting
    rather than throwing keeps the exception type — which differs per
    layer — a decision for the caller:

        throw-cancelled unless sleep-with-cancel($wait, :&cancelled);

    A zero or negative C<$seconds> returns True without sleeping and
    without consulting C<&cancelled>; an absent C<&cancelled> makes it
    a plain chunked sleep. )
our sub sleep-with-cancel(
	Num(Real) $seconds,
	:&cancelled,
	Num(Real) :$chunk = 0.25e0,
	--> Bool:D
) is export {
	my Num $slept = 0e0;
	while $slept < $seconds {
		return False if &cancelled.defined && ?&cancelled();
		my Num $slice = min($chunk, $seconds - $slept);
		sleep $slice;
		$slept += $slice;
	}
	True;
}

#|( Build one entry for C<X::LLM::Chat::Retry::Exhausted>'s
    C<@.attempts>. C<raw-text> is the model's output where there was
    one worth keeping (parser failures, truncations); its key is
    ABSENT — not undefined — when C<:raw-text> is not passed, so
    consumers can use C<:exists> or C<.defined> interchangeably and a
    network failure never looks like an empty completion. )
our sub attempt-record(
	Int:D :$backend-index!,
	Str:D :$model!,
	Str:D :$error!,
	Str :$raw-text,
	--> Hash
) is export {
	my %rec = backend-index => $backend-index, model => $model,
		error => $error;
	%rec<raw-text> = $raw-text if $raw-text.defined;
	%rec;
}

#|( Build the flattened per-round-trip telemetry payload (the hash an
    C<&on-call-complete>-style hook receives). See the module Pod for
    the key/presence table.

    C<:$response> is duck-typed: every accessor is probed with C<.?>,
    so a Response that never heard of C<cost> / C<generation-id> /
    C<provider-name> / C<is-byok> simply contributes no such keys, and
    a test double needs only the accessors it cares to expose. An
    undefined C<:$response> contributes none of them at all.

    An empty-string C<:$error> is normalised to an undefined C<Str>:
    the key is always present, so "no error" must be expressible as a
    value rather than an absence. )
our sub telemetry-payload(
	Int:D :$attempt!,
	Int:D :$backend-index!,
	Str:D :$model-name!,
	Int :$latency-ms,
	Bool() :$success = False,
	Str:D :$stage = 'network',
	Str :$error,
	Str :$error-class,
	Int :$error-status,
	:$response,
	--> Hash
) is export {
	my %payload = (
		attempt       => $attempt,
		backend-index => $backend-index,
		model-name    => $model-name,
		latency-ms    => $latency-ms,
		success       => $success,
		stage         => $stage,
		error         => ($error.defined && $error.chars) ?? $error !! Str,
		error-class   => $error-class,
		error-status  => $error-status,
	);
	my $r = $response;
	if $r.defined {
		# OAI-spec usage — present on any LLM::Chat::Backend::Response.
		%payload<prompt-tokens>     = $r.?prompt-tokens     if $r.?prompt-tokens.defined;
		%payload<completion-tokens> = $r.?completion-tokens if $r.?completion-tokens.defined;
		%payload<total-tokens>      = $r.?total-tokens      if $r.?total-tokens.defined;
		%payload<model-used>        = $r.?model-used        if $r.?model-used.defined;
		%payload<finish-reason>     = $r.?finish-reason     if $r.?finish-reason.defined;
		# Provider-specific extras — only on Response subclasses that
		# expose them (e.g. LLM::Chat::Backend::Response::OpenRouter).
		# `.?` returns Nil for Responses without the accessor, so the
		# presence-gated contract holds for any backend.
		%payload<cost>           = $r.?cost           if $r.?cost.defined;
		%payload<generation-id>  = $r.?generation-id  if $r.?generation-id.defined;
		%payload<provider-name>  = $r.?provider-name  if $r.?provider-name.defined;
		%payload<is-byok>        = $r.?is-byok        if $r.?is-byok.defined;
	}
	%payload;
}
