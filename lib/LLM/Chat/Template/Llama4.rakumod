use LLM::Chat::Conversation::Message;
use LLM::Chat::Template;

unit class LLM::Chat::Template::Llama4 is LLM::Chat::Template;

method name { 'llama-4' }

method render(@messages, $continuation = False, --> Str) {
    my $out = "<|begin_of_text|>\n";

    my $postfix = "";
    $postfix = @messages.pop if $continuation;

    for @messages -> $msg {
        $out ~= "<|header_start|>{$msg.role}<|header_end|>\n";
        $out ~= "{$msg.content}<|eot|>\n";
    }

    if $continuation {
        $out ~= "<|header_start|>assistant<|header_end|>\n";
        $out ~= $postfix.content;
    }

    return $out;
}

