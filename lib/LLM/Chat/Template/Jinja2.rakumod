use LLM::Chat::Conversation::Message;
use LLM::Chat::Template;
use Template::Jinja2;
use JSON::Fast;

unit class LLM::Chat::Template::Jinja2 is LLM::Chat::Template;

has Str:D $.template is required;
has Str $.bos-token = '';
has Str $.eos-token = '';
has Template::Jinja2 $!env;

submethod TWEAK {
	$!env = Template::Jinja2.new;
}

method name(--> Str) { 'jinja2' }

#|( The decoded form of a tool call's C<arguments>, or C<Nil> when
    they should be left exactly as they are.

    Deliberately narrow. Only a C<Str> whose first non-space character
    is C<{> is even a candidate, and it has to C<from-json> into an
    C<Associative> — so an empty string, a fragment truncated
    mid-stream, a bare scalar, a JSON array, and arguments a caller
    already handed over as a Hash all fall through untouched. A
    template that stringifies whatever it is given still gets
    something sensible in every one of those cases, which would not be
    true if this guessed. )
my sub decoded-arguments($arguments) {
	return Nil unless $arguments ~~ Str:D;

	my $trimmed = $arguments.trim;
	return Nil unless $trimmed.starts-with('{');

	# `try` and not a bare call: half a JSON object is exactly what a
	# stream cut short leaves behind, and that must render, not throw.
	my $parsed = try from-json($trimmed);
	$parsed ~~ Associative ?? $parsed !! Nil;
}

#|( A message hash ready to hand to the Jinja engine, with tool-call
    C<arguments> presented as decoded objects.

    B<Why.> HuggingFace chat templates are written against the
    structure Python's C<transformers> passes them, where a tool
    call's C<arguments> is a I<dict>. Templates iterate it —
    GLM-family templates do
    C<< {%- for k, v in tc.function.arguments.items() %} >>, and
    plenty of others index it by key. On the OpenAI wire, though,
    C<arguments> is a B<JSON string>, which is what
    C<Conversation::Message.to-hash> carries because that is what the
    request body needs. Handed a string, C<.items()> is at best a
    render that silently drops every argument and at worst an error —
    for a token counter, an undercount of exactly the part of the
    prompt most likely to be large.

    B<Why a copy.> C<to-hash> shares the message's live C<@!tool-calls>
    — the array, the call hashes and the function hashes inside them
    are all the same objects the Message holds. Rewriting C<arguments>
    in place would therefore change the Message itself, and the next
    request built from that conversation would put a JSON I<object>
    where the wire format requires a string. So the message hash, the
    tool-call array, each call, and each function hash are copied
    before anything is replaced; nothing the Message owns is touched.
    Values that are not rewritten are shared, not cloned — they are
    only ever read from here.

    C<Message.to-hash> itself is deliberately left alone: it is the
    wire path. )
my sub template-tool-call($call) {
	return $call unless $call ~~ Associative;

	my %copy = $call;
	if %copy<function> ~~ Associative {
		my %function = %copy<function>;
		with decoded-arguments(%function<arguments>) -> $decoded {
			%function<arguments> = $decoded;
		}
		%copy<function> = %function;
	}
	%copy;
}

my sub template-message-hash($message --> Hash:D) {
	my %hash = $message.to-hash;

	my $calls = %hash<tool_calls>;
	return %hash unless $calls ~~ Positional && $calls.elems;

	%hash<tool_calls> = $calls.list.map({ template-tool-call($_) }).Array;
	%hash;
}

#|( Render C<@messages> through the template.

    C<$continuation> C<True> renders the conversation as it stands, for a
    model to carry on from; C<False> — the default — appends the
    template's generation prompt (C<add_generation_prompt>).

    C<:@tools> are the tool declarations the request will carry, in the
    shape the provider takes them (C<< { type => 'function', function =>
    { name, description, parameters } } >>), and they reach the template
    as its C<tools> variable. Real HuggingFace templates guard the block
    with C<< {% if tools %} >>, and a template that never mentions
    C<tools> is unaffected by them — so this is passed B<only when
    non-empty>: a render with no tools is byte-for-byte the render this
    method produced before the parameter existed, whatever the template
    does with an empty list.

    B<Tool-call arguments reach the template as objects.> On the wire
    a tool call's C<function.arguments> is a JSON I<string>, and that
    is what C<Conversation::Message.to-hash> carries. Chat templates,
    written against what Python's C<transformers> passes them, expect
    a I<dict> there and iterate or index it. So arguments that parse
    as a JSON object are decoded before the render — matching
    transformers' semantics — while the message objects themselves,
    and therefore every request body built from them, keep the string
    untouched. Arguments that are not a JSON object (empty, a
    fragment cut short mid-stream, an array, a bare scalar, or a Hash
    a caller supplied directly) are passed through exactly as they
    are. See C<decoded-arguments>.

    B<Not for counting.> An L<LLM::Chat::TokenCounter> deliberately does
    not pass tools: the declarations are a per-request constant, and a
    counter calibrated against provider-reported usage has already been
    charged for them once. Adding them to a per-message or
    per-conversation count would bill them twice. Pass them here when the
    B<render itself> has to match what the server will see — a
    text-completion backend rendering the prompt by hand, or a fidelity
    check against a provider's own template. )
method render(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	Bool $continuation = False,
	:@tools,
	--> Str
) {
	my @hashes = @messages.map({ template-message-hash($_) });
	$!env.from-string($!template).render(
		messages => @hashes,
		bos_token => $!bos-token,
		eos_token => $!eos-token,
		add_generation_prompt => !$continuation,
		# ONLY when there is something to pass. `tools => []` is not the
		# same as no tools at all: a template asking `{% if tools %}` sees
		# an empty list as false either way, but one that asks
		# `{% if tools is defined %}` — or that indexes into it — would take
		# a different branch, and no caller asked for that by passing no
		# tools.
		|(@tools.elems ?? (tools => @tools.list) !! ()),
	);
}

method from-tokenizer-config(Str:D $json --> LLM::Chat::Template::Jinja2) {
	my $config = from-json($json);
	my $template;

	my $ct = $config<chat_template>;
	if $ct ~~ Str {
		$template = $ct;
	} elsif $ct ~~ Positional {
		# Array of {name, template} objects — use 'default' or first
		my $default = $ct.first({ $_<name> eq 'default' });
		$template = $default.defined ?? $default<template> !! $ct[0]<template>;
	} else {
		die "No chat_template found in tokenizer config";
	}

	my $bos = $config<bos_token> // '';
	$bos = $bos<content> if $bos ~~ Associative;
	my $eos = $config<eos_token> // '';
	$eos = $eos<content> if $eos ~~ Associative;

	self.new(:$template, :bos-token(~$bos), :eos-token(~$eos));
}
