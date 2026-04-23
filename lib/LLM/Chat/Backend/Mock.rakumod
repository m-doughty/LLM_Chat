=begin pod

=head1 NAME

LLM::Chat::Backend::Mock - Canned-response backend for tests

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Chat::Backend::Mock;
use LLM::Chat::Backend::Settings;

# Single canned response
my $mock = LLM::Chat::Backend::Mock.new(
    settings => LLM::Chat::Backend::Settings.new,
    responses => ['hello from the mock backend'],
);

# A sequence — each call pops the next one
my $mock2 = LLM::Chat::Backend::Mock.new(
    settings  => LLM::Chat::Backend::Settings.new,
    responses => [
        'first answer',
        'second answer',
        'third answer',
    ],
);

# Streaming: tokens arrive split by whitespace (default).
# Customise with :token-splitter if you want per-character streaming or
# a specific token boundary.
my $stream = $mock2.chat-completion-stream(@messages);
react {
    whenever $stream.supply -> $token {
        print $token;
    }
    whenever $stream.supply.done { say "done" }
}

=end code

=head1 DESCRIPTION

Non-network backend for use in tests. Returns pre-configured responses
in order — one response per C<chat-completion>/C<text-completion> call.
When the queue is exhausted, subsequent calls either repeat the last
response (default) or fail (C<:fail-on-empty>).

For streaming calls, the response is split into tokens and emitted
through the normal C<Supplier> path. By default each whitespace-
separated word becomes a token; override C<:token-splitter> for
finer-grained control (per-character streaming, specific tokenisation,
etc.).

B<Not safe for production use.> Doesn't talk to any real model; any
parameter in C<Settings> is ignored (temperature, top_p, stop, etc.).
Only the raw text in C<responses> gets returned.

=head1 ATTRIBUTES

=item C<@.responses> — array of Str, one per expected call.
=item C<$.fail-on-empty> — when True, calling beyond the queue fails instead of repeating the last response. Default False.
=item C<$.stream-delay> — seconds between tokens in streaming mode. Default 0 (emit as fast as possible).
=item C<&.token-splitter> — sub that takes a Str and returns a list of tokens. Default splits on whitespace and preserves spacing by re-appending a space after each token except the last.
=item C<&.error-producer> — optional C<(Int $call-index --> Hash)> callback. When it returns a defined hash, that call is scripted to fail. Used to exercise the Task fallback policy. See L</SIMULATING FAILURES>.
=item C<$.call-index> — monotonically-increasing per-backend call count, bumped on every completion call whether it succeeded or failed. Distinct from the internal response cursor — tests can read this to assert call counts without reasoning about the response queue.

=head1 SIMULATING FAILURES

Pass C<&.error-producer> to script per-call failures. Every
C<chat-completion> invocation calls it with the 0-based call index.
Returning a defined hash fails the call; returning C<Nil> (or an
undefined value) lets the call proceed normally through the
C<@.responses> queue.

=begin code :lang<raku>

# Fail the first two calls with retryable errors, succeed on the third
my $mock = LLM::Chat::Backend::Mock.new(
    settings  => LLM::Chat::Backend::Settings.new,
    responses => ['finally'],
    error-producer => -> $i {
        when $i == 0 { { class => 'connection', message => 'ECONNRESET' } }
        when $i == 1 { { class => 'http', status => 503, message => 'bad gateway' } }
        default      { Nil }
    },
);

=end code

Recognised C<class> values match the Response error classification:
C<'http'> (with numeric C<status>), C<'timeout'>, C<'connection'>,
C<'response'> (malformed / empty body / finish-reason failure), and
C<'unknown'>. Failed calls DO NOT consume a slot from C<@.responses>,
so the queue addresses only the successful calls regardless of where
failures fire.

=head1 RECORDING CALLS

Every completion call is appended to C<@.recorded-calls> as a hash with:

=item C<kind> — 'chat-completion', 'chat-completion-stream', 'text-completion', or 'text-completion-stream'
=item C<messages> — the C<@messages> array that was passed in
=item C<tools> — the C<@tools> array (empty if none were passed)
=item C<continuation> — for text-completion only, the flag value
=item C<response> — the Str that was returned
=item C<at> — Instant when the call was made

Tests can assert on what reached the backend rather than just what came
back. Typical pattern:

=begin code :lang<raku>

my $mock = LLM::Chat::Backend::Mock.new(
    settings  => LLM::Chat::Backend::Settings.new,
    responses => ['ok'],
);

# ... code under test calls $mock.chat-completion-stream(@msgs) ...

is $mock.recorded-calls.elems, 1, 'one call';
is $mock.recorded-calls[0]<kind>, 'chat-completion-stream';
is $mock.recorded-calls[0]<messages>[0].role, 'system', 'first message is system prompt';
is $mock.recorded-calls[0]<messages>[*-1].content, 'hello', 'last message is user turn';

