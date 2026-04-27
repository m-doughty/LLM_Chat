=begin pod

=head1 NAME

LLM::Chat::Backend::Response::OpenRouter::Stream - Streaming variant of Response::OpenRouter

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Chat::Backend::Response::OpenRouter::Stream;

# Constructed by L<LLM::Chat::Backend::OpenRouter>'s
# C<chat-completion-stream> path. Behaves like
# C<LLM::Chat::Backend::Response::Stream> (accumulates emitted
# tokens into C<.latest>) and additionally carries
# C<.cost> / C<.generation-id> / C<.provider-name> / C<.is-byok>
# from the L<...::OpenRouter::Augment> role.

=end code

=head1 DESCRIPTION

Subclass of L<LLM::Chat::Backend::Response::Stream> that consumes
the L<LLM::Chat::Backend::Response::OpenRouter::Augment> role to
add OR-specific usage + routing fields. The streaming
C<._emit> / C<._done> behaviour is inherited unchanged from the
base stream class.

OR's terminal usage frame (sent after C<finish_reason: stop>, before
C<[DONE]>) is lifted by the backend via
C<_set-or-usage> on this same instance — so cost / generation-id /
provider-name become readable by the time the supply done-signal
fires.

=end pod

use LLM::Chat::Backend::Response::Stream;
use LLM::Chat::Backend::Response::OpenRouter;

unit class LLM::Chat::Backend::Response::OpenRouter::Stream
	is LLM::Chat::Backend::Response::Stream
	does LLM::Chat::Backend::Response::OpenRouter::Augment;
