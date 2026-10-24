=begin pod

=head1 NAME

LLM::Chat::Test::Kit - fixture-server plumbing shared by the HTTP-level tests

=head1 SYNOPSIS

=begin code :lang<raku>
use LLM::Chat::Test::Kit;

my $server = raw-server(-> $request {
    given $request.method, $request.path {
        when ('POST', '/v1/chat/completions') {
            $request.json<stream>
                ?? %( type => 'text/event-stream', chunks => @sse-frames )
                !! %( body => to-json(%reply) );
        }
        default { %( status => 404, body => '' ) }
    }
});
LEAVE $server.stop;

my $backend = LLM::Chat::Backend::OpenAICommon.new(
    api_url  => $server.url ~ '/v1',
    settings => LLM::Chat::Backend::Settings.new,
);

my $response = stream-settled($backend.chat-completion-stream(@messages), 'the stream');
=end code

=head1 DESCRIPTION

The HTTP-level tests need the same few things: a real HTTP server on a
port nothing else owns, a way to wait for a Promise that gives up loudly
instead of hanging the suite, and a way to drive a
C<LLM::Chat::Backend::Response> to its terminal state. Those live here
so the files that need them stay about the behaviour under test.

The server is C<raw-server>: a small HTTP/1.1 server written directly on
C<IO::Socket::Async>, which finishes writing a response before it closes
anything. Not Cro's own HTTP server, because every client this
distribution makes asks the server to close the connection after its
response (C<Connection: close>), and on that path Cro's server
occasionally loses the end of a response on a machine that is busy
enough: a streamed body cut short at a chunk boundary, or never sent at
all. Nearly every assertion an HTTP-level test makes rests on the whole
response arriving.

This is test support, not library surface. It ships inside the dist's
own namespace (rather than under C<t/lib>) deliberately, so that C<zef
install>'s test phase precompiles it as part of C<lib/> staging before
any test file runs. A C<t/lib> CompUnit repo starts cold on a fresh
C<zef install>, and parallel test files pulling the fixture's
dependency chain into that cold store can race and fail the install
outright; moving test support into C<lib/> under a C<::Test> namespace
is the fleet-wide fix for that failure class.

=head2 Requests and answers

C<raw-server> listens on a port the OS picks, on 127.0.0.1, and calls
the responder with a C<RawRequest> for each request — C<.method>,
C<.path> (without the query string), C<.query>, C<.headers> (names
lower-cased), C<.header($name)>, C<.body> (a Blob), C<.text>, C<.json>,
C<.wants-close> — and the responder returns a Hash describing the
answer:

=item C<status> — default 200.
=item C<type> — the Content-Type, written exactly as given; default
C<application/json>. An undefined type sends no Content-Type at all.
=item C<headers> — further headers, a list of Pairs.
=item C<body> — a Str (sent as UTF-8) or a Blob, sent with a
Content-Length.
=item C<chunks> — instead of a body: a list, or a Supply, of Strs or
Blobs, each sent as one HTTP chunk. A Supply is followed for as long
as it emits; when the client hangs up first, the Supply's tap is closed,
so its C<CLOSE> phaser is where a test learns that it happened.
=item C<delay> — seconds to wait before the response headers, or a
Promise to wait for (a server that answers when the test lets it).

A bare Str or Blob is short for C<%( body => ... )>. An answer the server
cannot use, or a responder that dies, is answered with a 500 and
recorded in C<.errors>, so a fixture mistake fails the test instead of
hanging it. Connections are kept open between requests unless the
request asks for C<Connection: close>; then the server closes the
connection once the response's last write has completed, as RFC 9112
requires. C<.requests> lists what arrived, C<.accepted> and
C<.open-connections> count connections, C<.url> is the base URL to point
a backend at, and C<.stop> closes everything.

A server that streams forever and notices the client hanging up:

=begin code :lang<raku>
my $hung-up = Promise.new;
my $server = raw-server(-> $ {
    %( type => 'text/event-stream', chunks => supply {
        whenever Supply.interval(0.01) -> $n { emit "data: tick $n\n\n" }
        CLOSE { $hung-up.keep(True) unless $hung-up.status }
    } );
});
=end code

=end pod

use JSON::Fast;

use LLM::Chat::ExceptionText;

unit module LLM::Chat::Test::Kit;

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

# --- Raw servers --------------------------------------------------------

