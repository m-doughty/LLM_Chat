=begin pod

=head1 NAME

LLM::Chat::ExceptionText - An exception's message, for any exception, without ever throwing

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Chat::ExceptionText;

class X::Quiet is Exception { }      # no message of its own

my $loud  = X::AdHoc.new(payload => 'disk full');
my $quiet = X::Quiet.new;

say exception-message($loud);        # disk full
say exception-message($quiet).raku;  # Str  (undefined: there is none)

say exception-text($loud);           # disk full
say exception-text($quiet);          # X::Quiet

$quiet.message;                      # dies: Stub code executed

=end code

=head1 DESCRIPTION

In Rakudo the base C<Exception.message> is a stub: its whole body is
C<...>, the yada operator. An exception class that defines neither a
C<message> method nor a C<$.message> attribute therefore has no message
to give. What C<.message> hands back is a C<Failure> whose exception
says "Stub code executed" (an C<X::StubCode> from Rakudo 2026.08 on, an
C<X::AdHoc> before), and that Failure B<throws> the moment anything
uses it as text: interpolates it, stringifies it, calls C<.lc> or
C<.lines> on it.

Such classes are not hypothetical. C<Cro::HTTP::Client> raises
C<Cro::HTTP::Client::PipelineClosedBeforeHeaders>, which has no message,
whenever a server closes the connection before sending response headers
— a server restarting, a proxy dropping an idle connection, a worker
killed mid-request. Any library can declare one; a test double often
does.

The place this bites is a C<CATCH> block. A handler that formats the
exception it caught with C<.message> throws a I<second> exception from
inside the handler, and that one is not caught by anything. In the main
program it replaces the original error with a stub error; inside a
C<start> block the program prints C<Unhandled exception in code
scheduled on thread N> and exits. The request that should have failed
takes the whole process with it.

=begin code :lang<raku>

start {
    my $res = await $client.post: $url, body => $body;
    # ...
    CATCH {
        default {
            # WRONG: dies again, from inside the handler, for any
            # exception without a message.
            $response.quit("{.^name}: {.message}");
        }
    }
}

=end code

C<.message // ''> happens to defuse the stub's Failure, but it is no
help against a C<message> method that dies outright, and an empty
string is a poor thing to report as an error.

These two subs read the message defensively, so the handler cannot fail:

=begin code :lang<raku>

use LLM::Chat::ExceptionText;

start {
    my $res = await $client.post: $url, body => $body;
    # ...
    CATCH {
        default {
            note "{.^name}: {exception-message($_) // '(no message)'}";
            $response.quit(exception-text($_));
        }
    }
}

=end code

Every C<.message> this distribution calls on an exception it did not
create goes through one of them, so a transport, hook or tool error
whose exception has no message fails the request it belongs to — with
the exception's class name as its error text — instead of the process.

=head1 WHICH ONE

=item B<C<exception-text>> when you need something to show: the error
handed to C<.quit>, the content of a failed tool result, a log line that
does not already name the class. It is never undefined, so it can go
straight into a C<Str:D>. An exception without a message is reported by
its class name, which is the most specific thing there is to say about
it.

=item B<C<exception-message>> when it matters whether there I<is> a
message: matching on the text, or choosing a fallback of your own. The
answer is an undefined C<Str> when there is none, which is exactly what
C<//> wants:

=begin code :lang<raku>

# Classify by the text, treating "no message" as "matches nothing".
my $text = (exception-message($_) // '').lc;
my $class = $text.contains('refused') ?? 'connection' !! 'unknown';

# A log line that already names the class should not name it twice.
note "{.^name}: {exception-message($_) // '(no message)'}";

=end code

=head1 WHAT COUNTS AS NO MESSAGE

C<exception-message> returns the message as a C<Str> when there is one,
and an undefined C<Str> when:

=item C<.message> returns an undefined value: C<Nil>, a type object, or
a C<Failure> — the last being what the base stub returns. A C<Failure>
is marked handled on the way, so it does not resurface later as an
"unhandled Failure" warning.

=item C<.message> dies. The exception it throws is caught and
discarded.

=item The message's own C<.Str> throws, is undefined, or is not a
C<Str>.

A defined message that is not a C<Str> is stringified (C<42> becomes
C<"42">). An empty string is a message, and is returned as one.

Anything can be passed, not only an C<Exception>: a value without a
C<message> method — a type object included — simply has no message.
Neither sub ever throws.

=head1 SUBROUTINES

=head2 exception-message

=begin code :lang<raku>

sub exception-message(Mu $exception --> Str) is export

=end code

The message of C<$exception> as a C<Str>, or an undefined C<Str> when it
has none (see L</WHAT COUNTS AS NO MESSAGE>).

=head2 exception-text

=begin code :lang<raku>

sub exception-text(Mu $exception --> Str:D) is export

=end code

The message when there is one, the class name otherwise. Always a
defined C<Str>.

The name is the I<declared> class, without roles mixed into the object
at runtime. That matters because C<await> rethrows every exception with
C<X::Await::Died> mixed in, so the exception a C<CATCH> around an
C<await> sees has a C<.^name> like
C<Cro::HTTP::Client::PipelineClosedBeforeHeaders+{X::Await::Died}>; its
text is C<Cro::HTTP::Client::PipelineClosedBeforeHeaders>.

=begin code :lang<raku>

class X::Quiet is Exception { }

my $p = Promise.new;
$p.break(X::Quiet.new);
try await $p;

say $!.^name;              # X::Quiet+{X::Await::Died}
say exception-text($!);    # X::Quiet

=end code

=end pod

unit module LLM::Chat::ExceptionText;

sub exception-message(Mu $exception --> Str) is export {
	my Str $text;
	{
		# A message method that dies, a .Str that dies, a value that will
		# not go into a Str: whatever goes wrong below means there is no
		# message to report.
		CATCH { default { $text = Str } }
		my Mu $message := $exception.message;
		# .defined, rather than a type check, so a Failure — which is what
		# the base Exception's stub returns — is marked handled here
		# instead of warning when it is collected.
		if $message.defined {
			my Mu $str := $message.Str;
			$text = $str if $str.defined;
		}
	}
	$text;
}

sub exception-text(Mu $exception --> Str:D) is export {
	exception-message($exception) // type-name($exception);
}

# The class name, for the exception-text fallback: the declared class,
# without roles mixed in at runtime. `await` rethrows every exception
# with X::Await::Died mixed in, and the error text should say
# Cro::HTTP::Client::PipelineClosedBeforeHeaders, not that name with
# "+{X::Await::Died}" on the end. A metaobject that cannot answer is
# not a reason to throw from an error path: the plain name stands in
# for the declared one, and 'Exception' for both.
my sub type-name(Mu $exception --> Str:D) {
	my Str $plain;
	my Str $declared;
	{
		CATCH { default { } }
		my Mu $name := $exception.^name;
		$plain = $name if $name.defined;
		my Mu $base := $exception.^mixin_base.^name;
		$declared = $base if $base.defined;
	}
	return $declared if $declared.defined && $declared.chars;
	return $plain if $plain.defined && $plain.chars;
	'Exception';
}
