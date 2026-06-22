unit class LLM::Chat::Conversation::Message;

use Digest::SHA256::Native;

subset ChatRole of Str where {
	   $_ eq 'user'
	|| $_ eq 'assistant'
	|| $_ eq 'system'
	|| $_ eq 'tool'
};

has ChatRole   $.role      is required;
has Str        $.content   = "";
has            @.tool-calls;
has Str        $.tool-call-id;
has Bool       $.sticky    = False;
has Bool       $.sysprompt = False;
has Int        $.depth     is rw;
has Str        $.checksum  is rw;

method to-hash {
	my %h =
		role    => ~$!role,
		content => $!content;

	if @!tool-calls.elems {
		%h<tool_calls> = @!tool-calls;
		%h<content> = Any if $!role eq 'assistant' && $!content eq '';
	}

	%h<tool_call_id> = $!tool-call-id if $!tool-call-id.defined;

	%h;
}

method get-checksum {
	return $!checksum if $!checksum.defined;

	my $seri   = self.to-hash.raku;
	$!checksum = sha256-hex($seri);

	return $!checksum;
}

method is-sysprompt {
	$!sysprompt;
}

method is-sticky {
	$!sticky || $!depth.defined || $!sysprompt;
}

method is-insert-at-depth {
	$!depth.defined;
}

method gist {
	"{$.role.uc}: {$.content.substr(0, 40) ~ '...'}"
}
