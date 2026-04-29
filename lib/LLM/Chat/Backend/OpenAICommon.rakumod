=begin pod

=head1 NAME

LLM::Chat::Backend::OpenAICommon - Generic OpenAI-compatible chat backend

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Chat::Backend::OpenAICommon;
use LLM::Chat::Backend::Settings;

# Any OpenAI-compatible endpoint (Together, Groq, Fireworks, vLLM,
# llama.cpp's OAI server, ...). For OpenRouter specifically, prefer
# the L<LLM::Chat::Backend::OpenRouter> subclass — it adds the
# attribution headers, body extras, and cost/generation-id lifts.
my $backend = LLM::Chat::Backend::OpenAICommon.new(
    api_url  => 'https://api.together.xyz/v1',
    api_key  => %*ENV<TOGETHER_API_KEY>,
    model    => 'meta-llama/Llama-3.3-70B-Instruct-Turbo',
    settings => LLM::Chat::Backend::Settings.new(:max_tokens(4096)),
);

my $resp = $backend.chat-completion(@messages);
react {
    whenever $resp.supply -> $tok { print $tok }
    whenever $resp.supply.done    { say "done — {$resp.prompt-tokens} in / {$resp.completion-tokens} out" }
}

=end code

=head1 DESCRIPTION

OpenAI-compatible HTTP client. Uses C<Cro::HTTP::Client> against
C</chat/completions> and C</completions> endpoints, lifts the OAI-spec
C<usage> block onto the returned C<Response>, and classifies failures
into the categorical C<error-class> shape the L<LLM::Data::Inference>
fallback policy expects.

=head1 EXTENSION

Provider-specific subclasses extend this class to add wire fields,
headers, or Response shapes that aren't part of the OAI spec. To
keep that path clean, the following internal methods are
underscore-prefixed (rather than C<!>-private) so subclasses can
override them:

=item C<_get-api-settings>       — body params for every request.
=item C<_get-api-headers>        — HTTP headers for every request.
=item C<_lift-usage>             — extract usage / model from a response body or stream chunk into the Response.
=item C<make-response>           — factory for non-streaming Response objects (used by C<chat-completion> / C<text-completion>).
=item C<make-stream-response>    — factory for streaming Response objects.
=item C<_on-blocking-complete>   — fires after a non-streaming completion's body has been parsed and lifted, before C<$response.done>. Subclasses use it to attach post-call metadata (e.g. OpenRouter's C</generation> cost lookup).
=item C<_on-stream-complete>     — same hook for the streaming path; fires after C<[DONE]>, before C<$response.done>.

L<LLM::Chat::Backend::OpenRouter> overrides all of these.

C<!classify-exception> stays private — it's pure Raku/Cro mapping
with no provider-specific behaviour.

=end pod

use LLM::Chat::Backend;
use LLM::Chat::Conversation::Message;
use LLM::Chat::Backend::Response;
use LLM::Chat::Backend::Response::Stream;
use LLM::Chat::Debug;

use Cro::HTTP::Client;
use JSON::Fast;
use UUID::V4;

unit class LLM::Chat::Backend::OpenAICommon is LLM::Chat::Backend;

has Str $.api_url is required;
has Str $.api_key is rw;
has Str $.model   is rw;

# Per-phase HTTP timeouts passed to Cro::HTTP::Client. The headers
# phase is when the upstream gateway (OpenRouter, Together, Groq,
# etc.) acknowledges the request with a 200 OK — it happens BEFORE
# any reasoning / content tokens stream over the body, so a long
# headers wait is almost always a queueing or routing stall rather
# than a slow model. 60s is enough grace for any healthy upstream;
# anything longer and the user is waiting for a request that's not
# coming. The body phase stays unbounded so reasoning models that
# take minutes to think still complete cleanly once headers land.
# Callers can override per-backend via C<request-timeout => %( ... )>.
has %.request-timeout = %(
    connection =>  30,
    headers    =>  60,
    body       => Inf,
    total      => 1800,
);

#|( Best-effort: when a 4xx response triggers an
    X::Cro::HTTP::Error::Client, fetch the response body and write it
    to LLM::Chat::Debug. OpenAI-compatible APIs (OpenRouter included)
    return JSON like C<{"error": {"message": "...", "code": "..."}}>
    on rejection — surfacing that text is the difference between
    "401 Unauthorized" and "your key is rate-limited on this model".
    The body is awaited synchronously inside the caller's start { }
    block; if it's already been drained, malformed, or the await
    itself fails, we silently move on rather than masking the
    original error. Gated on LLM_CHAT_DEBUG like the rest of the
    debug log. )