=end code

Use C<clear-recorded-calls> to reset the log between phases of a test.

=end pod

use LLM::Chat::Backend;
use LLM::Chat::Backend::Response;
use LLM::Chat::Backend::Response::Stream;
use LLM::Chat::Conversation::Message;

use UUID::V4;

unit class LLM::Chat::Backend::Mock is LLM::Chat::Backend;

has Str @.responses is rw;
has Bool $.fail-on-empty = False;
has Numeric $.stream-delay = 0;

#|( Optional per-call usage payload. When non-empty, every
    completion call invokes C<Response._set-usage(|%.fake-usage)>
    on the freshly-minted Response so telemetry tests can assert on
    a concrete shape. Accepts the same keys as
    C<Response._set-usage>: C<prompt>, C<completion>, C<total>,
    C<cost>, C<model>, C<id>. Left empty by default so non-
    telemetry tests don't drift. )
has %.fake-usage;

#|( Optional prompt-aware responder. When set, each call invokes
    C<&responder(@messages)>; a defined Str return value is used
    as the response, while an undefined return falls through to
    the FIFO C<@.responses> cursor path. Lets tests mix the two
    modes: intercept specific call shapes (e.g. a per-kind LoreScan
    dispatch arriving in non-deterministic order) while letting
    the rest of the pipeline consume canned responses positionally. )
has &.responder;

#|( Optional failure-producer for fallback / retry tests. Called with
    the 0-based per-backend call index (C<$.call-index> before the
    increment). A defined Hash return flags this call as failed; an
    undefined return proceeds normally. Expected hash shape:
      * C<class>   — one of 'http', 'timeout', 'connection', 'response',
                     'unknown'. Required. Stored on the Response via
                     C<_set-error-info>.
      * C<status>  — Int HTTP status code. Optional (relevant when
                     C<class eq 'http'>).
      * C<message> — Str failure message passed to C<$response.quit>.
                     Optional; defaults to "Mock error".
    Failed calls DO NOT consume a slot from C<@.responses>, so tests
    can cleanly interleave scripted errors with scripted successes. )
has &.error-producer;

# Serialises cursor advancement + recorded-calls appends so concurrent
# callers (e.g. a WorkerPool hitting the mock from N threads) can't race
# on the SELECT-MAX-then-INSERT-style sequence in !next-response or
# produce interleaved @!recorded-calls entries.
has Lock $!mock-lock = Lock.new;

#| Log of every completion call this backend handled. Inspect in tests
#| to assert on what the code under test sent to inference. See the
#| RECORDING CALLS section of the POD for the hash shape.
has @.recorded-calls;
#| Delay before the first emission, in seconds. Default 10ms — gives
#| async callers time to attach their taps before tokens start flowing,
#| mirroring the network latency a real backend introduces. Set to 0
#| for tests that consume .msg after waiting for done, where tap
#| attachment order doesn't matter.
has Numeric $.initial-delay = 0.01;
has &.token-splitter = &default-splitter;

# Track which canned response is next.
has UInt $!cursor = 0;
# Monotonically-increasing call index (0-based), incremented on every
# completion call regardless of whether it succeeds, fails, or is
# intercepted by the responder. Distinct from C<$!cursor>, which only
# advances on successful canned-response consumption — that split lets
# C<&.error-producer> address specific call numbers without the
# response queue shifting underneath it.
has UInt $.call-index = 0;
# Remember cancellations so late-emitting streams skip.
has %!cancelled;

sub default-splitter(Str $text --> List) {
    return ('',) unless $text.chars;
    # Split on whitespace, keep the trailing space on each token so the
    # reassembled stream is character-identical to the input.
    my @words = $text.split(/\s+/, :skip-empty);
    my @out;
    for @words.kv -> $i, $w {
        @out.push: $w ~ (($i == @words.end) ?? '' !! ' ');
    }
    @out.List;
}

method !next-response(--> Str) {
    $!mock-lock.protect: {
        if $!cursor >= @!responses.elems {
            die 'Mock backend: canned responses exhausted' if $!fail-on-empty;
            # Repeat last
            return @!responses ?? @!responses[*-1] !! '';
        }
        my $r = @!responses[$!cursor];
        $!cursor++;
        $r;
    }
}

#| The raw text that will be returned by the next completion call.
#| Useful for assertions in tests that want to know "what's about to
#| be returned" without popping the queue.
method peek-next-response(--> Str) {
    return @!responses[$!cursor] if $!cursor < @!responses.elems;
    @!responses ?? @!responses[*-1] !! '';
}

#| Reset the response cursor to the start of the queue.
method reset() { $!cursor = 0 }

#| Empty the recorded-calls log. Call between test phases when you
#| want to assert on calls from a specific window of activity.
method clear-recorded-calls() { @!recorded-calls = () }

