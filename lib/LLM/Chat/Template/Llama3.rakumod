use LLM::Chat::Conversation::Message;
use LLM::Chat::Template;

unit class LLM::Chat::Template::Llama3 is LLM::Chat::Template;

method name { 'llama-3' }

method render(@messages, $continuation = False, --> Str) {
    my $out = "";

    my $postfix = "";
    $postfix = @messages.pop if $continuation;

    for @messages -> $msg {
        $out ~= "<|start_header_id|>{$msg.role}<|end_header_id|>\n";
        $out ~= "{$msg.content}<|eot_id|>\n";
    }

    if $continuation {
        $out ~= "<|start_header_id|>assistant<|end_header_id|>\n";
        $out ~= $postfix.content;
    }

    return $out;
}

