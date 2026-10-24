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
	:@tools,
	--> LLM::Chat::Backend::Response
) {
	fail "chat-completion must be implemented by the subclass";
}

method chat-completion-stream(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	:@tools,
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

#|( What the server says about its own limits: a Hash with C<source>
    and either C<context_length> (plus C<slots> when known) or a
    C<note> saying why nothing was learnt. A backend that cannot ask
    its server answers with a note and no network traffic; see
    L<LLM::Chat::Backend::OpenAICommon> for the servers that can. )
method probe-server-limits(--> Hash:D) {
	%(source => 'none', note => "{self.^name} reports no server limits");
}
