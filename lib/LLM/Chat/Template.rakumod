unit class LLM::Chat::Template;
use LLM::Chat::Conversation::Message;

method name(--> Str) {
	die "name must be implemented by the concrete class";
}

method render(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	Bool $continuation = False,
	--> Str
) {
	die "render must be implemented by the concrete class";
}
