use Tokenizers;
use LLM::Chat::Template;
use LLM::Chat::Conversation::Message;

unit class LLM::Chat::TokenCounter;

our class InvalidRequest is Exception {
	has Str $.detail is required;
	method message { $!detail }
}

has Tokenizers          $.tokenizer is required;
has LLM::Chat::Template $.template  is required;
has                     %.template-counts = ();
has                     %.message-counts  = ();

method get-template-count(--> Int) {
	my $template-name = $!template.name;
	return %!template-counts{$template-name}
		if (%!template-counts{$template-name}:exists);

	%!template-counts{$template-name} = $!tokenizer.count(
		$!template.render([]),
		:add-special-tokens(False),
		:allow-special-tokens,
	);

	return %!template-counts{$template-name};
}

method get-message-count(LLM::Chat::Conversation::Message $message, --> Int) {
	my $message-checksum = $message.get-checksum;
	return %!message-counts{$message-checksum}
		if (%!message-counts{$message-checksum}:exists);

	%!message-counts{$message-checksum} = $!tokenizer.count(
		$!template.render([$message]),
		:add-special-tokens(False),
		:allow-special-tokens,
	) - self.get-template-count();

	return %!message-counts{$message-checksum};
}

method get-conversation-count(@messages where all(@messages) ~~ LLM::Chat::Conversation::Message, --> Int) {
	$!tokenizer.count(
		$!template.render(@messages), 
		:add-special-tokens(False),
		:allow-special-tokens,
	);
}

#|( Count exactly what one selected-model request will render.

    C<@messages> remains the stored conversation. Optional runtime context is
    projected in the same order as LLM::Agent::Loop's wire view:
    C<[context-head, |@messages, context-tail]>. Tool declarations are passed
    to the template because they are part of the selected model's prompt.
    Neither the messages nor tool structures are mutated. )
method get-request-count(
	@messages,
	:@tools,
	:$context-head,
	:$context-tail,
	Bool :$continuation = False,
	--> Int
) {
	for @messages.list.kv -> $index, $message {
		LLM::Chat::TokenCounter::InvalidRequest.new(
			detail => "messages[$index] must be an LLM::Chat::Conversation::Message"
		).throw unless $message ~~ LLM::Chat::Conversation::Message;
	}
	for context-head => $context-head, context-tail => $context-tail -> $part {
		next unless $part.value.defined;
		LLM::Chat::TokenCounter::InvalidRequest.new(
			detail => "{$part.key} must be a Str or an LLM::Chat::Conversation::Message"
		).throw unless $part.value ~~ Str:D
			|| $part.value ~~ LLM::Chat::Conversation::Message;
	}
	for @tools.list.kv -> $index, $tool {
		LLM::Chat::TokenCounter::InvalidRequest.new(
			detail => "tools[$index] must be an associative tool declaration"
		).throw unless $tool ~~ Associative;
	}

	my $head-message = $context-head ~~ Str:D
		?? LLM::Chat::Conversation::Message.new(
			role => 'system', content => $context-head,
		)
		!! $context-head;
	my $tail-message = $context-tail ~~ Str:D
		?? LLM::Chat::Conversation::Message.new(
			role => 'system', content => $context-tail,
		)
		!! $context-tail;
	my @wire = (
		|($head-message.defined ?? ($head-message,) !! ()),
		|@messages,
		|($tail-message.defined ?? ($tail-message,) !! ()),
	);
	my $rendered = $!template.render(
		@wire,
		$continuation,
		|(@tools.elems ?? (tools => @tools.list) !! ()),
	);
	$!tokenizer.count(
		$rendered, :add-special-tokens(False), :allow-special-tokens,
	);
}
