use Tokenizers;
use LLM::Chat::Template;
use LLM::Chat::Conversation::Message;

unit class LLM::Chat::TokenCounter;

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
		:add-special-tokens(False)
	);

	return %!template-counts{$template-name};
}

method get-message-count(LLM::Chat::Conversation::Message $message, --> Int) {
	my $message-checksum = $message.get-checksum;
	return %!message-counts{$message-checksum}
		if (%!message-counts{$message-checksum}:exists);

	%!message-counts{$message-checksum} = $!tokenizer.count(
		$!template.render([$message]),
		:add-special-tokens(False)
	) - self.get-template-count();

	return %!message-counts{$message-checksum};
}

method get-conversation-count(@messages where all(@messages) ~~ LLM::Chat::Conversation::Message, --> Int) {
	$!tokenizer.count(
		$!template.render(@messages), 
		:add-special-tokens(False)
	);
}

