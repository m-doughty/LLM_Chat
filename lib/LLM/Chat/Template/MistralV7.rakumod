use LLM::Chat::Conversation::Message;
use LLM::Chat::Template;

unit class LLM::Chat::Template::MistralV7 is LLM::Chat::Template;

method name { 'mistral-v7' }

method render(@messages, $continuation = False, --> Str) {
	my $out = "<s>";

	my $postfix = "";
	$postfix = @messages.pop if $continuation;

	for @messages -> $msg {
		given $msg.role {
			when 'system' {
				$out ~= "[SYSTEM_PROMPT]{$msg.content}[/SYSTEM_PROMPT]";
			}
			when 'user' {
				$out ~= "[INST]{$msg.content}[/INST]";
			}
			when 'assistant' {
				$out ~= "{$msg.content}</s>";
			}
			default {
				die "Unsupported role: $msg.role";
			}
		}
	}

	$out ~= $postfix.content if $continuation;

	return $out;
}

