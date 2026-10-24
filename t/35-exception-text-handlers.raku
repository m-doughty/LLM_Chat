use Test;

use LLM::Chat::Backend;
use LLM::Chat::Backend::KoboldCpp;
use LLM::Chat::Backend::OpenAICommon;
use LLM::Chat::Backend::OpenRouter;
use LLM::Chat::Backend::Response;
use LLM::Chat::Backend::Response::Stream;
use LLM::Chat::Backend::Settings;
use LLM::Chat::Conversation::Message;
use LLM::Chat::Template::ChatML;
use LLM::Chat::ToolLoop;
use LLM::Chat::ExceptionText;

use Cro::HTTP::Client;
use JSON::Fast;

# The handler half of t/35-exception-text.rakutest, run by that file in a
# child process of its own. Not a test file itself (the extension keeps
# prove6 and zef from running it directly), but TAP all the same: the
# parent reads this process's TAP from stdout and repeats each result.
#
# Every handler that used to call `.message` on the exception it caught
# is driven here with an exception that has no message: the four
# OpenAICommon completion paths against a real server that drops the
# connection, the server probes, the finish-reason hook, OpenRouter's
# generation lookup, the transport teardowns, and ToolLoop. Before the
# fix the completion and ToolLoop cases took the process down with them.
#
# Why a child process: this process prints "WARNING: unhandled Failure
# detected in DESTROY ... Stub code executed" on stderr, at whatever
# moment the garbage collector runs. Rakudo's Exception.rethrow, given an
# exception that was never thrown, reads its .message to label the VM
# exception and drops the stub's Failure unhandled. Cro rethrows
# PipelineClosedBeforeHeaders exactly that way, and so does `await` with
# a Promise broken by such an exception; the Failure is created and
# discarded inside Rakudo, out of reach of this library or this file.
# The parent keeps that stderr off the test run, and fails if it holds
# anything else.
#
# Run it by hand from the distribution root with `raku -I. t/<this file>`.

plan 14;

# No message of its own: .message is the base stub.
class X::ExceptionTextTest::Quiet is Exception { }

my constant QUIET = 'X::ExceptionTextTest::Quiet';
my constant DROPPED = 'Cro::HTTP::Client::PipelineClosedBeforeHeaders';

# What a handler's log line says about X::ExceptionTextTest::Quiet.
my Str $quiet-logged = QUIET ~ ': (no message)';

# --- Fixtures: the transport ------------------------------------------

# A loopback HTTP server that reads each request to the end and then,
# by path, sends a canned JSON reply or closes the connection without a
# word. The second is the real trigger: Cro reports a connection closed
# before any response header as PipelineClosedBeforeHeaders. Reading
# the whole request first matters — a socket closed with input still
# unread is reset rather than closed on some platforms, and Cro reports
# a reset as a different error, one that has a message.
class DroppingServer {
	has %.replies;
	has $.port;
	has @!paths;
	has @!conns;
	has $!tap;
	has Lock $!lock = Lock.new;

	method start() {
		$!tap = IO::Socket::Async.listen('127.0.0.1', 0).tap(
			-> $conn { self!serve($conn) },
			quit => -> $ { },
		);
		$!port = await $!tap.socket-port;
		self;
	}

	method paths(--> List) {
		$!lock.protect: { @!paths.List }
	}

	method stop() {
		my @conns = $!lock.protect: { @!conns.List };
		for @conns -> $conn { try $conn.close }
		$!tap.close;
	}

	method !serve($conn) {
		$!lock.protect: { @!conns.push($conn) };
		my Buf $seen = Buf.new;
		my Bool $answered = False;
		$conn.Supply(:bin).tap(
			-> $bytes {
				$seen.append($bytes);
				if !$answered {
					with request-path($seen) -> $path {
						$answered = True;
						$!lock.protect: { @!paths.push($path) };
						with %!replies{$path} -> $json {
							my Blob $body = $json.encode('utf-8');
							my Blob $head = (
								"HTTP/1.1 200 OK\r\n"
								~ "Content-Type: application/json\r\n"
								~ "Content-Length: {$body.bytes}\r\n"
								~ "Connection: close\r\n\r\n"
							).encode('latin-1');
							$conn.write($head ~ $body).then({ $conn.close });
						}
						else {
							$conn.close;
						}
					}
				}
			},
			quit => -> $ { },
		);
	}
}