method !log-error-body($exception) {
	return unless $exception ~~ X::Cro::HTTP::Error::Client;
	my $status = try { $exception.response.status.Int } // 0;
	my $body   = try { await $exception.response.body-text };
	if $body.defined && $body.chars {
		LLM::Chat::Debug.log("HTTP $status BODY", $body);
	}
}

#|( Classify an exception caught during a completion call and record
    the structured error shape on the Response before C<.quit> is
    called. Distinguishes four buckets:
      * C<'http'>       — Cro raised X::Cro::HTTP::Error (4xx/5xx);
                          C<error-status> is populated with the code.
      * C<'timeout'>    — Cro raised X::Cro::HTTP::Client::Timeout.
                          The exception class is the only signal —
                          we deliberately do I<not> string-match for
                          "timeout" in arbitrary messages, because
                          unrelated errors (JSON parse failures,
                          stream cancellation messages, etc.) often
                          mention the word and were being misclassified
                          as header timeouts, hiding the real bug.
      * C<'connection'> — socket / DNS failure (connection refused /
                          reset / host unreachable / resolve failure).
                          Detected heuristically from the message
                          since Cro surfaces these as plain exceptions
                          from the underlying transport.
      * C<'unknown'>    — catch-all for exceptions that don't match
                          the above patterns.
    The Task fallback policy reads these off the Response and decides
    between abort / retry-same / advance without parsing raw messages. )
method !classify-exception($exception, LLM::Chat::Backend::Response $response) {
	given $exception {
		when X::Cro::HTTP::Error {
			my $status = try { .response.status.Int };
			$response._set-error-info(
				class  => 'http',
				status => $status,
			);
		}
		when X::Cro::HTTP::Client::Timeout {
			$response._set-error-info(class => 'timeout');
		}
		default {
			my $msg = (.message // '').lc;
			if $msg ~~ / :i [ 'connection' | 'refused' | 'reset'
			                | 'unreachable' | 'could not' \s+ 'resolve'
			                | 'dns' | 'network is' | 'no route' ] / {
				$response._set-error-info(class => 'connection');
			}
			else {
				$response._set-error-info(class => 'unknown');
			}
		}
	}
}

#|( Build the request body shared across all completion calls.
    Subclasses override to add provider-specific extras (e.g.
    OpenRouter's C<include_reasoning>) — call C<callsame> first,
    then mutate the returned hash.

    C<repetition_penalty> is gated on the caller having set a
    non-default value: the OAI spec doesn't define this field, so
    sending it always made some upstreams (notably OpenRouter routes)
    behave unexpectedly. C<top_k> is sent unconditionally because every
    OAI-compatible endpoint we target either honours it or quietly
    ignores it. )
method _get-api-settings(--> Hash) {
	my $s = self.settings;
	my %r;

	%r<model>              = $!model if $!model.defined;
	%r<max_tokens>         = $s.max_tokens;
	%r<temperature>        = $s.temperature;
	%r<top_p>              = $s.top_p;
	%r<top_k>              = $s.top_k;
	%r<presence_penalty>   = $s.presence_pen;
	%r<frequency_penalty>  = $s.frequency_pen;
	%r<stop>               = $s.stop.Array;

	%r<repetition_penalty> = $s.repetition_pen
		if $s.repetition_pen.defined && $s.repetition_pen != 1.0;

	return %r;
}

#|( Build the request headers shared across all completion calls.
    Subclasses override to add provider-specific headers (e.g.
    OpenRouter's C<HTTP-Referer> / C<X-Title> attribution) — call
    C<callsame> first, then add to the returned hash. )
method _get-api-headers(--> Hash) {
	my %h;
	%h<Authorization> = "Bearer {$!api_key}" if $!api_key.defined;
	return %h;
}

#|( Factory for the non-streaming Response object returned by
    C<chat-completion> / C<text-completion>. Subclasses override
    to return a provider-specific Response subclass (e.g.
    C<LLM::Chat::Backend::Response::OpenRouter>). )
method make-response(--> LLM::Chat::Backend::Response) {
	LLM::Chat::Backend::Response.new(id => uuid-v4());
}

