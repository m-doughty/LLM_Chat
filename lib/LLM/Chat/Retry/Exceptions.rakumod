=begin pod

=head1 NAME

LLM::Chat::Retry::Exceptions - shared typed failures for retry/fallback loops

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Chat::Retry;
use LLM::Chat::Retry::Exceptions;

my @attempts;
my $bucket = classify-error(:error-class<http>, :error-status(500));
@attempts.push: attempt-record(
    :backend-index(0), :model<gpt-4o-mini>, :error('http 500: upstream'),
);

# ... chain exhausted ...
X::LLM::Chat::Retry::Exhausted.new(
    attempts => @attempts,
    summary  => "all 1 backend(s) exhausted.\n  {@attempts[0]<error>}",
).throw;

=end code

Catching, with the subclasses first — a C<when> chain takes the first
matching arm, and C<Truncated> / C<TimedOut> B<are> C<Exhausted>s:

=begin code :lang<raku>

CATCH {
    when X::LLM::Chat::Retry::Cancelled {
        # The caller asked for this — clean up quietly.
    }
    when X::LLM::Chat::Retry::Truncated {
        note "every attempt hit the token budget:\n{.message}";
    }
    when X::LLM::Chat::Retry::TimedOut {
        note "the chain ran out of time:\n{.message}";
    }
    when X::LLM::Chat::Retry::Exhausted {
        for .attempts.grep(*.<raw-text>.defined) -> %a {
            note "model %a<model> said:\n%a<raw-text>";
        }
    }
}

=end code

=head1 DESCRIPTION