# The path (query string dropped) of the request in $buffer once all of
# it has arrived — headers and the whole body — or Str until then. Byte
# arithmetic on the Buf throughout: decoded, "\r\n" is one grapheme.
sub request-path(Buf:D $buffer --> Str) {
	my $head-end = header-end($buffer);
	return Str without $head-end;
	my Str $head = $buffer.subbuf(0, $head-end).decode('latin-1');
	my Int $body-bytes = $buffer.elems - ($head-end + 4);
	if $head ~~ m:i/ ^^ 'transfer-encoding:' \h* 'chunked' / {
		return Str unless $body-bytes >= 5
			&& $buffer.subbuf($buffer.elems - 5).decode('latin-1') eq "0\r\n\r\n";
	}
	else {
		my Int $length = $head ~~ m:i/ ^^ 'content-length:' \h* (\d+) / ?? +$0 !! 0;
		return Str if $body-bytes < $length;
	}
	$head ~~ / ^ \S+ \s+ (<-[\s?]>+) / ?? ~$0 !! '/';
}

sub header-end(Buf:D $buffer --> Int) {
	for 0 .. $buffer.elems - 4 -> $i {
		return $i if $buffer[$i] == 13 && $buffer[$i + 1] == 10
			&& $buffer[$i + 2] == 13 && $buffer[$i + 3] == 10;
	}
	Int;
}

# Replies by path, e.g. %( '/v1/chat/completions' => $json ); every
# other path is dropped.
sub start-server(%replies = %() --> DroppingServer) {
	DroppingServer.new(:%replies).start;
}

sub settings() {
	LLM::Chat::Backend::Settings.new(max_tokens => 16);
}

sub user-turn() {
	[LLM::Chat::Conversation::Message.new(role => 'user', content => 'hi'),]
}

my constant SETTLE-LIMIT = 30;

# A Response's own tap sets .is-done for success and failure alike,
# however fast either happened, so polling it is race-free for blocking
# and streaming Responses both.
sub settles($response --> Bool) {
	my $deadline = now + SETTLE-LIMIT;
	until $response.is-done {
		return False if now > $deadline;
		sleep 0.005;
	}
	True;
}

# A blocking chat reply, with the id OpenRouter's generation lookup uses.
my Str $chat-reply = to-json(%(
	id      => 'gen-exception-text',
	model   => 'test/model',
	choices => [
		%(
			index         => 0,
			message       => %( role => 'assistant', content => 'hello' ),
			finish_reason => 'stop',
		),
	],
	usage   => %( prompt_tokens => 3, completion_tokens => 1, total_tokens => 4 ),
), :!pretty);

# The handlers' own log lines format the exception they caught, which
# is code under repair too, so the debug log is switched on for the
# whole file and each check reads what its own scenario appended. Set
# once, here, before any worker thread exists to read it.
my IO::Path $log-path = $*TMPDIR.add("llm-chat-exception-text-{$*PID}.log");
%*ENV<LLM_CHAT_DEBUG> = ~$log-path;
END { try $log-path.unlink }

sub log-size(--> Int:D) {
	$log-path.e ?? $log-path.s !! 0;
}

sub log-since(Int:D $offset --> Str:D) {
	return '' unless $log-path.e;
	$log-path.slurp(:bin).subbuf($offset).decode('utf-8');
}

# --- The real trigger -------------------------------------------------