# Reason phrases for the status line. A code not listed here still gets
# a well-formed line, with "Status" as its phrase.
my constant REASONS = %(
	200 => 'OK',                   201 => 'Created',
	204 => 'No Content',           400 => 'Bad Request',
	401 => 'Unauthorized',         402 => 'Payment Required',
	403 => 'Forbidden',            404 => 'Not Found',
	408 => 'Request Timeout',      413 => 'Payload Too Large',
	422 => 'Unprocessable Entity', 429 => 'Too Many Requests',
	500 => 'Internal Server Error', 502 => 'Bad Gateway',
	503 => 'Service Unavailable',  504 => 'Gateway Timeout',
);

# The keys a responder's answer may carry. See "Requests and answers" above.
my constant ANSWER-KEYS = set <status type headers body chunks delay>;

#| One request a raw server received: what came over the wire, parsed
#| just far enough to answer it.
class RawRequest {
	has Str:D  $.method is required;
	#| The request target's path, without its query string.
	has Str:D  $.path is required;
	#| The query string, without its C<?>; empty when there was none.
	has Str:D  $.query = '';
	#| Header values by lower-cased name; repeats are joined with C<, >.
	has        %.headers;
	has Blob:D $.body = Blob.new;

	#| The value of header $name, in any case, or Str when it is absent.
	method header(Str:D $name --> Str) {
		%!headers{$name.lc} // Str;
	}

	#| The body as UTF-8 text.
	method text(--> Str:D) {
		$!body.decode('utf-8');
	}

	#| The body parsed as JSON.
	method json() {
		from-json(self.text);
	}

