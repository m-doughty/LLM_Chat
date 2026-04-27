=begin pod

=head1 NAME

LLM::Chat::Backend::Response::OpenRouter - OpenRouter-flavoured Response with cost + routing metadata

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Chat::Backend::Response::OpenRouter;
use UUID::V4;

# Built by L<LLM::Chat::Backend::OpenRouter>'s C<chat-completion> path
# — you rarely construct one directly. The shape below shows what's
# available once the backend has lifted the response body.
my $resp = LLM::Chat::Backend::Response::OpenRouter.new(id => uuid-v4());

# Inherited from base Response (OAI-spec):
#   $resp.prompt-tokens / completion-tokens / total-tokens / model-used
#
# Added by Augment (OpenRouter-specific):
#   $resp.cost            — USD spent (Num) when usage.cost is in the body
#   $resp.generation-id   — OR's "gen-XXXX" id for /generation lookups
#   $resp.provider-name   — provider OR routed to (e.g. "Anthropic")
#   $resp.is-byok         — True when call used user's BYOK keys

=end code

=head1 DESCRIPTION

Subclass of L<LLM::Chat::Backend::Response> that adds OpenRouter-only
usage and routing fields via the
L<LLM::Chat::Backend::Response::OpenRouter::Augment> role. Use it (or
its streaming sibling
L<LLM::Chat::Backend::Response::OpenRouter::Stream>) when you need to
read costs, look up generation metadata via OpenRouter's
C</generation> endpoint, or branch on which underlying provider
served a request.

The split lets a generic OpenAI-compatible client (any
C<OpenAICommon>-derived backend) keep its Response surface clean —
fields that don't exist on the wire for OpenAI proper don't leak
into the base type.

=head2 Why a role + two classes?

C<Response> and C<Response::Stream> are sibling classes (Stream
extends Response). Adding the OR-specific attrs + setter via a role
that both classes consume avoids diamond inheritance and keeps the
extra fields in one place.

The role declares only attrs and a fresh setter — no C<callsame> /
C<nextsame> dispatch from inside the role, so it sidesteps the
known-broken role-redispatch case.

=end pod

use LLM::Chat::Backend::Response;

#|( OpenRouter-specific usage + routing fields, plus a presence-gated
    setter. Consumed by both C<Response::OpenRouter> and
    C<Response::OpenRouter::Stream>.

    Each attr stays undefined unless the backend explicitly populates
    it — callers should test C<.cost.defined> (etc.) before reading,
    so they can distinguish "provider didn't tell us" from a literal
    zero. )
role LLM::Chat::Backend::Response::OpenRouter::Augment {
	has Num  $.cost;
	has Str  $.generation-id;
	has Str  $.provider-name;
	has Bool $.is-byok;

	#|( Partial-update OR-specific usage fields. Every parameter is
	    optional; only defined values are written. Idempotent on
	    repeat calls with the same payload — safe to invoke
	    per-streaming-chunk without stomping already-set fields. )
	method _set-or-usage(
		:$cost, :$generation-id, :$provider-name, :$is-byok,
	) {
		$!cost           = $cost.Num            if $cost.defined;
		$!generation-id  = $generation-id.Str   if $generation-id.defined;
		$!provider-name  = $provider-name.Str   if $provider-name.defined;
		$!is-byok        = $is-byok.Bool        if $is-byok.defined;
	}
}

class LLM::Chat::Backend::Response::OpenRouter
	is LLM::Chat::Backend::Response
	does LLM::Chat::Backend::Response::OpenRouter::Augment { }