subtest 'premise: Cro raises a messageless exception on a dropped connection' => {
	plan 4;
	my $server = start-server();
	LEAVE { $server.stop }

	my $client = Cro::HTTP::Client.new(:http<1.1>, content-type => 'application/json');
	my $post = $client.post("http://127.0.0.1:{$server.port}/v1/chat/completions",
		body => '{}'.encode('utf-8'));
	await Promise.anyof($post, Promise.in(SETTLE-LIMIT));
	is $post.status, Broken, 'the request fails';
	my $cause = $post.status ~~ Broken ?? $post.cause !! Mu;
	ok $cause.^name.starts-with(DROPPED), "it fails with {DROPPED}";
	throws-like { $cause.message }, X::StubCode,
		'... whose .message is the base stub';
	is exception-text($cause), DROPPED, 'exception-text names it';
};

for <chat-completion chat-completion-stream text-completion text-completion-stream> -> $method {
	subtest "OpenAICommon $method fails the Response when the server drops the connection" => {
		plan 6;
		my $server = start-server();
		LEAVE { $server.stop }
		my $backend = LLM::Chat::Backend::OpenAICommon.new(
			api_url  => "http://127.0.0.1:{$server.port}/v1",
			settings => settings(),
			template => LLM::Chat::Template::ChatML.new,
		);

		my $offset = log-size();
		my $response = $backend."$method"(user-turn());
		ok settles($response), 'the Response settles (and the process is still here)';
		nok $response.is-success, 'it is not a success';
		ok (~$response.err).contains(DROPPED), 'its error text names the exception class';
		is $response.error-class, 'unknown', "error-class 'unknown'";
		ok $server.paths.elems >= 1, 'the request did reach the server';
		my $log = log-since($offset);
		ok $log ~~ / '=== EXCEPTION ===' \n \N* 'PipelineClosedBeforeHeaders' \S* ': (no message)' /,
			'the handler logged the class and "(no message)"';
	};
}

