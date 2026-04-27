=begin pod

=head1 NAME

LLM::Chat::Debug - Optional wire-level debug log for chat backends

=head1 DESCRIPTION

Append-only file logger for raw HTTP traffic on chat backends. Gated
on the C<LLM_CHAT_DEBUG> environment variable: when set, treated as a
filesystem path and every request / response chunk is appended there.
When unset, every C<log> call is a no-op so the production cost is a
hash lookup per call.

The logger serialises concurrent writes through an internal lock — it's
safe to call from multiple in-flight backends at once.

The C<Authorization> header is redacted automatically when a header
hash is logged via C<log-headers>; everything else is written verbatim,
so prompts, model names, generation ids, and provider-specific extras
are all visible. Keep the log out of source control.

=head1 SYNOPSIS

=begin code :lang<raku>

# Enable for the lifetime of a process:
#   LLM_CHAT_DEBUG=/tmp/llm-chat.log raku script.raku
#   tail -f /tmp/llm-chat.log

use LLM::Chat::Debug;

LLM::Chat::Debug.log('REQUEST URL',  $url);
LLM::Chat::Debug.log-headers('REQUEST HEADERS', %headers);
LLM::Chat::Debug.log-json('REQUEST BODY', %body);

# In a streaming loop:
LLM::Chat::Debug.log('SSE LINE', $raw-line);

LLM::Chat::Debug.log('RESPONSE END', "done");

=end code

=end pod

unit class LLM::Chat::Debug;

use JSON::Fast;

my Lock $LOG-LOCK = Lock.new;

#|( Append a single labelled record to the debug log if C<LLM_CHAT_DEBUG>
    is set in the environment. Adds a timestamp + section banner so
    successive records are easy to scan in C<tail -f>. Returns silently
    when the env var is unset — call sites pay only a single hash
    lookup. )
method log(Str:D $label, Str:D $body) {
	my $path = %*ENV<LLM_CHAT_DEBUG>;
	return unless $path && $path.chars;
	$LOG-LOCK.protect: {
		my $fh = open $path, :a;
		my $ts = DateTime.now;
		$fh.say("[$ts] === $label ===");
		$fh.say($body);
		$fh.say('');
		$fh.close;
	}
}

#|( Convenience: pretty-print a hash as JSON before logging. Most of
    the wire traffic — request bodies, parsed response chunks — is
    already structured, and a JSON dump is dramatically more readable
    than C<.gist>. Falls back to C<.gist> when the value isn't a Hash
    so callers don't have to branch. )
method log-json(Str:D $label, $body) {
	my $rendered = $body ~~ Associative
		?? to-json($body, :pretty)
		!! $body.gist;
	self.log($label, $rendered);
}

#|( Like C<log-json> but redacts the C<Authorization> header (and
    common variants) so log files are safe to share when triaging
    upstream issues. Does not redact attribution headers
    (C<HTTP-Referer>, C<X-Title>) which are non-sensitive. )
method log-headers(Str:D $label, %headers) {
	my %safe = %headers.kv.map(-> $k, $v {
		$k => ($k.lc eq 'authorization' | 'x-rest-token' ?? '<redacted>' !! $v);
	}).Hash;
	self.log-json($label, %safe);
}
