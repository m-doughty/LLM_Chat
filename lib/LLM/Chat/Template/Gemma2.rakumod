use LLM::Chat::Conversation::Message;
use LLM::Chat::Template;

unit class LLM::Chat::Template::Gemma2 is LLM::Chat::Template;

method name { 'gemma-2' }

method render(@messages, $continuation = False, --> Str) {
	my $out = "";

	my $last = $continuation ?? @messages.pop !! Nil;

	for @messages -> $msg {
		my $role = $msg.role eq 'user'      ?? 'user' 
			!! $msg.role eq 'system'    ?? 'user'
			!!                             'model';

		$out ~= "<start_of_turn>{$role}\n{$msg.content}\n<end_of_turn>\n";
	}

	if $continuation && $last.defined {
		my $role = $last.role eq 'user'      ?? 'user' 
			!! $last.role eq 'system'    ?? 'user'
			!!                              'model';

		$out ~= "<start_of_turn>{$role}\n{$last.content}";
	}

	return $out;
}