	#| Whether the client asked for the connection to close after this
	#| request's response — what a non-persistent Cro client always asks.
	method wants-close(--> Bool:D) {
		so (self.header('connection') // '').lc.split(',').map(*.trim).grep('close');
	}
}

my constant LAST-CHUNK = "0\r\n\r\n".encode('latin-1');

my sub as-blob($piece --> Blob:D) {
	$piece ~~ Blob ?? $piece !! $piece.Str.encode('utf-8');
}

my sub chunk-of(Blob:D $data --> Blob:D) {
	($data.bytes.base(16) ~ "\r\n").encode('latin-1') ~ $data ~ "\r\n".encode('latin-1');
}

# Where the blank line that ends a request's headers starts in $buffer,
# searching from $from, or Int while it has not arrived. Byte arithmetic
# throughout: decoded, "\r\n" is one grapheme.
my sub header-end(Buf:D $buffer, Int:D $from = 0 --> Int) {
	for $from .. $buffer.elems - 4 -> $i {
		return $i if $buffer[$i] == 13 && $buffer[$i + 1] == 10
			&& $buffer[$i + 2] == 13 && $buffer[$i + 3] == 10;
	}
	Int;
}

# Take the first complete request off the front of $pending, or return
# RawRequest (the type object) while it is still incomplete. Bodies come
# with Content-Length or chunked; anything else has no body.
my sub take-request(Buf:D $pending --> RawRequest) {
	my $head-end = header-end($pending);
	return RawRequest without $head-end;
	my @lines = $pending.subbuf(0, $head-end).decode('latin-1').split("\r\n");
	my $start = @lines.shift // '';
	my %headers;
	for @lines -> $line {
		with $line.index(':') -> $colon {
			my $name = $line.substr(0, $colon).trim.lc;
			my $value = $line.substr($colon + 1).trim;
			%headers{$name} = %headers{$name}:exists ?? "%headers{$name}, $value" !! $value;
		}
	}
	my Int $at = $head-end + 4;
	my Blob $body;
	if (%headers<transfer-encoding> // '').lc.contains('chunked') {
		my Buf $decoded = Buf.new;
		loop {
			my $size-end = line-end($pending, $at);
			return RawRequest without $size-end;
			my $size = :16($pending.subbuf($at, $size-end - $at).decode('latin-1').split(';').head.trim || '0');
			$at = $size-end + 2;
			if $size == 0 {
				my $trailer-end = header-end($pending, $at - 2);
				return RawRequest without $trailer-end;
				$at = $trailer-end + 4;
				last;
			}
			return RawRequest if $pending.elems < $at + $size + 2;
			$decoded.append($pending.subbuf($at, $size));
			$at += $size + 2;
		}
		$body = $decoded;
	}
	else {
		my Int $length = (%headers<content-length> // '0').Int;
		return RawRequest if $pending.elems < $at + $length;
		$body = $pending.subbuf($at, $length);
		$at += $length;
	}
	$pending.splice(0, $at);
	my ($method, $target) = $start.split(' ', 3);
	$target //= '/';
	my ($path, $query) = $target.split('?', 2);
	RawRequest.new(
		method  => $method // '',
		path    => $path,
		query   => $query // '',
		:%headers,
		:$body,
	);
}

# Where the next "\r\n" at or after $from starts, or Int.
my sub line-end(Buf:D $buffer, Int:D $from --> Int) {
	for $from .. $buffer.elems - 2 -> $i {
		return $i if $buffer[$i] == 13 && $buffer[$i + 1] == 10;
	}
	Int;
}

#| An HTTP/1.1 server on IO::Socket::Async, answering each request with
#| whatever its responder returns. See "Requests and answers" above.
class RawServer {
	has      &.responder is required;
	has Int  $.port;
	has      $!listener;
	has      @!requests;
	has      @!errors;
	has      @!connections;
	has Int  $!open = 0;
	has Int  $!accepted = 0;
	has Lock $!lock = Lock.new;

	method start(--> RawServer) {
		$!listener = IO::Socket::Async.listen('127.0.0.1', 0).tap(
			-> $conn { self!serve($conn) },
			quit => -> $ { },
		);
		$!port = await $!listener.socket-port;
		self;
	}

	#| C<http://127.0.0.1:PORT>, for building a backend's api_url.
	method url(--> Str:D) {
		"http://127.0.0.1:$!port";
	}

	#| Every request received so far, in arrival order.
	method requests(--> List) {
		$!lock.protect: { @!requests.List }
	}

	#| What went wrong with the responder or its answers, if anything.
	#| Each entry is a line of text; the client was answered with a 500.
	method errors(--> List) {
		$!lock.protect: { @!errors.List }
	}

	#| Connections accepted and not yet closed by either side.
	method open-connections(--> Int:D) {
		$!lock.protect: { $!open }
	}

	#| Connections accepted since the server started.
	method accepted(--> Int:D) {
		$!lock.protect: { $!accepted }
	}

	#| Stop listening and close every connection still open.
	method stop(--> Nil) {
		try $!listener.close with $!listener;
		my @open = $!lock.protect: { @!connections.List };
		for @open -> $conn { try $conn.close }
		Nil;
	}

	method !note-error(Str:D $what --> Nil) {
		$!lock.protect: { @!errors.push($what) };
		Nil;
	}

	method !serve($conn --> Nil) {
		$!lock.protect: {
			@!connections.push($conn);
			$!open++;
			$!accepted++;
		};

		# The connection's own state, touched from the socket's thread
		# and from write completions.
		my Lock $guard = Lock.new;
		my Buf  $pending = Buf.new;
		my Bool $busy = False;
		my Bool $ended = False;
		my      $body-tap;

		# End the connection, whichever side ended it: a streaming body
		# is closed (so its CLOSE phasers run, which is how a test sees
		# a hang-up) and the socket with it. Runs once.
		my sub end-connection(--> Nil) {
			my $tap;
			my Bool $first = False;
			$guard.protect: {
				unless $ended {
					$ended = True;
					$first = True;
					$tap = $body-tap;
					$body-tap = Nil;
				}
			};
			if $first {
				$tap.close with $tap;
				try $conn.close;
				$!lock.protect: { $!open-- };
			}
			Nil;
		}

		# Write $data unless the connection has ended. A write that fails
		# means the client has gone, and ends the connection.
		my sub put(Blob:D $data --> Promise:D) {
			return Promise.kept(False) if $guard.protect({ $ended });
			my $written = $conn.write($data);
			$written.then(-> $w { end-connection() if $w.status ~~ Broken });
			$written;
		}

		# After the response's last write: close if asked to, otherwise
		# take the next request this connection has sent.
		my sub finish(Promise:D $last, Bool:D $close --> Nil) {
			$last.then({
				if $close {
					end-connection();
				}
				else {
					$guard.protect: { $busy = False };
					next-request();
				}
			});
			Nil;
		}

		my sub respond(RawRequest:D $request --> Nil) {
			my %answer = self!answer-for($request);
			my Bool $close = $request.wants-close;
			my $chunks = %answer<chunks>;
			my Bool $chunked = $chunks.defined;
			my Blob $body = $chunked ?? Blob !! as-blob(%answer<body> // Blob.new);

			my @head = "HTTP/1.1 %answer<status> {REASONS{%answer<status>} // 'Status'}";
			@head.push: "Content-Type: %answer<type>" with %answer<type>;
			@head.push: $chunked ?? 'Transfer-Encoding: chunked' !! "Content-Length: {$body.bytes}";
			@head.push: "{.key}: {.value}" for %answer<headers>.list;
			@head.push: 'Connection: close' if $close;
			my Blob $head = (@head.join("\r\n") ~ "\r\n\r\n").encode('latin-1');

			my &send = {
				my $last = put($head);
				if !$chunked {
					$last = put($body) if $body.bytes;
					finish($last, $close);
				}
				elsif $chunks ~~ Supply {
					my $tap = $chunks.tap(
						-> $piece {
							my Blob $data = as-blob($piece);
							$last = put(chunk-of($data)) if $data.bytes;
						},
						done => {
							$last = put(LAST-CHUNK);
							finish($last, $close);
						},
						quit => -> $error {
							self!note-error("chunks for {$request.method} {$request.path} quit: "
								~ exception-text($error));
							end-connection();
						},
					);
					my Bool $keep = $guard.protect: {
						$body-tap = $tap unless $ended;
						!$ended;
					};
					$tap.close unless $keep;
				}
				else {
					for $chunks.list -> $piece {
						my Blob $data = as-blob($piece);
						$last = put(chunk-of($data)) if $data.bytes;
					}
					$last = put(LAST-CHUNK);
					finish($last, $close);
				}
			};

			given %answer<delay> // 0 {
				when Promise { .then(&send) }
				when * > 0   { Promise.in($_).then(&send) }
				default      { send() }
			}
			Nil;
		}

		# Answer the next complete request, unless one is being answered
		# or the connection has ended.
		my sub next-request(--> Nil) {
			my $request = $guard.protect: {
				if $busy || $ended {
					RawRequest;
				}
				else {
					my $next = take-request($pending);
					$busy = True if $next.defined;
					$next;
				}
			};
			with $request {
				$!lock.protect: { @!requests.push($_) };
				respond($_);
			}
			Nil;
		}

		$conn.Supply(:bin).tap(
			-> $bytes {
				$guard.protect: { $pending.append($bytes) };
				next-request();
			},
			done => { end-connection() },
			quit => -> $ { end-connection() },
		);
		Nil;
	}

	# The responder's answer to $request as a checked Hash, or a 500 that
	# says what was wrong with it (recorded in .errors as well).
	method !answer-for(RawRequest:D $request --> Hash:D) {
		my $what = "{$request.method} {$request.path}";
		my $answer;
		{
			CATCH {
				default {
					self!note-error("responder died for $what: {exception-text($_)}");
					$answer = Nil;
				}
			}
			$answer = &!responder($request);
		}
		return self!refused($what, 'responder died') without $answer;
		$answer = %( body => $answer ) if $answer ~~ Str | Blob;
		return self!refused($what, "responder returned {$answer.^name}, not a Hash")
			unless $answer ~~ Associative;
		my %answer = $answer.Hash;
		my @unknown = %answer.keys.grep({ $_ !(elem) ANSWER-KEYS }).sort;
		return self!refused($what, "unknown answer keys: @unknown[]") if @unknown;
		return self!refused($what, 'an answer has a body or chunks, not both')
			if (%answer<body>:exists) && (%answer<chunks>:exists);
		%answer<status> //= 200;
		return self!refused($what, "status {%answer<status>.raku} is not an HTTP status")
			unless %answer<status> ~~ Int && 100 <= %answer<status> <= 599;
		%answer<type> = 'application/json' unless %answer<type>:exists;
		%answer<headers> //= ();
		return self!refused($what, 'headers must be a list of Pairs')
			unless %answer<headers>.list.all ~~ Pair;
		with %answer<chunks> {
			return self!refused($what, 'chunks must be a Supply or a list')
				unless $_ ~~ Supply || $_ ~~ Positional;
		}
		with %answer<delay> {
			return self!refused($what, 'delay must be a Promise or a non-negative number of seconds')
				unless $_ ~~ Promise || ($_ ~~ Real && $_ >= 0);
		}
		%answer;
	}

	method !refused(Str:D $what, Str:D $why --> Hash:D) {
		self!note-error("bad answer for $what: $why") unless $why eq 'responder died';
		%( status => 500, type => 'text/plain', body => "fixture error: $why", headers => () );
	}
}

#| Start a raw HTTP/1.1 server on a port the OS picks, answering each
#| request with &responder. See "Requests and answers" above. The caller stops
#| it.
sub raw-server(&responder --> RawServer:D) is export {
	RawServer.new(:&responder).start;
}
