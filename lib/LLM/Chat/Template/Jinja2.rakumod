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

method render(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	Bool $continuation = False,
	--> Str
) {
	my @hashes = @messages.map(*.to-hash);
	$!env.from-string($!template).render(
		messages => @hashes,
		bos_token => $!bos-token,
		eos_token => $!eos-token,
		add_generation_prompt => !$continuation,
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
