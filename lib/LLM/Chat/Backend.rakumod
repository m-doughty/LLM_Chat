use LLM::Chat::Conversation::Message;
use LLM::Chat::Backend::Response;
use LLM::Chat::Backend::Response::Stream;
use LLM::Chat::Backend::Settings;
use LLM::Chat::Template;

unit class LLM::Chat::Backend;

has LLM::Chat::Backend::Settings $.settings     is required is rw;
has LLM::Chat::Template          $.template;

method set-settings(LLM::Chat::Backend::Settings $settings) {
	$!settings = $settings;
}

method chat-completion(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	--> LLM::Chat::Backend::Response
) {
	fail "chat-completion must be implemented by the subclass";
}

method chat-completion-stream(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message, 
	--> LLM::Chat::Backend::Response::Stream
) {
	fail "chat-completion-stream must be implemented by the subclass";
}

method text-completion(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message, 
	Bool $continuation = False, 
	--> LLM::Chat::Backend::Response
) {
	fail "text-completion must be implemented by the subclass";
}

method text-completion-stream(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message, 
	Bool $continuation = False, 
	--> LLM::Chat::Backend::Response::Stream
) {
	fail "text-completion-stream must be implemented by the subclass";
}

method cancel(LLM::Chat::Backend::Response $resp) {
	fail "cancel must be implemented by the subclass";
}
