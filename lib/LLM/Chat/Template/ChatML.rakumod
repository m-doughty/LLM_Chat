use LLM::Chat::Conversation::Message;
use LLM::Chat::Template;

unit class LLM::Chat::Template::ChatML is LLM::Chat::Template;

method name { 'chatml' }

method render(@messages, $continuation = False, --> Str) {
	my $out = "";

	my $last = $continuation ?? @messages.pop !! Nil;

	for @messages -> $msg {
		$out ~= "<|im_start|>{$msg.role}\n{$msg.content}\n<|im_end|>\n";
	}

	if $continuation && $last.defined {
		$out ~= "<|im_start|>{$last.role}\n{$last.content}";
	}

	return $out;
}

