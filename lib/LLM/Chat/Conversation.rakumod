use LLM::Chat::Conversation::Message;
use LLM::Chat::TokenCounter;

unit class LLM::Chat::Conversation;

has LLM::Chat::TokenCounter $.token-counter  is required;
has Int                     $.context-budget is required;

method insert-at-depth(
	LLM::Chat::Conversation::Message $msg,
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message
) {
	my $depth     = $msg.depth;
	my $insert-at = @messages.elems - $depth;
	$insert-at    = 0 if $insert-at < 1;

	@messages.splice($insert-at, 0, $msg);
	return @messages;
}

method needs-context-shift(@messages where all(@messages) ~~ LLM::Chat::Conversation::Message) {
	$!token-counter.get-conversation-count(@messages) > $!context-budget;
}

method can-context-shift(@messages where all(@messages) ~~ LLM::Chat::Conversation::Message) {
	self.sticky-budget(@messages) < $!context-budget;
}

method sticky-budget(@messages where all(@messages) ~~ LLM::Chat::Conversation::Message) {
	my @sticky = @messages.grep: *.is-sticky;
	$!token-counter.get-conversation-count(@sticky);
}

method extract-sysprompt(@messages where all(@messages) ~~ LLM::Chat::Conversation::Message, @non-sys, @sys) {
	@sys     = @messages.grep: *.is-sysprompt;
	@non-sys = @messages.grep: *.is-sysprompt.not;
}

method extract-insert-at-depth(@messages where all(@messages) ~~ LLM::Chat::Conversation::Message, @non-iad, @iad) {
	@iad     = @messages.grep: *.is-insert-at-depth;
	@non-iad = @messages.grep: *.is-insert-at-depth.not;
}

method prepare-for-inference(@messages where all(@messages) ~~ LLM::Chat::Conversation::Message) {
	self.extract-sysprompt(@messages, my @non-sys, my @sys);
	self.extract-insert-at-depth(@non-sys, my @msgs, my @iad);

	if self.needs-context-shift(@messages) {
		return Failure.new("Context exceeded by sticky messages. Cannot proceed.")
			unless self.can-context-shift(@messages);

		my $sticky-budget = self.sticky-budget(@messages);
		my $budget = $!context-budget - $sticky-budget - $!token-counter.get-template-count;

		my $i = @msgs.elems - 1;
		my @new = ();
		loop {
			if @msgs[$i].is-sticky {
				@new.unshift(@msgs[$i]);
			} elsif $budget >= 0 {
				$budget -= $!token-counter.get-message-count(@msgs[$i]);
				@new.unshift(@msgs[$i]) if $budget >= 0;
			}
			last if $i <= 0;
			$i--;
		}

		@msgs = @new;
	}

	for @iad -> $ins {
		@msgs = self.insert-at-depth($ins, @msgs);
	}

	@sys.append: @msgs;
	return @sys;
}

