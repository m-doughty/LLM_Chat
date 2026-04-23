#!/usr/bin/env raku

use LLM::Chat::Backend;
use LLM::Chat::Conversation::Message;
use LLM::Chat::Backend::Response;
use LLM::Chat::Backend::Response::Stream;

use Cro::HTTP::Client;
use JSON::Fast;
use UUID::V4;

unit class LLM::Chat::Backend::OpenAICommon is LLM::Chat::Backend;

has Str $.api_url is required;
has Str $.api_key is rw;
has Str $.model   is rw;

# Per-phase HTTP timeouts passed to Cro::HTTP::Client. The defaults
# target reasoning models (Kimi K2.6, DeepSeek-R1, GLM-4.6 thinking,
# ...) whose time-to-first-byte can comfortably exceed Cro's default
# 60s headers timeout while they emit reasoning tokens server-side.
# Callers can override per-backend via C<request-timeout => %( ... )>.
has %.request-timeout = %(
    connection =>  60,
    headers    => 600,
    body       => Inf,
    total      => 1800,
);

#|( Classify an exception caught during a completion call and record
    the structured error shape on the Response before C<.quit> is
    called. Distinguishes four buckets:
      * C<'http'>       — Cro raised X::Cro::HTTP::Error (4xx/5xx);
                          C<error-status> is populated with the code.
      * C<'timeout'>    — Cro raised X::Cro::HTTP::Client::Timeout,
                          or a caller-level deadline fired.
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
			if $msg ~~ / :i 'timeout' | 'timed out' / {
				$response._set-error-info(class => 'timeout');
			}
			elsif $msg ~~ / :i [ 'connection' | 'refused' | 'reset'
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

method !get-api-settings(--> Hash) {
	my $s = self.settings;
	my %r;

	%r<model>              = $!model if $!model.defined;
	%r<max_tokens>         = $s.max_tokens;
	%r<temperature>        = $s.temperature;
	%r<top_p>              = $s.top_p;
	%r<repetition_penalty> = $s.repetition_pen;
	%r<presence_penalty>   = $s.presence_pen;
	%r<frequency_penalty>  = $s.frequency_pen;
	%r<stop>               = $s.stop.Array;

	return %r;
}

method !get-api-headers(--> Hash) {
    my %h;
    %h<Authorization> = "Bearer {$!api_key}" if $!api_key.defined;
    return %h;
}

method chat-completion(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	:@tools,
	--> LLM::Chat::Backend::Response
) {
	my $response = LLM::Chat::Backend::Response.new(id => uuid-v4());

	start {
		my %settings = self!get-api-settings;
		%settings<messages> = @messages.map(*.to-hash).Array;
		%settings<tools> = @tools if @tools.elems > 0;

		my $client = Cro::HTTP::Client.new:
			content-type => 'application/json',
			timeout      => %!request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/chat/completions";

		my $res = await $client.post:
			$url,
			body    => %settings,
			headers => self!get-api-headers;

		my $data = await $res.body;

		# Usage + routed-model metadata lifted before touching
		# choices, so a malformed choices[] doesn't shadow otherwise-
		# good telemetry. Presence-gated: absent keys stay Nil on
		# Response and propagate as "unknown" to the sink.
		self!lift-usage($response, $data);

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
		$response.done;

		CATCH {
			default {
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
	my $response = LLM::Chat::Backend::Response::Stream.new(id => uuid-v4());

	start {
		my %settings = self!get-api-settings;
		%settings<messages> = @messages.map(*.to-hash).Array;
		%settings<stream> = True;
		# OpenRouter only emits a `usage` block on streams when this
		# option is set. Without it there's nothing to lift, so force
		# it on — downstream telemetry depends on it.
		%settings<stream_options> = %( include_usage => True );
		%settings<tools> = @tools if @tools.elems > 0;

		my $client = Cro::HTTP::Client.new:
			content-type => 'application/json',
			timeout      => %!request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/chat/completions";

		my $res = await $client.post:
			$url,
			body             => %settings,
			headers          => self!get-api-headers;

		react {
			whenever $res.body-byte-stream -> $data {
				my $decoded = $data.decode('utf-8').trim;
				for $decoded.lines -> $clean {
					when $clean ~~ /^ \n* 'data:' \s* (.*) \s* $/ {
						my $line = ~$0;
						if $line eq '[DONE]' {
							$response.done;
							done;
						} else {
							my $chunk = from-json($line.trim);
							# Usage chunks arrive as the terminal
							# frame (choices=[] + usage populated);
							# also snag model / id off the first
							# chunk that carries them.
							self!lift-usage($response, $chunk);
							my $delta = $chunk<choices>[0]<delta><content>:exists
								?? $chunk<choices>[0]<delta><content>
								!! "";
							$response.emit($delta);

							my $reason = $chunk<choices>[0]<finish_reason> // Nil;
							if $reason.defined {
								given $reason {
									when 'stop' {
										# Don't close yet. When
										# stream_options.include_usage
										# is set, OpenRouter emits the
										# usage frame AFTER the
										# finish_reason chunk and
										# before `[DONE]`; closing here
										# would throw away telemetry.
										# `[DONE]` or a naturally-
										# closed body terminates us.
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
		}

		CATCH {
			default {
				self!classify-exception($_, $response);
				$response.quit($_.message);
			}
		};
	}

	return $response;
}

#|( Lift the OpenRouter-shaped `usage` / `model` / `id` metadata off
    a parsed response body (or a single stream chunk) into the
    Response object. Every extraction is presence-guarded so missing
    keys leave Response attrs undefined — callers read
    C<.prompt-tokens.defined> to distinguish "unknown" from "zero".
    Idempotent on repeated calls with the same chunk, so streaming
    can invoke this per-chunk without worrying about stomping
    already-set values. )
method !lift-usage($response, $payload) {
	return unless $payload ~~ Associative;
	my %args;
	if $payload<usage>:exists && $payload<usage> ~~ Associative {
		my %u = $payload<usage>;
		%args<prompt>     = %u<prompt_tokens>     if %u<prompt_tokens>:exists;
		%args<completion> = %u<completion_tokens> if %u<completion_tokens>:exists;
		%args<total>      = %u<total_tokens>      if %u<total_tokens>:exists;
		%args<cost>       = %u<cost>              if %u<cost>:exists;
	}
	%args<model> = $payload<model> if $payload<model>:exists
	                               && $payload<model>.defined
	                               && $payload<model>.Str.chars;
	%args<id>    = $payload<id>    if $payload<id>:exists
	                               && $payload<id>.defined
	                               && $payload<id>.Str.chars;
	$response._set-usage(|%args) if %args.elems;
}

method text-completion(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message, 
	Bool $continuation = False, 
	--> LLM::Chat::Backend::Response
) {
	my $response = LLM::Chat::Backend::Response.new(id => uuid-v4());

	unless (self.template.defined) {
		$response._set-error-info(class => 'unknown');
		$response.quit("Must define template in backend to use text completion");

		return $response;
	}

	start {
		my %settings = self!get-api-settings;
		my $template = self.template;
		%settings<prompt> = $template.render(
			@messages,
			$continuation,
		);

		my $client = Cro::HTTP::Client.new:
			content-type => 'application/json',
			timeout      => %!request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/completions";

		my $res = await $client.post:
			$url,
			body    => %settings,
			headers => self!get-api-headers;

		my $data = await $res.body;

		my $msg  = $data<choices>[0]<text>;

		$response.emit($msg);
		$response.done;

		CATCH {
			default {
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
	my $response = LLM::Chat::Backend::Response::Stream.new(id => uuid-v4());

	unless self.template.defined {
		$response._set-error-info(class => 'unknown');
		$response.quit("Must define template in backend to use text completion stream");
		return $response;
	}

	start {
		my %settings = self!get-api-settings;
		my $template = self.template;
		%settings<prompt> = $template.render(
			@messages,
			$continuation,
		);
		%settings<stream> = True;

		my $client = Cro::HTTP::Client.new:
			content-type => 'application/json',
			timeout      => %!request-timeout;

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/completions";

		my $res = await $client.post:
			$url,
			body    => %settings,
			headers => self!get-api-headers;

		react {
			whenever $res.body-byte-stream -> $data {
				my $decoded = $data.decode('utf-8').trim;
				for $decoded.lines -> $line {
					when $line ~~ /^ \n* 'data:' \s* (.*) \s* $/ {
						my $payload = ~$0;
						if $payload eq '[DONE]' {
							$response.done;
							done;
						} else {
							my $chunk = from-json($payload.trim);
							my $text = $chunk<choices>[0]<text> // "";

							$response.emit($text);

							my $reason = $chunk<choices>[0]<finish_reason> // Nil;
							if $reason.defined {
								given $reason {
									when 'stop' { 
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
		}

		CATCH {
			default {
				$response.quit($_.message);
			}
		}
	}

	return $response;
}

method cancel(LLM::Chat::Backend::Response $resp) {
	$resp.cancel;
}
