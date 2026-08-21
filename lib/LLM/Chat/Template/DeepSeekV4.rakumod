use JSON::Fast;
use LLM::Chat::Conversation::Message;
use LLM::Chat::Template;

unit class LLM::Chat::Template::DeepSeekV4 is LLM::Chat::Template;

our class Invalid is Exception {
	has Str $.detail is required;
	method message { $!detail }
}

sub invalid(Str:D $detail --> Nil) {
	LLM::Chat::Template::DeepSeekV4::Invalid.new(:$detail).throw
}

# Hash iteration in Raku is intentionally unordered.  This small private map
# retains the caller's observed pair order while preprocessing cloned messages;
# JSON embedded in a DSV4 prompt is therefore stable and Python-compatible.
my class OrderedObject does Associative {
	has @.storage;
	method AT-KEY($key) is rw {
		my $index = @!storage.first({ .key eq $key }, :k);
		return-rw @!storage[$index].value if $index.defined;
		my $value;
		@!storage.push($key => $value);
		return-rw @!storage[*-1].value;
	}
	method EXISTS-KEY($key --> Bool) { so @!storage.first({ .key eq $key }) }
	method DELETE-KEY($key) {
		my $index = @!storage.first({ .key eq $key }, :k);
		$index.defined ?? @!storage.splice($index, 1)[0].value !! Nil
	}
	method pairs { @!storage.Seq }
	method keys { @!storage.map(*.key).Seq }
	method values { @!storage.map(*.value).Seq }
	method elems { @!storage.elems }
}

# JSON::Fast normalizes a parsed -0.0 to positive zero. Python's json module
# retains the float sign and emits -0.0, which is prompt-visible in DSML.
my class NegativeZero { }

# Used by the golden oracle and by callers that already possess a JSON wire
# payload.  JSON::Fast correctly parses values but materializes objects as
# unordered Hashes; this parser retains object member order as Python does.
my class OrderedJSONParser {
	has Str $.source is required;
	has Int $!pos = 0;

	method parse {
		my $value = self!value;
		self!ws;
		invalid("Trailing JSON data at character $!pos") unless $!pos == $!source.chars;
		$value
	}
	method !ws { $!pos++ while $!pos < $!source.chars && $!source.substr($!pos, 1) ~~ /\s/ }
	method !value {
		self!ws;
		invalid('Unexpected end of JSON') if $!pos >= $!source.chars;
		given $!source.substr($!pos, 1) {
			when '{' { self!object }
			when '[' { self!array }
			when '"' { self!string }
			default { self!scalar }
		}
	}
	method !string {
		my $start = $!pos++;
		my $escaped = False;
		while $!pos < $!source.chars {
			my $char = $!source.substr($!pos++, 1);
			if $escaped { $escaped = False; next }
			if $char eq '\\' { $escaped = True; next }
			if $char eq '"' {
				return from-json($!source.substr($start, $!pos - $start));
			}
		}
		invalid("Unterminated JSON string at character $start")
	}
	method !scalar {
		my $start = $!pos;
		$!pos++ while $!pos < $!source.chars && $!source.substr($!pos, 1) ne any(',', ']', '}') && $!source.substr($!pos, 1) !~~ /\s/;
		my $raw = $!source.substr($start, $!pos - $start);
		if $raw.starts-with('-') && ($raw.contains('.') || $raw.lc.contains('e')) {
			my $mantissa = $raw.substr(1).split(/<[eE]>/)[0];
			return NegativeZero.new if $mantissa.trans('.' => '') ~~ /^ 0+ $/;
		}
		my $value;
		try {
			CATCH { default { invalid("Invalid JSON scalar `$raw`") } }
			$value = from-json($raw);
		}
		$value
	}
	method !object {
		$!pos++;
		my @pairs;
		self!ws;
		if $!source.substr($!pos, 1) eq '}' { $!pos++; return OrderedObject.new(storage => []) }
		loop {
			self!ws;
			invalid("Expected JSON object key at character $!pos") unless $!source.substr($!pos, 1) eq '"';
			my $key = self!string;
			self!ws;
			invalid("Expected ':' at character $!pos") unless $!source.substr($!pos, 1) eq ':';
			$!pos++;
			my $value = self!value;
			my $existing = @pairs.first({ .key eq $key }, :k);
			if $existing.defined {
				@pairs[$existing] = $key => $value;
			} else {
				@pairs.push($key => $value);
			}
			self!ws;
			my $delimiter = $!source.substr($!pos++, 1);
			last if $delimiter eq '}';
			invalid("Expected ',' or '}' at character {$!pos - 1}") unless $delimiter eq ',';
		}
		OrderedObject.new(storage => @pairs)
	}
	method !array {
		$!pos++;
		my @items;
		self!ws;
		if $!source.substr($!pos, 1) eq ']' { $!pos++; return @items }
		loop {
			@items.push(self!value);
			self!ws;
			my $delimiter = $!source.substr($!pos++, 1);
			last if $delimiter eq ']';
			invalid("Expected ',' or ']' at character {$!pos - 1}") unless $delimiter eq ',';
		}
		@items
	}
}