The four exception types every retry/fallback loop in this ecosystem
throws, factored out of L<LLM::Data::Inference::Task> so that
C<LLM::Chat>-level consumers (C<LLM::Agent::Loop>, bespoke chains, an
app's own executor) can throw and catch the B<same> types instead of
each inventing a private hierarchy that nothing downstream can match
on.

They are deliberately dependency-free: this module imports nothing but
core Raku, so an exception can travel through any layer without
dragging a backend, a Response, or an HTTP client behind it.

=head2 The four types

=item B<C<X::LLM::Chat::Retry::Exhausted>> — every backend in the chain
was tried without producing a usable result. Carries C<@.attempts> (one
record per recorded failure, in order) and a required C<$.summary>,
which is also its C<.message>. The summary is the human-readable
aggregate; the records are the machine-readable detail, including the
B<raw model output> for parser failures, so a caller can show the user
what the model actually produced instead of only "parser: unexpected
']'".

=item B<C<X::LLM::Chat::Retry::Truncated>> — a B<subclass> of
C<Exhausted>, thrown in its place when at least one attempt in the
exhausted chain was cut off by the completion budget (the provider
reported C<finish_reason> C<'length'>) rather than producing something
unusable. Being a subclass is the whole point: existing C<Exhausted>
handlers — dead-letter routing, CLI error reporting, exhaustion hooks —
keep catching it unchanged, while callers who care can add a narrower
arm saying "this one is fixable: raise the budget". It adds no
attributes; the lever belongs in the C<summary>, and truncated attempt
records carry their partial output as C<raw-text>.

=item B<C<X::LLM::Chat::Retry::TimedOut>> — likewise a B<subclass> of
C<Exhausted>, thrown in its place when at least one attempt died on a
response deadline (a caller-side timeout firing mid-poll, or a backend
reporting error class C<'timeout'>). Same rationale: exhaustion by
deadline IS a chain failure and must keep flowing to every existing
C<Exhausted> handler, while callers who want to distinguish "fixable by
raising the deadline" from "the model can't do this" can match it
B<before> the C<Exhausted> arm.

=item B<C<X::LLM::Chat::Retry::Cancelled>> — the caller withdrew: an
C<is-cancelled>-style hook reported that nobody wants the result any
more, before a round-trip, between retries, or mid-call. Carries the
same C<@.attempts> so anything already produced stays inspectable.

=head2 Why C<Cancelled> is NOT an C<Exhausted>

Everything else in this file is a failure I<of the chain>; a cancel is
the caller's own intent. A handler that routes exhaustion to a
dead-letter queue, counts model failures, or opens an incident must not
have a user pressing Ctrl-C silently folded into those numbers — so
C<Cancelled> descends straight from C<Exception> and has to be caught
on purpose. That also means a bare C<when X::LLM::Chat::Retry::Exhausted>
arm can never swallow it by accident.

=head2 Precedence: C<Truncated> beats C<TimedOut>

A chain that saw B<both> a truncation and a deadline miss throws
C<Truncated>. It is the more specific diagnosis, and — see the advice
contract below — it is the B<deterministic> one: it declares
C<item-retryable> C<False>, which tells an orchestrator to stop
re-running the item rather than buying back retries that the truncation
guarantees will fail. Downgrading to C<TimedOut> would do exactly that.
Throwers that observed both pathologies should name both levers in the
C<summary>; they describe different fixes and suppressing one hides
half the diagnosis.

=head2 Attempt record shape

C<@.attempts> holds one C<Hash> per recorded failure, in the order they
happened. L<LLM::Chat::Retry>'s C<attempt-record> builds them:

=begin code :lang<raku>

%(
    backend-index => 0,          # 0-based position in the chain
    model         => 'gpt-4o',   # model name, or 'unknown'
    error         => '[backend 0 gpt-4o] http 500: upstream on fire',
    raw-text      => '{"a": 1',  # OPTIONAL — key ABSENT when there is
                                 # no body worth keeping (network
                                 # failures have none); present for
                                 # parser failures and truncations
)

=end code

The C<raw-text> key is B<absent>, not undefined, when it does not
apply, so C<.grep(*.<raw-text>.defined)> and C<%a<raw-text>:exists>
both work and neither reports a phantom empty body.

=head1 THE C<item-retryable> ADVICE CONTRACT

(This is the canonical home of the contract; it moved here from
L<LLM::Data::Inference::Exceptions> when the retry policy was factored
out, and the types there are now subclasses of these.)

An orchestration layer that re-runs failed work (C<LLM::Data::Pipeline>'s
item engine, a job queue, a supervisor loop) has no way of knowing
which of these deaths a blind re-roll could plausibly fix. Some of
them are B<deterministic>: re-issuing the identical request produces
the identical death, so the retries are pure latency and spend on the
way to the dead-letter queue.

An exception may therefore B<advise> the layer above it by exposing:

=begin code :lang<raku>

method item-retryable(--> Bool:D) { False }

=end code

The contract is duck-typed in both directions, deliberately:

=item B<Absent means retryable.> A consumer probes with C<.?> and
defaults to True, so every exception that has never heard of the
contract — including every exception in this distribution before
C<0.8.0> — keeps its full attempt budget.

=item B<No type dependency either way.> The consumer never imports a
retry type (it calls a method by name); this distribution never imports
the orchestrator. Any exception from any library can opt in.

=item B<It is advice, not control flow.> The layer above decides what
to do with it. Nothing in this distribution reads the method.

Only C<Truncated> declares it, as C<False>: a completion cut off by
C<max_tokens> will be cut off at exactly the same place on the next
blind re-roll, because C<max_tokens> is per-backend C<Settings> state
that a re-run cannot change. C<TimedOut> deliberately does B<not>
declare it — a deadline miss is genuinely transient (a slow provider,
a queued request, an upstream hiccup), so it keeps the full item
budget. Plain C<Exhausted> abstains for the same reason: the base
exhaustion carries no evidence that a re-run is pointless.

A consumer reads it like this:

=begin code :lang<raku>

my Bool $retry = $exception.?item-retryable // True;

=end code

=head1 SUBCLASSING

Distributions that want their own names in the type tree — for
backwards compatibility, or just for a message that says which layer
died — subclass these and inherit the whole contract:

=begin code :lang<raku>

class X::My::Chain::Exhausted is X::LLM::Chat::Retry::Exhausted { }
class X::My::Chain::Truncated
    is X::My::Chain::Exhausted
    is X::LLM::Chat::Retry::Truncated { }   # keeps item-retryable

=end code

The diamond is intentional and resolves cleanly: C<X::My::Chain::Truncated>
smartmatches both C<X::My::Chain::Exhausted> and
C<X::LLM::Chat::Retry::Truncated>, so old handlers and new ones both
fire. One gotcha when overriding methods in such a subclass: use the
public accessor C<@.attempts>, never the private C<@!attempts> — the
attribute lives in the parent class and is not visible to the child.

=head2 Why these are plain global classes, not C<is export>ed ones

There is no C<unit module> here and no C<is export> trait, so C<use>-ing
this file simply makes C<X::LLM::Chat::Retry::*> resolvable — the same
way core's C<X::AdHoc> is. That is deliberate, and it is not the style
L<LLM::Data::Inference::Exceptions> uses.

C<is export> on a nested-name class exports it under its B<leaf> name
as well: a module doing C<class X::Foo::Exhausted is export> puts a
bare C<Exhausted> into every importer's lexical scope. Two such modules
therefore cannot be imported into the same scope at all —
C<"Cannot import the following symbols … because they already exist:
'Exhausted', 'Truncated', …"> — which would make it impossible to write
the very handler this module exists to enable, one that matches a
subclass hierarchy against the shared one. Declaring the classes
globally instead costs nothing (they are reachable by their real names,
which are also their C<.^name>s) and keeps this module compatible with
every other exception module in the ecosystem, present and future.

=end pod

#|( Thrown when a whole backend chain is exhausted. C<attempts> holds
    one Hash per recorded failure, in order:
      * backend-index — 0-based position in the chain
      * model         — model name (or 'unknown')
      * error         — the failure description
      * raw-text      — the full model output, present only when there
                        was a body worth keeping (parser failures,
                        truncations); network-level failures have none
    C<message> returns C<summary> unchanged, so string-matching callers
    see exactly what the thrower composed.

    Deliberately does NOT define C<item-retryable>: the base exhaustion
    carries no evidence that a re-run is pointless, and the advice
    contract reads an absent method as "retryable" (see the module
    Pod). Subclasses that DO have that evidence declare it —
    C<Truncated> does. )
