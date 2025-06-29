#!/usr/bin/env raku

use lib 'lib';

use LLM::Chat::Backend::OpenAICommon;
use LLM::Chat::Backend::Settings;
use LLM::Chat::Conversation;
use LLM::Chat::Conversation::Message;
use LLM::Chat::Template::MistralV7;
use LLM::Chat::TokenCounter;
use Tokenizers;

## EDIT THESE TO MATCH YOUR ENVIRONMENT
constant $API_URL     = 'http://192.168.1.193:5001/v1';
constant $MAX_TOKENS  = 1024;
constant $MAX_CONTEXT = 32768;

my @conversation = (
	LLM::Chat::Conversation::Message.new(
		role      => 'system',
		content   => 'You are a helpful assistant.',
		sysprompt => True
	);
);

my $template      = LLM::Chat::Template::MistralV7.new;
my $tokenizer     = Tokenizers.new-from-json(
	slurp('t/fixtures/tokenizer.json')
);
my $token-counter = LLM::Chat::TokenCounter.new(
	tokenizer => $tokenizer,
	template  => $template,
);

my $settings = LLM::Chat::Backend::Settings.new(
	max_tokens => $MAX_TOKENS,
	max_context => $MAX_CONTEXT,
);

my $con = LLM::Chat::Conversation.new(
	token-counter  => $token-counter,
	context-budget => $MAX_CONTEXT - $MAX_TOKENS,
);

my $backend = LLM::Chat::Backend::OpenAICommon.new(
	api_url  => $API_URL,
	settings => $settings,
	template => $template,
);

loop {
	my @lines;
	say "Enter your input. Type 'DONE' on a line by itself when finished:\n";

	loop {
		print "> ";
		my $line = $*IN.get // last;
		last if $line.trim eq 'DONE';
		@lines.push: $line;
	}

	last if @lines.elems == 0;
	@conversation.push: LLM::Chat::Conversation::Message.new(
		role    => 'user',
		content => @lines.join("\n"),
	);
	my @prompt = $con.prepare-for-inference(@conversation);
	my $resp   = $backend.text-completion(@prompt);

	while (!$resp.is-done) {
		sleep(0.1);
	}

	if $resp.is-success {
		print "{$resp.msg}\n";
		@conversation.push: LLM::Chat::Conversation::Message.new(
			role    => 'assistant',
			content => $resp.msg,
		);
	}
	print "ERROR: {$resp.err}\n" if !$resp.is-success;
}