# Prompt encoder ported from DeepSeek's MIT-licensed reference implementation:
# deepseek-ai/DeepSeek-V4-Flash-0731, commit
# 7872f01b1d1fe23eabc4c98b48bffcef5a386062, encoding/encoding_dsv4.py.
# Copyright (c) 2023 DeepSeek. See t/fixtures/deepseek-v4/LICENSE.

my constant BOS = '<｜begin▁of▁sentence｜>';
my constant EOS = '<｜end▁of▁sentence｜>';
my constant THINK-START = '<think>';
my constant THINK-END = '</think>';
my constant DSML = '｜DSML｜';
my constant USER = '<｜User｜>';
my constant ASSISTANT = '<｜Assistant｜>';
my constant LATEST-REMINDER = '<｜latest_reminder｜>';

my constant %TASK-TOKENS =
	action    => '<｜action｜>',
	query     => '<｜query｜>',
	authority => '<｜authority｜>',
	domain    => '<｜domain｜>',
	title     => '<｜title｜>',
	read_url  => '<｜read_url｜>';

my constant %EFFORT-PROMPTS =
	low => '',
	high => "Reasoning Effort: Absolute maximum with no shortcuts permitted.\nYou MUST be very thorough in your thinking and comprehensively decompose the problem to resolve the root cause, rigorously stress-testing your logic against all potential paths, edge cases, and adversarial scenarios.\nExplicitly write out your entire deliberation process, documenting every intermediate step, considered alternative, and rejected hypothesis to ensure absolutely no assumption is left unchecked.\n\n",
	max => "Reasoning Effort: Beyond maximum — exhaustive, relentless, and uncompromising.\nYou MUST reason with the utmost depth and rigor, leaving absolutely nothing to chance: exhaustively decompose the problem into its most fundamental components, trace every causal chain to its root, and resolve the underlying cause rather than any surface symptom.\nDo not stop reasoning until you have independently verified the solution from multiple angles and are certain that no assumption remains unchecked and no error remains undiscovered.\n\n";

has Str $.thinking-mode where * eq 'chat' | 'thinking' = 'chat';
has Bool $.drop-thinking = True;
has Bool $.add-default-bos-token = True;
has Str $.reasoning-effort where * eq 'low' | 'high' | 'max' = 'low';

method name(--> Str) { 'deepseek-v4' }

# JSON::Fast's compact form lacks the spaces used by Python json.dumps.  DSV4
# places JSON literally in the prompt, so reproduce Python's default separators.
sub py-json(Mu $value --> Str) {
	return 'null' unless $value.defined;
	return '-0.0' if $value ~~ NegativeZero;
	return $value ?? 'true' !! 'false' if $value ~~ Bool;
	if $value ~~ Numeric {
		my $json = to-json($value, :!pretty);
		# JSON::Fast writes every Num with a terminal e0. Python writes an
		# integral float with `.0`, and an ordinary fractional float without
		# an exponent. Rats already retain whether the JSON spelling was 1.0.
		if $value ~~ Num && $json.ends-with('e0') {
			$json = $json.substr(0, *-2);
			$json ~= '.0' unless $json.contains('.');
		}
		return $json;
	}
	return to-json(~$value, :!pretty) if $value ~~ Str;
	if $value ~~ Associative {
		return '{' ~ $value.pairs.map({ py-json(~.key) ~ ': ' ~ py-json(.value) }).join(', ') ~ '}';
	}
	if $value ~~ Positional {
		return '[' ~ $value.list.map({ py-json($_) }).join(', ') ~ ']';
	}
	to-json($value, :!pretty)
}

sub clone-value(Mu $value) {
	return $value.map({ clone-value($_) }).Array if $value ~~ Positional;
	return OrderedObject.new(storage => $value.pairs.map({ .key => clone-value(.value) }).Array) if $value ~~ Associative;
	$value
}