#|( Factory for the streaming Response object returned by
    C<chat-completion-stream> / C<text-completion-stream>.
    Subclasses override to return a provider-specific streaming
    Response subclass. )
method make-stream-response(--> LLM::Chat::Backend::Response::Stream) {
	LLM::Chat::Backend::Response::Stream.new(id => uuid-v4());
}

#|( Lift the OAI-spec C<usage> block + top-level C<model> off a
    parsed response body (or a single stream chunk) into the
    Response object. Every extraction is presence-guarded so missing
    keys leave Response attrs undefined — callers read
    C<.prompt-tokens.defined> to distinguish "unknown" from "zero".
    Idempotent on repeated calls with the same chunk, so streaming
    can invoke this per-chunk without worrying about stomping
    already-set values.

    Subclasses override to lift provider-specific extras: call
    C<callsame> first to handle the OAI-spec fields, then pull any
    extras off C<$payload> into the provider's Response subclass. )
method _lift-usage($response, $payload) {
	return unless $payload ~~ Associative;
	my %args;
	if $payload<usage>:exists && $payload<usage> ~~ Associative {
		my %u = $payload<usage>;
		%args<prompt>     = %u<prompt_tokens>     if %u<prompt_tokens>:exists;
		%args<completion> = %u<completion_tokens> if %u<completion_tokens>:exists;
		%args<total>      = %u<total_tokens>      if %u<total_tokens>:exists;
	}
	%args<model> = $payload<model> if $payload<model>:exists
	                               && $payload<model>.defined
	                               && $payload<model>.Str.chars;
	$response._set-usage(|%args) if %args.elems;
}

method chat-completion(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	:@tools,
	--> LLM::Chat::Backend::Response
) {
	my $response = self.make-response;

	start {
		my %settings = self._get-api-settings;
		%settings<messages> = @messages.map(*.to-hash).Array;
		%settings<tools> = @tools if @tools.elems > 0;

		# Pin HTTP/1.1. Cro defaults to ALPN-negotiated HTTP version
		# for HTTPS, which means it can pick HTTP/2 against gateways
		# that advertise it (OpenRouter does). node-fetch — and
		# therefore SillyTavern, which doesn't see this bug — is
		# HTTP/1.1 only. Cro's HTTP/2 client appears to silently hang
		# waiting for headers against some upstream-routed providers,
		# producing the 60s X::Cro::HTTP::Client::Timeout we've been
		# chasing. Forcing 1.1 brings us into parity with fetch.
		my $client = Cro::HTTP::Client.new:
			:http<1.1>,
			content-type => 'application/json',
			timeout      => %!request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/chat/completions";

		LLM::Chat::Debug.log('REQUEST URL (chat-completion)', $url);
		LLM::Chat::Debug.log-headers('REQUEST HEADERS', self._get-api-headers);
		LLM::Chat::Debug.log-json('REQUEST BODY', %settings);

		my $res = await $client.post:
			$url,
			body    => %settings,
			headers => self._get-api-headers;

		my $data = await $res.body;
		LLM::Chat::Debug.log-json('RESPONSE BODY (chat-completion)', $data);

		# Usage + routed-model metadata lifted before touching
		# choices, so a malformed choices[] doesn't shadow otherwise-
		# good telemetry. Presence-gated: absent keys stay Nil on
		# Response and propagate as "unknown" to the sink. Dispatches
		# through subclass overrides so provider-specific extras
		# (e.g. OpenRouter's cost / generation-id) get lifted too.
		self._lift-usage($response, $data);

		my $choice = $data<choices>[0];
		my $finish = $choice<finish_reason> // '';
		$response._set-finish-reason($finish);

		if $finish eq 'tool_calls' && $choice<message><tool_calls>.defined {
			$response._set-tool-calls($choice<message><tool_calls>.list);
			# Also capture any content the model produced alongside tool calls
			my $msg = $choice<message><content> // '';
			$response.emit($msg);
		} else {
			my $msg = $choice<message><content> // '';
			$response.emit($msg);
		}

		# Non-streaming reasoning lands on the final message rather
		# than on per-chunk deltas. Capture it here for parity with
		# the stream path so callers can read .reasoning-text either
		# way.
		my $reasoning = $choice<message><reasoning> // '';
		$response._append-reasoning($reasoning) if $reasoning.chars;

		# Hook fires before $response.done so any subclass-supplied
		# post-call metadata (e.g. OpenRouter's /generation cost
		# lookup, which is the only place blocking-path callers can
		# pick up usage.cost since we no longer ask for it inline)
		# is populated by the time consumers see the final body.
		# See _on-blocking-complete docs.
		self._on-blocking-complete($response);
		$response.done;

		CATCH {
			default {
				LLM::Chat::Debug.log('EXCEPTION', "{.^name}: {.message}");
				self!log-error-body($_);
				self!classify-exception($_, $response);
				$response.quit($_.message);
			}
		};
	}

	return $response;
}