class X::LLM::Chat::Retry::Exhausted is Exception {
	has @.attempts;
	has Str:D $.summary is required;

	method message(--> Str) { $!summary }
}

#|( Thrown INSTEAD of C<Exhausted> when at least one attempt in the
    exhausted chain was cut off by the completion budget — the provider
    reported C<finish_reason> 'length'. Same shape as C<Exhausted> (no
    extra attributes): the truncation is described in C<summary>, which
    should also name the levers (raise C<max_tokens>, add a
    larger-budget fallback backend, or shrink the request), and each
    truncated attempt record keeps whatever partial output arrived as
    C<raw-text>.

    Deliberately a SUBCLASS of C<Exhausted>, unlike C<Cancelled>:
    truncation IS a chain failure and belongs in the dead-letter queue,
    so every existing handler must keep working untouched. The subclass
    only exists so callers who want to distinguish "fixable by raising
    the budget" from "the model produced garbage" can, by matching it
    BEFORE the C<Exhausted> arm.

    Wins over C<TimedOut> when a chain saw both: it is the more
    specific diagnosis, and it is the deterministic one. )
class X::LLM::Chat::Retry::Truncated
	is X::LLM::Chat::Retry::Exhausted {
	#|( Advice to an orchestration layer that re-runs failed work: do
	    NOT spend further item attempts on this one. A truncation is
	    DETERMINISTIC — C<max_tokens> is per-backend C<Settings> state,
	    so an identical re-issued request overruns at exactly the same
	    place, and every blind re-run is pure latency and spend on the
	    way to the same dead-letter record. The lever is a config change
	    (bigger budget, bigger-budget fallback, smaller request), which
	    a re-run cannot make.

	    Duck-typed advice, not control flow: nothing in this
	    distribution reads it, consumers probe with C<.?> and default to
	    True when it is absent, and neither side imports the other. See
	    the module Pod. )
	method item-retryable(--> Bool:D) { False }
}

#|( Thrown INSTEAD of C<Exhausted> when at least one attempt in the
    exhausted chain died on a response deadline — a caller-side timeout
    firing while the in-flight response was polled (the pending call
    should be aborted through C<Backend.cancel> first), or a backend
    reporting error class 'timeout' itself. Same shape as C<Exhausted>
    (no extra attributes); the deadline that was hit and its levers
    belong in C<summary>.

    A SUBCLASS of C<Exhausted> for exactly the reasons C<Truncated> is
    one: a chain that ran out of time is a chain failure, belongs in
    the dead-letter queue, and must keep reaching every handler that
    already exists. The subclass earns its keep by letting a caller say
    "raise the deadline / use a faster backend" instead of "the model
    can't do this" — match it BEFORE the C<Exhausted> arm.

    Deliberately does NOT define C<item-retryable>. Unlike a
    truncation, a deadline miss is genuinely transient: the same
    request against the same chain a minute later routes to a different
    upstream provider, or simply is not queued behind someone else's
    batch. It keeps the full item-retry budget. )
class X::LLM::Chat::Retry::TimedOut
	is X::LLM::Chat::Retry::Exhausted { }

#|( Thrown when a cancellation hook reports that the caller withdrew
    mid-run. C<attempts> matches C<Exhausted>'s shape (whatever
    failures were recorded before the cancel landed — possibly none).
    Deliberately NOT a subclass of C<Exhausted>: handlers that treat
    exhaustion as a model failure must not accidentally swallow a user
    cancel. )
class X::LLM::Chat::Retry::Cancelled is Exception {
	has @.attempts;

	method message(--> Str) {
		'LLM call cancelled by caller'
		~ (@!attempts
			?? " after {@!attempts.elems} recorded attempt(s)"
			!! '');
	}
}
