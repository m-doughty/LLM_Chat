use JSON::Fast;
use UUID::V4;

use LLM::Chat::Backend;
use LLM::Chat::Backend::Response::Stream;
use LLM::Chat::Conversation::Message;

unit class LLM::Chat::ToolLoop;

has LLM::Chat::Backend $.backend is required;
has @.tools;
has &.execute-tools is required;
has Int $.max-tool-rounds = 4;
has Int $.max-tool-calls = 12;
has Int $.max-identical-calls = 2;
has $.on-tool-call;
has $.on-tool-result;
has $.on-limit;

my constant LIMIT-MESSAGE =
	'Tool call limit reached. Do not call tools again. Answer using the information already available, and state if more tool work would be needed.';

method chat-completion-stream(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	--> LLM::Chat::Backend::Response::Stream
) {
	my $id = uuid-v4;
	my $out = LLM::Chat::Backend::Response::Stream.new(:$id);

	start {
		my @conversation = @messages;
		my Int $rounds = 0;
		my Int $total-calls = 0;
		my %call-counts;
		my Bool $tools-enabled = True;

		loop {
			my @request-tools = $tools-enabled ?? @!tools !! ();
			my $resp = @request-tools.elems
				?? $!backend.chat-completion-stream(
					@conversation,
					tools => @request-tools,
				)
				!! $!backend.chat-completion-stream(@conversation);

			last unless self!forward-stream($resp, $out);
			last unless $tools-enabled && $resp.has-tool-calls;

			my @tool-calls = $resp.tool-calls;
			my $limit = self!limit-reason(
				@tool-calls,
				$rounds,
				$total-calls,
				%call-counts,
			);

			if $limit.defined {
				self!notify($!on-limit, $limit, @tool-calls);
				@conversation.push: LLM::Chat::Conversation::Message.new(
					role    => 'system',
					content => LIMIT-MESSAGE,
				);
				$tools-enabled = False;
				next;
			}

			@conversation.push: LLM::Chat::Conversation::Message.new(
				role       => 'assistant',
				content    => $resp.msg // '',
				tool-calls => @tool-calls,
			);

			for @tool-calls -> %call {
				my $sig = self!tool-call-signature(%call);
				%call-counts{$sig} = (%call-counts{$sig} // 0) + 1;
				self!notify($!on-tool-call, %call);
			}

			my @results = self!execute(@tool-calls);
			for @results -> $result {
				my %result = $result ~~ Associative
					?? $result.Hash
					!! %(content => ~$result);

				@conversation.push: LLM::Chat::Conversation::Message.new(
					role         => 'tool',
					content      => ~(%result<content> // ''),
					tool-call-id => ~(%result<tool_call_id> // ''),
				);
				self!notify($!on-tool-result, %result);
			}

			$total-calls += @tool-calls.elems;
			$rounds++;
		}

		$out.done unless $out.is-done;

		CATCH {
			default {
				$out.quit(.message) unless $out.is-done;
			}
		}
	}

	$out;
}

method !forward-stream(
	LLM::Chat::Backend::Response::Stream $source,
	LLM::Chat::Backend::Response::Stream $target,
	--> Bool
) {
	my $done = Promise.new;
	my Bool $ok = True;

	$source.supply.tap(
		-> $chunk {
			$target.emit($chunk)
				if $chunk.defined && $chunk.Str.chars && !$target.is-done;
		},
		done => -> { $done.keep if $done.status ~~ Planned },
		quit => -> $err {
			$ok = False;
			$done.break($err) if $done.status ~~ Planned;
		},
	);

	try {
		await $done;
		CATCH {
			default {
				$target.quit(.message) unless $target.is-done;
				$ok = False;
			}
		}
	}

	unless $source.is-success {
		$target.quit($source.err // 'Completion stream failed')
			unless $target.is-done;
		$ok = False;
	}

	$ok;
}

method !limit-reason(
	@tool-calls,
	Int:D $rounds,
	Int:D $total-calls,
	%call-counts,
) {
	return "maximum tool rounds exceeded ({$!max-tool-rounds})"
		if $rounds >= $!max-tool-rounds;

	return "maximum total tool calls exceeded ({$!max-tool-calls})"
		if $total-calls + @tool-calls.elems > $!max-tool-calls;

	for @tool-calls -> %call {
		my $sig = self!tool-call-signature(%call);
		return "maximum identical tool calls exceeded ({$!max-identical-calls})"
			if (%call-counts{$sig} // 0) >= $!max-identical-calls;
	}

	Nil;
}

method !execute(@tool-calls --> List) {
	my @results;
	my $exec-error;

	try {
		@results = &!execute-tools(@tool-calls);
		CATCH {
			default {
				$exec-error = .message;
			}
		}
	}

	return @results.List unless $exec-error.defined;

	@tool-calls.map(-> %call {
		{
			role         => 'tool',
			tool_call_id => %call<id> // '',
			content      => $exec-error,
			is_error     => True,
		}
	}).list;
}

method !tool-call-signature(%call --> Str) {
	my $name = %call<function><name> // '';
	my $args = %call<function><arguments> // '';
	$args = to-json($args) if $args ~~ Associative;
	"$name\0$args";
}

method !notify($callback, |args) {
	return unless $callback.defined;
	try {
		$callback(|args);
		CATCH { default { } }
	}
}