method chat-completion-stream(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	:@tools,
	--> LLM::Chat::Backend::Response::Stream
) {
	my $response = self.make-stream-response;

	start {
		my $start-time = now;
		my %settings = self._get-api-settings;
		%settings<messages> = @messages.map(*.to-hash).Array;
		%settings<stream> = True;
		%settings<tools> = @tools if @tools.elems > 0;

		# Pin HTTP/1.1. Cro defaults to ALPN-negotiated HTTP version
		# for HTTPS, which means it can pick HTTP/2 against gateways
		# that advertise it (OpenRouter does). node-fetch — and
		# therefore SillyTavern, which doesn't see this bug — is
		# HTTP/1.1 only. Cro's HTTP/2 client appears to silently hang
		# waiting for headers against some upstream-routed providers,
		# producing the 60s X::Cro::HTTP::Client::Timeout we've been
		# chasing. Forcing 1.1 brings us into parity with fetch.
		my $client = Cro::HTTP::Client.new:
			:http<1.1>,
			content-type => 'application/json',
			timeout      => %!request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/chat/completions";

		LLM::Chat::Debug.log('REQUEST URL (chat-completion-stream)', $url);
		LLM::Chat::Debug.log-headers('REQUEST HEADERS', self._get-api-headers);
		LLM::Chat::Debug.log-json('REQUEST BODY', %settings);

		my $res = await $client.post:
			$url,
			body             => %settings,
			headers          => self._get-api-headers;

		LLM::Chat::Debug.log('HEADERS RECEIVED',
			"+{((now - $start-time) * 1000).Int}ms status={$res.status}");

		react {
			# Buffer SSE bytes across TCP chunk boundaries. SSE events
			# end with a blank line ("\n\n" / "\r\n\r\n"); a single
			# `data: {...}` JSON object can be split across multiple
			# body-byte-stream emissions. Decoding+parsing each chunk
			# independently (the previous behaviour) caused from-json
			# to throw on the truncated half whenever a JSON object
			# straddled a TCP packet, terminating the entire stream.
			my Bool $first-byte-seen = False;
			my Str  $buffer = '';
			whenever $res.body-byte-stream -> $data {
				unless $first-byte-seen {
					$first-byte-seen = True;
					LLM::Chat::Debug.log('FIRST BODY BYTE',
						"+{((now - $start-time) * 1000).Int}ms bytes={$data.elems}");
				}
				$buffer ~= $data.decode('utf-8');
				my @events = $buffer.split(/\n\n | \r\n\r\n/);
				$buffer = @events.pop;   # incomplete tail held back

				for @events -> $event {
					for $event.lines -> $raw-line {
						my $clean = $raw-line.trim;
						# SSE comment lines start with ":" — heartbeats
						# like `: OPENROUTER PROCESSING` keep the
						# connection alive and carry no data. Skip them
						# silently per spec.
						next if $clean.starts-with(':');
						next unless $clean.starts-with('data:');

						my $line = $clean.substr(5).trim;
						LLM::Chat::Debug.log('SSE LINE', $line);
						if $line eq '[DONE]' {
							# Hook fires before $response.done so any
							# subclass-supplied post-stream metadata
							# (e.g. OpenRouter's /generation cost
							# lookup) is populated by the time
							# consumers see .is-done = True. Hooks
							# are responsible for being prompt — see
							# _on-stream-complete docs.
							self._on-stream-complete($response);
							$response.done;
							done;
						}

						my $chunk;
						{
							CATCH {
								default {
									LLM::Chat::Debug.log('SSE PARSE ERROR',
										"line={$line} error={.message}");
									# Skip malformed chunks; OR
									# occasionally interleaves error
									# fragments mid-stream that aren't
									# our problem to surface as fatals.
								}
							}
							$chunk = from-json($line);
						}
						next without $chunk;

						# Usage chunks arrive as the terminal
						# frame (choices=[] + usage populated);
						# also snag model / id off the first
						# chunk that carries them. Subclass
						# override (e.g. OpenRouter) lifts any
						# provider-specific extras alongside.
						self._lift-usage($response, $chunk);
						my $delta = $chunk<choices>[0]<delta><content>:exists
							?? $chunk<choices>[0]<delta><content>
							!! "";
						$response.emit($delta);

						# Reasoning trace, when the model emits
						# one. Accumulated separately from the
						# content supply so consumers that just
						# want the visible reply still get a
						# clean stream.
						my $reasoning = $chunk<choices>[0]<delta><reasoning>:exists
							?? ($chunk<choices>[0]<delta><reasoning> // '')
							!! '';
						$response._append-reasoning($reasoning) if $reasoning.chars;

						my $reason = $chunk<choices>[0]<finish_reason> // Nil;
						if $reason.defined {
							given $reason {
								when 'stop' {
									# Don't close yet — `[DONE]` or a
									# naturally-closed body terminates
									# us, and OpenRouter occasionally
									# emits a final id/provider chunk
									# after finish_reason but before
									# the SSE close.
								}
								when 'length' {
									$response._set-error-info(class => 'response');
									$response.quit("Hit max tokens");
									done;
								}
								when 'content_filter' {
									$response._set-error-info(class => 'response');
									$response.quit("Blocked by content filter");
									done;
								}
								default {
									$response._set-error-info(class => 'response');
									$response.quit("Unknown finish reason: $reason");
									done;
								}
							}
						}
					}
				}
			}
		}

		CATCH {
			default {
				LLM::Chat::Debug.log('EXCEPTION',
					"+{((now - $start-time) * 1000).Int}ms {.^name}: {.message}");
				self!log-error-body($_);
				self!classify-exception($_, $response);
				$response.quit($_.message);
			}
		};
	}

	return $response;
}

#|( Hook called when a streaming response naturally completes
    (`[DONE]` received, or `finish_reason: stop` for text completions).
    Fires I<before> C<$response.done>, so any subclass-supplied
    metadata (e.g. OpenRouter's /generation cost lookup) is readable
    by the time consumers observe C<.is-done = True>.

    Hooks run synchronously inside the streaming worker's C<start { }>
    block — blocking the main reactor isn't a concern, but anything
    that takes much over ~200 ms here will visibly delay
    C<.is-done> for the consumer. Hooks should swallow their own
    exceptions; an unhandled throw will land in the caller's CATCH
    and be classified as a generic stream failure.

    Default is a no-op for vanilla OAI-compatible endpoints. )
method _on-stream-complete(LLM::Chat::Backend::Response::Stream $response) {
	# No-op — subclasses (e.g. OpenRouter) override.
}

#|( Hook called when a non-streaming chat-completion successfully
    completes — body parsed, usage / generation-id lifted onto the
    Response by C<_lift-usage>. Fires I<before> C<$response.done>,
    so any subclass-supplied post-call metadata (e.g. OpenRouter's
    C</generation> cost lookup, which is the only place a blocking
    caller can pick up C<usage.cost> since we no longer ask for it
    inline) is readable by the time consumers observe the final
    body.

    Symmetric counterpart to C<_on-stream-complete>: same contract,
    same timing, same exception handling — runs synchronously inside
    the request worker's C<start { }> block, hooks swallow their own
    exceptions, an unhandled throw lands in the caller's CATCH and
    is classified as a generic failure.

    Default is a no-op for vanilla OAI-compatible endpoints. )