sub openai-tools(Positional $tools --> Array) {
	$tools.map({ $_<function> }).Array
}

sub openai-tool-calls(Positional $calls --> Array) {
	my @result;
	for $calls.list -> $call {
		@result.push(OrderedObject.new(storage => [name => $call<function><name>, arguments => $call<function><arguments>]));
	}
	@result
}

sub encode-arguments(Associative $call --> Str) {
	my $arguments;
	my $parsed = True;
	try {
		CATCH { default { $parsed = False } }
		$arguments = OrderedJSONParser.new(source => ($call<arguments> // '')).parse;
	}
	$arguments = { arguments => ($call<arguments> // '') } unless $parsed;
	invalid('Tool-call arguments must decode to a JSON object') unless $arguments ~~ Associative;
	$arguments.pairs.map(-> $pair {
		my $value = $pair.value ~~ Str ?? $pair.value !! py-json($pair.value);
		my $is-string = $pair.value ~~ Str ?? 'true' !! 'false';
		'<' ~ DSML ~ 'parameter name="' ~ $pair.key ~ '" string="' ~ $is-string ~ '">' ~
			$value ~ '</' ~ DSML ~ 'parameter>'
	}).join("\n")
}

sub render-tools(Positional $tools --> Str) {
	my $schemas = $tools.map({ py-json($_) }).join("\n");
	qq:to/TOOLS/
## Tools

You have access to a set of tools to help answer the user's question. You can invoke tools by writing a "<{DSML}tool_calls>" block like the following:

<{DSML}tool_calls>
<{DSML}invoke name="\$TOOL_NAME">
<{DSML}parameter name="\$PARAMETER_NAME" string="true|false">\$PARAMETER_VALUE</{DSML}parameter>
...
</{DSML}invoke>
<{DSML}invoke name="\$TOOL_NAME2">
...
</{DSML}invoke>
</{DSML}tool_calls>

String parameters should be specified as is and set `string="true"`. For all other types (numbers, booleans, arrays, objects), pass the value in JSON format and set `string="false"`.

If thinking_mode is enabled (triggered by {THINK-START}), you MUST output your complete reasoning inside {THINK-START}...{THINK-END} BEFORE any tool calls or final response.

Otherwise, output directly after {THINK-END} with tool calls or final response.

### Available Tool Schemas

$schemas

You MUST strictly follow the above defined tool name and parameter schemas to invoke tool calls.
TOOLS
}

sub last-user-index(Positional $messages --> Int) {
	for reverse ^$messages.elems -> $index {
		return $index if ($messages[$index]<role> // '') eq 'user' | 'developer';
	}
	-1
}

sub merge-tool-messages(Positional $messages --> Array) {
	my @merged;
	for $messages.list -> $original {
		my $message = clone-value($original);
		given $message<role> // '' {
			when 'tool' {
				my $block = OrderedObject.new(storage => [type => 'tool_result', tool_use_id => ($message<tool_call_id> // ''), content => ($message<content> // '')]);
				if @merged && @merged[*-1]<role> eq 'user' && (@merged[*-1]<content_blocks>:exists) {
					@merged[*-1]<content_blocks>.push($block);
				} else {
					@merged.push(OrderedObject.new(storage => [role => 'user', content_blocks => [$block]]));
				}
			}
			when 'user' {
				my $block = OrderedObject.new(storage => [type => 'text', text => ($message<content> // '')]);
				if @merged && @merged[*-1]<role> eq 'user' && (@merged[*-1]<content_blocks>:exists) && !@merged[*-1]<task>.defined {
					@merged[*-1]<content_blocks>.push($block);
				} else {
					my $new = OrderedObject.new(storage => [role => 'user', content => ($message<content> // ''), content_blocks => [$block]]);
					for <task wo_eos mask> -> $key { $new{$key} = $message{$key} if $message{$key}:exists }
					@merged.push($new);
				}
			}
			default { @merged.push($message) }
		}
	}
	@merged
}

sub sort-tool-results(Positional $messages --> Array) {
	my @result = clone-value($messages);
	my %call-order;
	for @result -> $message {
		if $message<role> eq 'assistant' && $message<tool_calls> {
			%call-order = ();
			for $message<tool_calls>.list.kv -> $index, $call {
				my $id = $call<id> // $call<function><id> // '';
				%call-order{$id} = $index if $id;
			}
		} elsif $message<role> eq 'user' && $message<content_blocks> {
			my @blocks := $message<content_blocks>;
			my @tools = @blocks.grep({ ($_<type> // '') eq 'tool_result' });
			if @tools.elems > 1 && %call-order {
				@tools = @tools.sort({ (%call-order{$^a<tool_use_id> // ''} // 0) <=> (%call-order{$^b<tool_use_id> // ''} // 0) });
				my $next = 0;
				@blocks = @blocks.map({ ($_<type> // '') eq 'tool_result' ?? @tools[$next++] !! $_ });
			}
		}
	}
	@result
}

sub drop-thinking-messages(Positional $messages --> Array) {
	my $last-user = last-user-index($messages);
	my @result;
	for $messages.list.kv -> $index, $original {
		my $message = clone-value($original);
		my $role = $message<role> // '';
		if $role eq any(<user system tool latest_reminder direct_search_results>) || $index >= $last-user {
			@result.push($message);
		} elsif $role eq 'assistant' {
			$message<reasoning_content>:delete;
			@result.push($message);
		}
	}
	@result
}

sub render-message(Int $index, Positional $messages, Str $thinking-mode, Bool $drop-thinking, Str $effort --> Str) {
	invalid("Invalid thinking_mode `$thinking-mode`") unless $thinking-mode eq 'chat' | 'thinking';
	invalid("Invalid reasoning effort: $effort") unless %EFFORT-PROMPTS{$effort}:exists;
	my $message := $messages[$index];
	my $role = $message<role> // '';
	my $prompt = $index == 0 && $thinking-mode eq 'thinking' ?? %EFFORT-PROMPTS{$effort} !! '';
	my $last-user = last-user-index($messages);
	my @tools = $message<tools> ?? openai-tools($message<tools>) !! [];
	my @calls = $message<tool_calls> ?? openai-tool-calls($message<tool_calls>) !! [];

	given $role {
		when 'system' {
			$prompt ~= $message<content> // '';
			$prompt ~= "\n\n" ~ render-tools(@tools) if @tools;
			$prompt ~= "\n\n## Response Format:\n\nYou MUST strictly adhere to the following schema to reply:\n" ~ py-json($message<response_format>) if $message<response_format>;
		}
		when 'developer' {
			invalid('Invalid message for role `developer`') unless $message<content>;
			$prompt ~= USER ~ $message<content>;
			$prompt ~= "\n\n" ~ render-tools(@tools) if @tools;
			$prompt ~= "\n\n## Response Format:\n\nYou MUST strictly adhere to the following schema to reply:\n" ~ py-json($message<response_format>) if $message<response_format>;
		}
		when 'user' {
			$prompt ~= USER;
			if $message<content_blocks> {
				my @parts = $message<content_blocks>.map(-> $block {
					given $block<type> // '' {
						when 'text' { $block<text> // '' }
						when 'tool_result' {
							my $content = $block<content> // '';
							if $content ~~ Positional {
								$content = $content.map({ ($_<type> // '') eq 'text' ?? ($_<text> // '') !! "[Unsupported {$_<type>}]" }).join("\n\n");
							}
							'<tool_result>' ~ $content ~ '</tool_result>'
						}
						default { "[Unsupported {$block<type>}]" }
					}
				});
				$prompt ~= @parts.join("\n\n");
			} else { $prompt ~= $message<content> // '' }
		}
		when 'latest_reminder' { $prompt ~= LATEST-REMINDER ~ ($message<content>.defined ?? $message<content> !! 'None') }
		when 'tool' { invalid('deepseek_v4 merges tool messages into user; preprocess with merge-tool-messages') }
		when 'assistant' {
			my $tool-content = '';
			if @calls {
				my @encoded = @calls.map({ "<{DSML}invoke name=\"{$_<name>}\">\n{encode-arguments($_)}\n</{DSML}invoke>" });
				$tool-content = "\n\n<{DSML}tool_calls>\n" ~ @encoded.join("\n") ~ "\n</{DSML}tool_calls>";
			}
			my $previous-has-task = $index > 0 && $messages[$index - 1]<task>.defined;
			my $thinking = '';
			if $thinking-mode eq 'thinking' && !$previous-has-task && (!$drop-thinking || $index > $last-user) {
				$thinking = ($message<reasoning_content> // '') ~ THINK-END;
			}
			$prompt ~= $thinking ~ ($message<content> // '') ~ $tool-content;
			$prompt ~= EOS unless $message<wo_eos> // False;
		}
		default { invalid("Unknown role: $role") }
	}

	return $prompt if $index + 1 < $messages.elems && $messages[$index + 1]<role> ne any(<assistant latest_reminder>);
	if $message<task>.defined {
		my $task = $message<task>;
		invalid("Invalid task: '$task'") unless %TASK-TOKENS{$task}:exists;
		if $task eq 'action' {
			$prompt ~= ASSISTANT ~ ($thinking-mode eq 'thinking' ?? THINK-START !! THINK-END) ~ %TASK-TOKENS{$task};
		} else { $prompt ~= %TASK-TOKENS{$task} }
	} elsif $role eq 'user' | 'developer' {
		$prompt ~= ASSISTANT;
		$prompt ~= $thinking-mode eq 'thinking' && (!$drop-thinking || $index >= $last-user) ?? THINK-START !! THINK-END;
	}
	$prompt
}

method encode-messages(
	Positional:D $messages,
	Str:D :$thinking-mode! where * eq 'chat' | 'thinking',
	Positional :$context = [],
	Bool :$drop-thinking = True,
	Bool :$add-default-bos-token = True,
	Str :$reasoning-effort where * eq 'low' | 'high' | 'max' = 'low',
	--> Str
) {
	for $messages.list.kv -> $index, $message {
		invalid("Messages[$index] must be an associative message object")
			unless $message ~~ Associative;
	}
	for $context.list.kv -> $index, $message {
		invalid("Context[$index] must be an associative message object")
			unless $message ~~ Associative;
	}

	my @raw-context = $context ?? clone-value($context) !! [];
	my @messages = merge-tool-messages($messages);
	@messages = sort-tool-results([|@raw-context, |@messages]).skip(@raw-context.elems).Array;
	my @context = @raw-context ?? sort-tool-results(merge-tool-messages(@raw-context)) !! [];
	my @full = |@context, |@messages;
	my $prompt = $add-default-bos-token && !@context ?? BOS !! '';
	my $effective-drop = $drop-thinking && !@full.first({ $_<tools> });
	my $context-length = @context.elems;
	my $render-count = @messages.elems;
	if $thinking-mode eq 'thinking' && $effective-drop {
		@full = drop-thinking-messages(@full);
		my @dropped-context = drop-thinking-messages(@context);
		$render-count = @full.elems - @dropped-context.elems;
		$context-length = @full.elems - $render-count;
	}
	for ^$render-count -> $offset {
		$prompt ~= render-message($offset + $context-length, @full, $thinking-mode, $effective-drop, $reasoning-effort);
	}
	$prompt
}

method encode-json(
	Str:D $messages-json,
	Str:D :$thinking-mode! where * eq 'chat' | 'thinking',
	Str :$context-json,
	Bool :$drop-thinking = True,
	Bool :$add-default-bos-token = True,
	Str :$reasoning-effort where * eq 'low' | 'high' | 'max' = 'low',
	--> Str
) {
	my $messages = OrderedJSONParser.new(source => $messages-json).parse;
	invalid('Messages JSON must contain an array') unless $messages ~~ Positional;
	my $context = $context-json.defined ?? OrderedJSONParser.new(source => $context-json).parse !! [];
	invalid('Context JSON must contain an array') unless $context ~~ Positional;
	self.encode-messages($messages, :$thinking-mode, :$context, :$drop-thinking, :$add-default-bos-token, :$reasoning-effort)
}

method render(
	@messages where all(@messages) ~~ LLM::Chat::Conversation::Message,
	Bool $continuation = False,
	:@tools,
	Str :$thinking-mode = $!thinking-mode,
	Bool :$drop-thinking = $!drop-thinking,
	Bool :$add-default-bos-token = $!add-default-bos-token,
	Str :$reasoning-effort = $!reasoning-effort,
	*%options,
	--> Str
) {
	my @hashes = @messages.map({ clone-value(.to-hash) });
	if @tools {
		my $target = @hashes.first({ $_<role> eq 'system' | 'developer' });
		if $target.defined {
			$target<tools> = clone-value(@tools);
		} else {
			@hashes.unshift(OrderedObject.new(storage => [
				role => 'system', content => '', tools => clone-value(@tools),
			]));
		}
	}
	my $prompt = self.encode-messages(@hashes, :$thinking-mode, :$drop-thinking, :$add-default-bos-token, :$reasoning-effort);
	if $continuation && @hashes && @hashes[*-1]<role> eq any(<user developer>) {
		my $suffix = ASSISTANT ~ ($thinking-mode eq 'thinking' ?? THINK-START !! THINK-END);
		$prompt = $prompt.substr(0, *-$suffix.chars) if $prompt.ends-with($suffix);
	}
	$prompt
}
