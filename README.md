# LLM::Chat

## Introduction

`LLM::Chat` is a module for inferencing large language models.

It automatically manages pruning old messages, retaining the system prompt (`:sysprompt`) & other sticky (`:sticky`) messages, and inserting messages at depth (`:depth`).

## Example Usage

This is an implementation of a terminal-based conversational loop with LLM::Chat:

```raku
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
	my $resp   = $backend.chat-completion-stream(@prompt);

	my $last;
	loop {
		my $new = $resp.latest.subst(/^$last/, '');
		$last   = $resp.latest;

		print $new if $new ne "";
		last if $resp.is-done;
		sleep(0.1);
	}

	print "\n";

	print "ERROR: {$resp.err}\n" if !$resp.is-success;
}
```

See `examples/*` and `t/*` for more usage examples.

## Current Support

### Inference Types

- Chat completion (with or without streaming)
- Text completion (with or without streaming)

### API Types

- OpenAI compatible (most backends) - `LLM::Chat::Backend::OpenAICommon`
- KoboldCpp (additional samplers & cancel function) - `LLM::Chat::Backend::KoboldCpp`

To implement more API types, just extend `LLM::Chat::Backend`.

### Chat Templates

- ChatML (`LLM::Chat::Template::ChatML`)
- Gemma 2 (`LLM::Chat::Template::Gemma2`)
- Llama 3 (`LLM::Chat::Template::Llama3`)
- Llama 4 (`LLM::Chat::Template::Llama4`)
- Mistral V7 (`LLM::Chat::Template::MistralV7`)

To implement more chat templates, just extend `LLM::Chat::Template`. You will need a correct chat template for accurate context shifting and/or text completion.

## Planned

- Tool Calling
- VLM Capabilities
- More APIs & templates
- Automatically fetching tokenizers & chat template from HF model identifiers

## Contributing

Pull requests and issues welcome.

## License

Artistic License 2.0
(C) 2025 Matt Doughty `<matt@apogee.guru>`

The file at `t/fixtures/tokenizer.json` is (C) 2025 Mistral AI.

It is extracted from Mistral Nemo, which is an Apache 2.0 licensed model.