method _on-blocking-complete(LLM::Chat::Backend::Response $response) {
	# No-op — subclasses (e.g. OpenRouter) override.
}

method text-completion(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	Bool $continuation = False,
	--> LLM::Chat::Backend::Response
) {
	my $response = self.make-response;

	unless (self.template.defined) {
		$response._set-error-info(class => 'unknown');
		$response.quit("Must define template in backend to use text completion");

		return $response;
	}

	start {
		my %settings = self._get-api-settings;
		my $template = self.template;
		%settings<prompt> = $template.render(
			@messages,
			$continuation,
		);

		# Pin HTTP/1.1. Cro defaults to ALPN-negotiated HTTP version
		# for HTTPS, which means it can pick HTTP/2 against gateways
		# that advertise it (OpenRouter does). node-fetch — and
		# therefore SillyTavern, which doesn't see this bug — is
		# HTTP/1.1 only. Cro's HTTP/2 client appears to silently hang
		# waiting for headers against some upstream-routed providers,
		# producing the 60s X::Cro::HTTP::Client::Timeout we've been
		# chasing. Forcing 1.1 brings us into parity with fetch.
		my $client = Cro::HTTP::Client.new:
			:http<1.1>,
			content-type => 'application/json',
			timeout      => %!request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/completions";

		my $res = await $client.post:
			$url,
			body    => %settings,
			headers => self._get-api-headers;

		my $data = await $res.body;

		my $msg  = $data<choices>[0]<text>;

		$response.emit($msg);
		$response.done;

		CATCH {
			default {
				LLM::Chat::Debug.log('EXCEPTION', "{.^name}: {.message}");
				self!log-error-body($_);
				self!classify-exception($_, $response);
				$response.quit($_.message);
			}
		};
	}

	return $response;
}

