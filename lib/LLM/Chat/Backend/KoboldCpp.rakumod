use LLM::Chat::Backend::OpenAICommon;
use LLM::Chat::Conversation::Message;
use LLM::Chat::Backend::Response;
use LLM::Chat::Backend::Response::Stream;

use Cro::HTTP::Client;
use JSON::Fast;
use UUID::V4;

unit class LLM::Chat::Backend::KoboldCpp is LLM::Chat::Backend::OpenAICommon;

has Str $.api_url is required;
has Str $.api_key is rw;
has Str $.model   is rw;

# Local dense models can spend well over 60s in prompt prefill on long
# context before the OAI-compatible endpoint sends response headers.
# Keep the parent's connection and total limits, but do not classify a
# healthy long-prefill KoboldCpp request as a headers timeout.
method _request-timeout(--> Hash) {
	my %timeout = callsame.Hash;
	%timeout<headers> = Inf if (%timeout<headers> // 60) == 60;
	%timeout;
}

#|( KoboldCpp accepts the OAI-spec body fields plus a long tail of
    sampler extras (top_k, min_p, typical_p, DRY, XTC, ...). Override
    of OpenAICommon's hook so the inherited chat / text completion
    methods send the full surface. )
method _get-api-settings(--> Hash) {
	my $s = self.settings;
	my %r;

	%r<model>                 = $!model if $!model.defined;
	%r<max_tokens>            = $s.max_tokens;
	%r<max_length>            = $s.max_tokens;
	%r<temperature>           = $s.temperature;
	%r<top_p>                 = $s.top_p;
	%r<top_k>                 = $s.top_k;
	%r<min_p>                 = $s.min_p;
	%r<typical_p>             = $s.typical_p;
	%r<repetition_penalty>    = $s.repetition_pen;
	%r<rep_pen>               = $s.repetition_pen;
	%r<presence_penalty>      = $s.presence_pen;
	%r<frequency_penalty>     = $s.frequency_pen;
	%r<max_context_length>    = $s.max_context;
	%r<stop>                  = $s.stop.Array;
	%r<dry_base>              = $s.dry_base;
	%r<dry_allowed_length>    = $s.dry_allowed_len;
	%r<dry_multiplier>        = $s.dry_multiplier;
	%r<dry_sequence_breakers> = $s.dry_seq_break.Array;
	%r<xtc_probability>       = $s.xtc_probability;
	%r<xtc_threshold>         = $s.xtc_threshold;

	# Structured outputs: KoboldCpp accepts a json_schema generate
	# field natively and compiles it to a grammar — sampler-level
	# enforcement, unlike the best-effort OpenAI response_format.
	# Older KoboldCpp builds ignore unknown fields harmlessly.
	%r<json_schema> = $s.json_schema with $s.json_schema;

	return %r;
}

method _get-api-headers(--> Hash) {
    my %h;
    %h<Authorization> = "Bearer {$!api_key}" if $!api_key.defined;
    return %h;
}

#|( Cancel an in-flight generation. The local response stream closes
    FIRST, synchronously — the consumer side sees the cancel
    immediately and unconditionally. The upstream abort
    (C<POST /api/extra/abort>) then fires on a worker thread,
    best-effort: a slow, hung, or unreachable KoboldCpp must never
    block the cancelling thread (this is reached from TUI keybind
    handlers), and a lost abort costs at most a few wasted tokens
    server-side since KoboldCpp also stops generating when the SSE
    connection drops. Network failures are swallowed. The previous
    ordering — await the abort, then close locally — meant a dead
    backend made C<cancel> throw before the local close ever ran.
    Returns the background Promise so tests can await the abort
    attempt deterministically; production callers may sink it. )
method cancel(LLM::Chat::Backend::Response $resp --> Promise) {
	$resp.cancel;

	# Strip the OAI-compat /v1 suffix (and any slashes around it) —
	# the abort endpoint lives at the server root. The old pattern
	# left the slash BEFORE v1 in place, producing //api/extra/abort.
	my $url = $.api_url.subst(/ '/'? 'v1' '/'? $/, '');
	$url ~= "/api/extra/abort";
	my %headers = self._get-api-headers;

	start {
		my $client = Cro::HTTP::Client.new:
			content-type => 'application/json';
		try await $client.post: $url, headers => %headers;
	}
}
