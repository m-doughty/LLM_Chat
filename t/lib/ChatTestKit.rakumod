=begin pod

=head1 NAME

ChatTestKit - fixture-server plumbing shared by the HTTP-level tests

=head1 DESCRIPTION

Several test files need the same three things: a real
C<Cro::HTTP::Server> on a port nothing else owns, a way to wait for a
Promise that gives up loudly instead of hanging the suite, and a way to
drive a C<LLM::Chat::Backend::Response> to its terminal state. Those
live here so the files that need them stay about the behaviour under
test.

=head2 The C</ping> contract

C<boot> picks a port itself, because Cro cannot report the port an
OS-assigned C<:port(0)> landed on, and a port we picked might already
belong to something else. The only honest proof that the listener
answering on it is ours is a request only our application would serve,
so every application handed to C<boot> must answer C<GET /ping> with a
2xx:

=begin code :lang<raku>
my $app = route {
    get -> 'ping' { content 'text/plain', 'pong' }
    # ... the routes actually under test ...
}

my ($server, $port) = boot($app);
LEAVE { try $server.stop with $server }
=end code

=end pod

use Cro::HTTP::Client;
use Cro::HTTP::Server;

unit module ChatTestKit;

#| How long any single wait here may take before it is called a
#| failure rather than a slow machine.
constant TIMEOUT is export = 30;

#| Await $promise, giving up (loudly) rather than blocking forever.
sub timed($promise, Str:D $what) is export {
    await Promise.anyof($promise, Promise.in(TIMEOUT));
    die "Timed out after {TIMEOUT}s waiting for $what" if $promise.status === Planned;
    $promise;
}

#| Drive a blocking completion to its terminal state. The Response's
#| supply Promise is broken (not kept) on quit, so failures have to be
#| tolerated here and inspected by the caller.
sub settled($response, Str:D $what) is export {
    try timed($response.supply.Promise, $what);
    $response;
}

#| Drive a STREAMING completion to its terminal state.
#|
#| Deliberately not C<settled>: C<$response.supply.Promise> installs a
#| fresh tap on a live supply, and a stream that has already finished
#| never re-delivers its C<done> to a latecomer — the wait would then
#| burn the whole timeout and die on a stream that in fact completed
#| perfectly. Against a loopback fixture that can answer in well under
#| a millisecond that is a live race, and a sweep of a few hundred
#| streams will find it. C<is-done> is set from the tap the Response
#| installs on itself at construction, so it is true for a completed
#| stream and for a quit one however fast either happened.
sub stream-settled($response, Str:D $what) is export {
    my $deadline = now + TIMEOUT;
    until $response.is-done {
        die "Timed out after {TIMEOUT}s waiting for $what" if now > $deadline;
        sleep 0.002;
    }
    $response;
}

#| Start $app on a random high port, retrying in case something else
#| already owns the one we picked. Returns C<($server, $port)>; the
#| caller is responsible for stopping the server. See the C</ping>
#| contract above.
sub boot($app --> List) is export {
    my $last-error = 'no attempt made';

    for ^5 {
        my $port   = (20000 .. 40000).pick;
        my $server = Cro::HTTP::Server.new(
            :host<127.0.0.1>, :$port, application => $app,
        );

        my Bool $listening = True;
        {
            CATCH {
                default {
                    $last-error = .message.lines.head;
                    $listening  = False;
                }
            }
            $server.start;
        }

        if $listening {
            my $probe = Cro::HTTP::Client.new(:!persistent, :http<1.1>)
                .get("http://127.0.0.1:$port/ping");
            await Promise.anyof($probe, Promise.in(10));
            return ($server, $port) if $probe.status === Kept;

            $last-error = $probe.status === Broken
                ?? $probe.cause.message.lines.head
                !! 'probe request timed out';
            try $server.stop;
        }
    }

    die "Could not start the fixture server on any port: $last-error";
}
