unit class LLM::Chat::Conversation::Message;

use Digest::SHA256::Native;

subset ChatRole of Str where {
	   $_ eq 'user'
	|| $_ eq 'assistant'
	|| $_ eq 'system'
	|| $_ eq 'tool'
};

has ChatRole   $.role      is required;
has Str        $.content   is required;
has Bool       $.sticky    = False;
has Bool       $.sysprompt = False;
has Int        $.depth     is rw;
has Str        $.checksum  is rw;

method to-hash {
	{
		role    => ~$!role,
		content => $!content,
	};
}

method get-checksum {
	return $!checksum if $!checksum.defined;

	my $seri   = "role={$!role};content={$!content}";
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