method text-completion-stream(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	Bool $continuation = False,
	--> LLM::Chat::Backend::Response::Stream
) {
	my $response = self.make-stream-response;

	unless self.template.defined {
		$response._set-error-info(class => 'unknown');
		$response.quit("Must define template in backend to use text completion stream");
		return $response;
	}

	start {
		my %settings = self._get-api-settings;
		my $template = self.template;
		%settings<prompt> = $template.render(
			@messages,
			$continuation,
		);
		%settings<stream> = True;

		# Pin HTTP/1.1. Cro defaults to ALPN-negotiated HTTP version
		# for HTTPS, which means it can pick HTTP/2 against gateways
		# that advertise it (OpenRouter does). node-fetch — and
		# therefore SillyTavern, which doesn't see this bug — is
		# HTTP/1.1 only. Cro's HTTP/2 client appears to silently hang
		# waiting for headers against some upstream-routed providers,
		# producing the 60s X::Cro::HTTP::Client::Timeout we've been
		# chasing. Forcing 1.1 brings us into parity with fetch.
		my $client = Cro::HTTP::Client.new:
			:http<1.1>,
			content-type => 'application/json',
			timeout      => %!request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/completions";

		my $res = await $client.post:
			$url,
			body    => %settings,
			headers => self._get-api-headers;

		react {
			my Str $buffer = '';
			whenever $res.body-byte-stream -> $data {
				$buffer ~= $data.decode('utf-8');
				my @events = $buffer.split(/\n\n | \r\n\r\n/);
				$buffer = @events.pop;

				for @events -> $event {
					for $event.lines -> $raw-line {
						my $clean = $raw-line.trim;
						next if $clean.starts-with(':');
						next unless $clean.starts-with('data:');

						my $payload = $clean.substr(5).trim;
						if $payload eq '[DONE]' {
							$response.done;
							self._on-stream-complete($response);
							done;
						}

						my $chunk;
						{
							CATCH {
								default {
									LLM::Chat::Debug.log('SSE PARSE ERROR',
										"line={$payload} error={.message}");
								}
							}
							$chunk = from-json($payload);
						}
						next without $chunk;

						my $text = $chunk<choices>[0]<text> // "";
						$response.emit($text);

						my $reason = $chunk<choices>[0]<finish_reason> // Nil;
						if $reason.defined {
							given $reason {
								when 'stop' {
									self._on-stream-complete($response);
									$response.done;
									done;
								}
								when 'length' {
									$response._set-error-info(class => 'response');
									$response.quit("Hit max tokens");
									done;
								}
								when 'content_filter' {
									$response._set-error-info(class => 'response');
									$response.quit("Blocked by content filter");
									done;
								}
								default {
									$response._set-error-info(class => 'response');
									$response.quit("Unknown finish reason: $reason");
									done;
								}
							}
						}
					}
				}
			}
		}

		CATCH {
			default {
				LLM::Chat::Debug.log('EXCEPTION', "{.^name}: {.message}");
				self!log-error-body($_);
				self!classify-exception($_, $response);
				$response.quit($_.message);
			}
		}
	}

	return $response;
}

method cancel(LLM::Chat::Backend::Response $resp) {
	$resp.cancel;
}
