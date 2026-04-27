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

	return %r;
}

method _get-api-headers(--> Hash) {
    my %h;
    %h<Authorization> = "Bearer {$!api_key}" if $!api_key.defined;
    return %h;
}

method cancel(LLM::Chat::Backend::Response $resp) {
	my $client = Cro::HTTP::Client.new:
		content-type => 'application/json';

	my $url = $.api_url.subst(/ 'v1' '/'? $/, '');
	$url ~= "/api/extra/abort";

	await $client.post:
		$url,
		headers => self._get-api-headers;

	$resp.cancel;
}
