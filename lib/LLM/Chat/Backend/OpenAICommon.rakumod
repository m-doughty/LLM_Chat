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
			content-type => 'application/json';

		my $url = $.api_url.subst(/'/' $/, '');
		$url ~= "/chat/completions";

		my $res = await $client.post:
			$url,
			body    => %settings,
			headers => self!get-api-headers;

		my $data = await $res.body;

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
		%settings<tools> = @tools if @tools.elems > 0;

		my $client = Cro::HTTP::Client.new: 
			content-type => 'application/json';

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
							my $delta = $chunk<choices>[0]<delta><content>:exists 
								?? $chunk<choices>[0]<delta><content> 
								!! "";
							$response.emit($delta);

							my $reason = $chunk<choices>[0]<finish_reason> // Nil;
							if $reason.defined {
								given $reason {
									when 'stop' { 
										$response.done;
										done; 
									}
									when 'length' { 
										$response.quit("Hit max tokens"); 
										done;
									}
									when 'content_filter' {
										$response.quit("Blocked by content filter");
										done;
									}
									default {
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
		};
	}

	return $response;
}

method text-completion(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message, 
	Bool $continuation = False, 
	--> LLM::Chat::Backend::Response
) {
	my $response = LLM::Chat::Backend::Response.new(id => uuid-v4());

	unless (self.template.defined) {
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
			content-type => 'application/json';

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
			content-type => 'application/json';

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
										$response.quit("Hit max tokens");
										done;
									}
									when 'content_filter' {
										$response.quit("Blocked by content filter");
										done;
									}
									default {
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
