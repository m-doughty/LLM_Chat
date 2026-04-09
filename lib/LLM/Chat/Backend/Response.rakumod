unit class LLM::Chat::Backend::Response;

has Str      $.id        is required;
has Str      $.msg       = "";
has          $.err       = Nil;
has Bool     $.done      = False;
has Bool     $.success   = False;
has Bool     $.cancelled = False;
has          @.tool-calls;
has Str      $.finish-reason;
has Supplier $.supplier  is required;
has Tap      $.tap       is required;

submethod BUILD(:$id) {
	$!id       := $id;
	$!supplier := Supplier.new;

	$!tap = self.supply.tap(
		-> $e { self._emit($e) },
		done => -> { self._done },
		quit => -> $ex { self._quit($ex) },
	);
}

method is-done { 
	$!done;
}

method is-cancelled {
	$!cancelled;
}

method is-success {
	$!success;
}

method supply {
	$.supplier.Supply;
}

method _set-msg($msg) {
	$!msg = $msg;
}

method _set-tap($t) {
	$!tap = $t;
}

method _emit($e) {
	$!msg = $e;
}

method _set-tool-calls(@calls) {
	@!tool-calls = @calls;
}

method _set-finish-reason(Str $reason) {
	$!finish-reason = $reason;
}

method has-tool-calls(--> Bool:D) {
	@!tool-calls.elems > 0;
}

method _done {
	$!done    = True;
	$!success = True;
	$!tap.close;
}

method _quit($ex) {
	$!err       = $ex;
	$!done      = True;
	$!cancelled = True;
	$!tap.close;
}

method emit($e) { 
	$.supplier.emit($e);
}

method done {
	$.supplier.done;
}

method cancel {
	$.supplier.quit("Cancelled by user");
}

method quit($err) {
	$.supplier.quit($err);
}