subtest 'probe-server-limits reports a dropped probe in its note' => {
	plan 4;
	my $server = start-server();
	LEAVE { $server.stop }
	my $backend = LLM::Chat::Backend::OpenAICommon.new(
		api_url              => "http://127.0.0.1:{$server.port}/v1",
		settings             => settings(),
		server-probe-timeout => SETTLE-LIMIT,
	);

	my %limits;
	lives-ok { %limits = $backend.probe-server-limits }, 'the probe does not throw';
	ok (%limits<note> // '').contains(DROPPED), 'its note names the exception class';
	ok (%limits<note> // '').contains('(no message)'), '... and says it had no message';
	is-deeply $server.paths.unique.List, ('/props',), 'the probe asked /props';
};

subtest 'KoboldCpp length check reports a dropped perf request in its evidence' => {
	plan 6;
	my $server = start-server();
	LEAVE { $server.stop }
	my $backend = LLM::Chat::Backend::KoboldCpp.new(
		api_url                      => "http://127.0.0.1:{$server.port}/v1",
		settings                     => settings(),
		verify-length-finish-timeout => SETTLE-LIMIT,
	);
	my $response = LLM::Chat::Backend::Response.new(id => 'kcpp-length-check');

	my $verdict;
	lives-ok {
		$verdict = $backend._reconcile-finish-reason($response, 'length', %(max_tokens => 16));
	}, 'the check does not throw';
	is $verdict, 'length', 'a failed check keeps length';
	my %evidence = $response.finish-reason-evidence;
	ok (%evidence<note> // '').contains(DROPPED), 'the evidence note names the exception class';
	ok (%evidence<note> // '').contains('(no message)'), '... and says it had no message';
	is %evidence<verdict>, 'length', 'the evidence records the verdict';
	ok $server.paths.grep('/api/extra/perf').elems, 'the check asked /api/extra/perf';
};

# Overrides with the exact signature the docs require.
class QuietHookBackend is LLM::Chat::Backend::OpenAICommon {
	method _reconcile-finish-reason(
		LLM::Chat::Backend::Response $response,
		Str:D $reason,
		%request,
		--> Str:D
	) {
		die X::ExceptionTextTest::Quiet.new;
	}
}

subtest 'a finish-reason hook dying without a message keeps the provider reason' => {
	plan 5;
	my $server = start-server(%( '/v1/chat/completions' => $chat-reply ));
	LEAVE { $server.stop }
	my $backend = QuietHookBackend.new(
		api_url  => "http://127.0.0.1:{$server.port}/v1",
		settings => settings(),
	);

	my $offset = log-size();
	my $response = $backend.chat-completion(user-turn());
	ok settles($response), 'the Response settles';
	ok $response.is-success, 'it succeeds, as with any failing hook';
	is $response.msg, 'hello', 'the reply is intact';
	is $response.finish-reason, 'stop', "the provider's reason stands";
	ok log-since($offset) ~~ / '=== FINISH REASON HOOK FAILED ===' \n $quiet-logged /,
		'the failure is logged with the class and "(no message)"';
};

subtest 'OpenRouter: a dropped generation lookup leaves the completion a success' => {
	plan 6;
	my $server = start-server(%( '/v1/chat/completions' => $chat-reply ));
	LEAVE { $server.stop }
	my $backend = LLM::Chat::Backend::OpenRouter.new(
		api_url  => "http://127.0.0.1:{$server.port}/v1",
		settings => settings(),
		model    => 'test/model',
		api_key  => 'test-key',
	);

	my $offset = log-size();
	my $response = $backend.chat-completion(user-turn());
	ok settles($response), 'the Response settles';
	ok $response.is-success, 'the completion succeeds';
	is $response.msg, 'hello', 'the reply is intact';
	nok $response.cost.defined, 'cost stays unreported';
	ok $server.paths.grep('/v1/generation').elems, 'the lookup did reach the server';
	my $log = log-since($offset);
	ok $log ~~ / '=== GENERATION LOOKUP FAILED ===' \n \N* 'PipelineClosedBeforeHeaders' \S* ': (no message)' /,
		'the lookup failure is logged with the class and "(no message)"';
};

subtest 'an aborter dying without a message does not escape cancel' => {
	plan 3;
	my $response = LLM::Chat::Backend::Response.new(id => 'quiet-aborter');
	$response._attach-aborter({ die X::ExceptionTextTest::Quiet.new });

	my $offset = log-size();
	lives-ok { $response.cancel }, 'cancel returns normally';
	ok $response.is-cancelled, 'the Response is cancelled';
	ok log-since($offset) ~~ / '=== ABORT FAILED ===' \n $quiet-logged /,
		'the failure is logged with the class and "(no message)"';
};

class QuietCancel {
	method cancel { die X::ExceptionTextTest::Quiet.new }
}

subtest 'abandoning a transport whose cancel dies without a message' => {
	plan 2;
	# The teardown after a stream-finish-grace expiry. Its argument is a
	# Cro response in real use; any object with a cancel that dies this
	# way exercises the same handler.
	my $abandon = LLM::Chat::Backend::OpenAICommon.^find_private_method('abandon-transport');
	my $backend = LLM::Chat::Backend::OpenAICommon.new(
		api_url  => 'http://127.0.0.1:1/v1',
		settings => settings(),
	);

	my $offset = log-size();
	lives-ok { $abandon($backend, QuietCancel.new) }, 'the teardown does not throw';
	ok log-since($offset) ~~ / '=== ABANDON FAILED ===' \n $quiet-logged /,
		'the failure is logged with the class and "(no message)"';
};

# --- ToolLoop ---------------------------------------------------------

# A stream that starts producing only once a consumer has subscribed.
# ToolLoop subscribes to each backend stream after the call returns, and
# a live Supply does not replay what was emitted before that; a fixed
# sleep would race on a loaded machine. The Response's own constructor
# tap runs before &.producer is set, so it gets the plain supply.
class GatedStream is LLM::Chat::Backend::Response::Stream {
	has &.producer is rw;

	method supply {
		my $inner = $.supplier.Supply;
		my &produce = &!producer;
		return $inner without &produce;
		&!producer = Nil;
		supply {
			whenever $inner { emit $_ }
			produce();
		}
	}
}

# Streams scripted one step per call; a step gets the stream once
# ToolLoop is listening to it.
class GatedBackend is LLM::Chat::Backend {
	has @.steps;
	has @.recorded-calls;
	has Int $!next-id = 0;

	method chat-completion(
		@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
		:@tools,
		--> LLM::Chat::Backend::Response
	) {
		die 'GatedBackend only implements streaming';
	}

	method chat-completion-stream(
		@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
		:@tools,
		--> LLM::Chat::Backend::Response::Stream
	) {
		my &step = @!steps.shift;
		@!recorded-calls.push: %( messages => @messages.clone, tools => @tools.clone );
		my $stream = GatedStream.new(id => 'gated-' ~ ++$!next-id);
		$stream.producer = { start { step($stream) } };
		$stream;
	}
}

class QuietBackend is LLM::Chat::Backend {
	method chat-completion(
		@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
		:@tools,
		--> LLM::Chat::Backend::Response
	) {
		die X::ExceptionTextTest::Quiet.new;
	}

	method chat-completion-stream(
		@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
		:@tools,
		--> LLM::Chat::Backend::Response::Stream
	) {
		die X::ExceptionTextTest::Quiet.new;
	}
}

my @tools = [{
	type     => 'function',
	function => {
		name        => 'get_weather',
		description => 'Get weather for a location',
		parameters  => {
			type       => 'object',
			properties => { location => { type => 'string' } },
			required   => ['location'],
		},
	},
},];

my @weather-call = [{
	id       => 'call_weather',
	type     => 'function',
	function => {
		name      => 'get_weather',
		arguments => '{"location":"London"}',
	},
},];

subtest 'ToolLoop: a backend call dying without a message quits the loop' => {
	plan 3;
	my $loop = LLM::Chat::ToolLoop.new(
		backend       => QuietBackend.new(settings => settings()),
		tools         => @tools,
		execute-tools => -> @calls { [] },
	);

	my $response = $loop.chat-completion-stream(user-turn());
	ok settles($response), 'the loop settles (and the process is still here)';
	nok $response.is-success, 'it is not a success';
	is ~$response.err, QUIET, 'its error is the exception class';
};

subtest 'ToolLoop: a backend stream quitting without a message quits the loop' => {
	plan 3;
	my $backend = GatedBackend.new(
		settings => settings(),
		steps    => [-> $stream { $stream.quit(X::ExceptionTextTest::Quiet.new) },],
	);
	my $loop = LLM::Chat::ToolLoop.new(
		:$backend,
		tools         => @tools,
		execute-tools => -> @calls { [] },
	);

	my $response = $loop.chat-completion-stream(user-turn());
	ok settles($response), 'the loop settles';
	nok $response.is-success, 'it is not a success';
	is ~$response.err, QUIET, 'its error is the exception class, without the await mixin';
};

subtest 'ToolLoop: execute-tools dying without a message becomes the tool result' => {
	plan 7;
	my $backend = GatedBackend.new(
		settings => settings(),
		steps    => [
			-> $stream {
				$stream._set-tool-calls(@weather-call);
				$stream._set-finish-reason('tool_calls');
				$stream.done;
			},
			-> $stream {
				$stream.emit('final answer');
				$stream._set-finish-reason('stop');
				$stream.done;
			},
		],
	);
	my @results;
	my $loop = LLM::Chat::ToolLoop.new(
		:$backend,
		tools          => @tools,
		execute-tools  => -> @calls { die X::ExceptionTextTest::Quiet.new },
		on-tool-result => -> %result { @results.push(%result) },
	);

	my $response = $loop.chat-completion-stream(user-turn());
	ok settles($response), 'the loop settles';
	ok $response.is-success, 'the loop carries on to a final answer';
	is $response.msg, 'final answer', 'the final answer is streamed';
	is $backend.recorded-calls.elems, 2, 'the loop called the backend again';
	my $tool-turn = $backend.recorded-calls[*-1]<messages>[*-1];
	is $tool-turn.role, 'tool', '... with a tool turn';
	is $tool-turn.content, QUIET, 'whose content is the exception class';
	ok @results.elems == 1 && @results[0]<is_error>, 'the tool result is flagged as an error';
};

done-testing;