# --- Non-streaming: emit whole response, mark done --------------------

method chat-completion(
    @messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
    :@tools,
    --> LLM::Chat::Backend::Response
) {
    my $id = uuid-v4;
    my $resp = LLM::Chat::Backend::Response.new(:$id, supplier => Supplier.new);
    $resp._set-usage(|%!fake-usage) if %!fake-usage.elems;

    # Capture the call index BEFORE running the error-producer so
    # the producer sees the same index the recorded-calls entry
    # will carry. Incremented unconditionally so failed calls still
    # bump the counter.
    my $this-index;
    $!mock-lock.protect: {
        $this-index = $!call-index;
        $!call-index++;
    }

    my $err-info;
    if &!error-producer.defined {
        $err-info = &!error-producer($this-index);
    }

    if $err-info.defined && ($err-info<class>:exists) {
        # Scripted failure. Match OpenAICommon's pattern: populate
        # structured error info before quitting the supplier so the
        # Task fallback policy can classify the failure.
        my $cls = $err-info<class>;
        my $sts = $err-info<status>:exists ?? $err-info<status>.Int !! Int;
        my $msg = $err-info<message>:exists ?? $err-info<message> !! 'Mock error';
        $resp._set-error-info(class => $cls, status => $sts);

        $!mock-lock.protect: {
            @!recorded-calls.push: {
                kind       => 'chat-completion',
                messages   => @messages.clone,
                tools      => @tools.clone,
                response   => Nil,
                error      => { class => $cls, status => $sts, message => $msg },
                call-index => $this-index,
                at         => now,
            };
        }

        my $delay = $!initial-delay;
        start {
            sleep $delay if $delay > 0;
            $resp.supplier.quit($msg);
        }

        return $resp;
    }

    my $text;
    if &!responder.defined {
        $text = &!responder(@messages);
    }
    $text //= self!next-response;

    $!mock-lock.protect: {
        @!recorded-calls.push: {
            kind       => 'chat-completion',
            messages   => @messages.clone,
            tools      => @tools.clone,
            response   => $text,
            call-index => $this-index,
            at         => now,
        };
    }

    # Emit asynchronously after a short delay so consumers have time
    # to attach taps — mirrors network latency in real backends.
    my $delay = $!initial-delay;
    start {
        sleep $delay if $delay > 0;
        $resp.supplier.emit($text);
        $resp.supplier.done;
    }

    $resp;
}

method text-completion(
    @messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
    Bool $continuation = False,
    --> LLM::Chat::Backend::Response
) {
    # Delegate to chat-completion for the emission mechanics, but
    # overwrite the recorded-call kind so tests can distinguish the
    # two code paths.
    my $resp = self.chat-completion(@messages);
    @!recorded-calls[*-1]<kind>         = 'text-completion';
    @!recorded-calls[*-1]<continuation> = $continuation;
    $resp;
}

# --- Streaming: tokenise response and emit with optional delay --------

method chat-completion-stream(
    @messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
    :@tools,
    --> LLM::Chat::Backend::Response::Stream
) {
    my $id = uuid-v4;
    my $resp = LLM::Chat::Backend::Response::Stream.new(:$id, supplier => Supplier.new);
    $resp._set-usage(|%!fake-usage) if %!fake-usage.elems;
    my $text;
    if &!responder.defined {
        $text = &!responder(@messages);
    }
    $text //= self!next-response;
    my @tokens = &!token-splitter($text);
    my $delay  = $!stream-delay;
    my %cancelled := %!cancelled;

    $!mock-lock.protect: {
        @!recorded-calls.push: {
            kind     => 'chat-completion-stream',
            messages => @messages.clone,
            tools    => @tools.clone,
            response => $text,
            at       => now,
        };
    }

    my $initial = $!initial-delay;
    start {
        sleep $initial if $initial > 0;
        for @tokens -> $tok {
            last if %cancelled{$id};
            $resp.supplier.emit($tok);
            sleep $delay if $delay > 0;
        }
        # If we were cancelled, the caller's cancel() path closes the
        # supplier with quit(). Don't also call done() — that'd be a
        # double-close and the supplier would throw on the second one.
        $resp.supplier.done unless %cancelled{$id};
    }

    $resp;
}

method text-completion-stream(
    @messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
    Bool $continuation = False,
    --> LLM::Chat::Backend::Response::Stream
) {
    my $resp = self.chat-completion-stream(@messages);
    @!recorded-calls[*-1]<kind>         = 'text-completion-stream';
    @!recorded-calls[*-1]<continuation> = $continuation;
    $resp;
}

method cancel(LLM::Chat::Backend::Response $resp) {
    %!cancelled{$resp.id} = True;
    $resp.cancel;
}
