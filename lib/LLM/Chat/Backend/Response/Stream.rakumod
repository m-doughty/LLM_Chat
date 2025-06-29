use LLM::Chat::Backend::Response;

unit class LLM::Chat::Backend::Response::Stream is LLM::Chat::Backend::Response;

has Str $.latest = "";

method latest {
	$!latest;
}

method _emit($e) {
	$!latest = $!latest ~ $e;
}

method _done {
	self._set-msg($!latest);
	nextsame;
}

