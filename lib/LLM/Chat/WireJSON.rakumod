=begin pod

=head1 NAME

LLM::Chat::WireJSON - Deterministic JSON for request bodies, with schema property order under the caller's control

=head1 SYNOPSIS

=begin code :lang<raku>

use LLM::Chat::WireJSON;

my %schema =
    type       => 'object',
    properties => %(
        change     => %( type => 'string' ),
        confidence => %( type => 'number' ),
        evidence   => %( type => 'string' ),
        notes      => %( type => 'string' ),
    ),
    # Generation order: evidence first, then the change it supports.
    required   => [ 'evidence', 'change', 'confidence' ];

say to-wire-json(%schema);
# {"properties":{"evidence":{"type":"string"},"change":{"type":"string"},
#  "confidence":{"type":"number"},"notes":{"type":"string"}},
#  "required":["evidence","change","confidence"],"type":"object"}
# (one line on the wire; wrapped here for reading)

# Same input, same bytes: in this process, in the next one, on every
# machine.
say to-wire-json(%schema) eq to-wire-json(%schema.clone);   # True

# Plain data: sorted members everywhere, no schema rule.
say to-wire-json(%( b => 1, a => %( properties => %( z => 1, y => 2 ),
                                     required   => ['z'] ) ),
                 :!schema-order);
# {"a":{"properties":{"y":2,"z":1},"required":["z"]},"b":1}

=end code

=head1 DESCRIPTION

Raku hashes have no member order, and their iteration order is
deliberately unpredictable: it differs between two hashes holding the
same keys, and between two runs of the same program. A request body
serialized straight from a C<Hash> — which is what handing a C<Hash> to
C<Cro::HTTP::Client> does — therefore goes on the wire with its members
in a different order every time.

For most of a request that is cosmetic. For a JSON Schema it is not.
llama.cpp and KoboldCpp compile a C<json_schema> / C<response_format>
schema into a sampling grammar, and that grammar makes the model write
an object's fields B<in the order the schema lists them>. A schema
serialized from a C<Hash> makes the model write its fields in a random
order per request, so an application cannot decide, for instance, that
the model states its evidence I<before> the conclusion that evidence
supports. Random prompt bytes also defeat prompt-prefix caching and
make a logged request impossible to replay exactly.

C<to-wire-json> is the serializer every L<LLM::Chat::Backend::OpenAICommon>
request body (and so every L<LLM::Chat::Backend::OpenRouter> and
L<LLM::Chat::Backend::KoboldCpp> body) goes through. It is exported for
applications that build prompt text or schemas themselves and want the
same guarantees.

=head1 THE ORDERING RULE

=item B<Arrays keep their order.>

=item B<Object members are sorted> in ascending order of their names by
Unicode code point — the same order as comparing the names' UTF-8 bytes.
For ASCII names that is digits, then uppercase, then C<_>, then
lowercase.

=item B<Except a schema's property map.> An object member named
C<properties> whose value is an object is a JSON Schema property map.
Its members are emitted in the order of the B<sibling> C<required>
array (the C<required> member of the same object), then every property
C<required> does not name, in ascending order. C<required> entries that
are not strings, name no property in the map, or repeat an earlier
entry are skipped. With no C<required> — or one that is not an array —
the whole map is sorted.

=item B<At any depth.> The rule applies wherever a property map occurs:
nested object properties, C<items>, C<prefixItems>, C<$defs> /
C<definitions> entries, C<anyOf> / C<oneOf> / C<allOf> branches,
C<additionalProperties>, tool C<parameters>, the schema inside
C<response_format>, KoboldCpp's C<json_schema> — nothing needs to be
registered for a new location.

=item B<Names are not keywords.> Inside a property map, and inside the
name-to-schema maps C<$defs>, C<definitions>, C<patternProperties> and
C<dependentSchemas>, member names are names chosen by the schema
author. A property called C<properties>, C<required>, C<enum> or
C<$defs> is an ordinary property; its value is read as a schema like
any other.

=item B<Data is never reordered as if it were schema.> The values of the
data keywords C<const>, C<default>, C<enum> and C<examples>, and the
values of any member listed in C<:$data-members> (the backends list the
request's C<messages>), are emitted with every object sorted, at every
depth, and are never searched for property maps. C<:!schema-order>
applies the same treatment to the whole value.

The upshot for a schema author: B<list C<required> in the order you
want the model to write the fields>. Optional fields follow, in
alphabetical order.

=begin code :lang<raku>

my %finding =
    type       => 'object',
    properties => %(
        verdict  => %( type => 'string', enum => <keep drop> ),
        quote    => %( type => 'string' ),
        reason   => %( type => 'string' ),
        severity => %( type => 'integer' ),
    ),
    required   => <quote reason verdict>;

# properties go out as quote, reason, verdict (required order), then
# severity (optional, sorted) — so a grammar-constrained model writes
# the quote first and decides the verdict last.
say to-wire-json(%finding);

=end code

The same schema nested anywhere keeps its own order:

=begin code :lang<raku>

my %report =
    type       => 'object',
    properties => %(
        findings => %( type => 'array', items => %finding ),
        summary  => %( type => 'string' ),
    ),
    required   => <findings summary>;

say to-wire-json(%report);   # %finding's map keeps quote, reason, verdict, severity

=end code

=head1 BYTES

=item B<Deterministic.> The same value serializes to the same bytes in
every process, whatever order its hashes were built in and whatever
hash seed the VM picked.

=item B<Semantically unchanged.> Parsing the output yields the same
data as parsing C<JSON::Fast>'s C<to-json> output for the same value:
only member order differs. Numbers, booleans, C<null>, enums, allomorphs
(C<IntStr> and friends), dates and every other non-string scalar are
written by C<JSON::Fast> itself, exactly as before. An undefined value
(type object, C<Nil>, C<Failure>) is C<null>.

=item B<Compact.> No whitespace between tokens.

=item B<Linear.> Every node is visited once and each string is escaped
in a single pass, so a request of several hundred kilobytes costs
milliseconds. (C<JSON::Fast> escapes by splicing, which is quadratic in
the number of characters that need escaping; a long transcript full of
newlines and quotes is exactly that case.)

=item B<Strings> are written as UTF-8 with the mandatory escapes only:
C<\"> C<\\> C<\n> C<\r> C<\t>, and C<\u00XX> for the remaining control
characters. Everything else, including characters outside the Basic
Multilingual Plane, is written as itself.

=item B<Combining marks after an escape are escaped too.> A combining
mark that directly follows an escape sequence would otherwise join the
escape's final letter when the text is normalized or encoded — C<\n>
followed by U+0301 becomes C<\ń>, which is not valid JSON. Such marks
(any code point with a non-zero canonical combining class) are written
as C<\uXXXX>, so the returned C<Str> encodes to valid JSON however it
is handled afterwards.

=head1 SUBROUTINES

=head2 to-wire-json

=begin code :lang<raku>

sub to-wire-json(
    Mu \value,
    :$data-members,
    Bool :$schema-order = True,
    --> Str:D
) is export

=end code

Serialize C<value> as compact, deterministic JSON following the rule
above. Encode the result with C<.encode('utf-8')> to get wire bytes.

=item C<:$data-members> — a name, or a list of names, of top-level
members of C<value> (when it is an object) whose values are data rather
than schema: emitted with sorted members at every depth, never searched
for property maps. Nested members of the same name are unaffected. The
backends pass C<< <messages> >>, so a conversation that happens to hold
an object with a C<properties> member is serialized as plain data:

=begin code :lang<raku>

my %body =
    messages => [ %( role => 'user', content => 'hi' ), ],
    tools    => @tool-definitions;

to-wire-json(%body, :data-members<messages>);
to-wire-json(%body, :data-members(<messages metadata>));

=end code

=item C<:$schema-order> — defaults to C<True>. C<False> treats the whole
value as data: every object sorted, no property-map rule.

Dies, like C<JSON::Fast>'s C<to-json>, on a value JSON cannot express
(a C<Supply>, say).

=end pod

use JSON::Fast;
use nqp;

unit module LLM::Chat::WireJSON;

# Serialization modes. SCHEMA reads property maps and name-to-schema
# maps by their keyword; DATA sorts every object and nothing else.
my constant SCHEMA = 0;
my constant DATA   = 1;

# Keywords whose value maps author-chosen names to subschemas.
my constant NAME-MAP-KEYWORDS = set <$defs definitions patternProperties dependentSchemas>;

# Keywords whose value is instance data, not schema.
my constant DATA-KEYWORDS = set <const default enum examples>;

sub to-wire-json(
	Mu \value,
	:$data-members,
	Bool :$schema-order = True,
	--> Str:D
) is export {
	my str @out;
	my int $mode = $schema-order ?? SCHEMA !! DATA;
	my @members = $data-members.defined ?? $data-members.list !! ();
	if $mode == SCHEMA && @members.elems && value.defined && value ~~ Associative {
		emit-object(@out, value, $mode, @members.map(*.Str).Set);
	}
	else {
		emit(@out, value, $mode);
	}
	@out.join;
}

my sub emit(str @out, Mu \value, int $mode --> Nil) {
	if !value.defined {
		@out.push('null');
	}
	elsif value ~~ Enumeration || value ~~ Allomorph {
		# Bool, enums and IntStr & co are written exactly as JSON::Fast
		# writes them (an enum by name, an allomorph as its number).
		@out.push(to-json(value, :!pretty));
	}
	elsif value ~~ Str {
		@out.push(quote(value));
	}
	elsif value ~~ Seq {
		emit-array(@out, value.cache, $mode);
	}
	elsif value ~~ Associative {
		emit-object(@out, value, $mode, Set);
	}
	elsif value ~~ Positional {
		emit-array(@out, value, $mode);
	}
	else {
		# Numbers, dates, versions — and the exception for anything JSON
		# cannot express — come from JSON::Fast, unchanged.
		@out.push(to-json(value, :!pretty));
	}
}

my sub emit-array(str @out, \array, int $mode --> Nil) {
	@out.push('[');
	my Bool $first = True;
	for array.list -> \item {
		@out.push(',') unless $first;
		$first = False;
		emit(@out, item, $mode);
	}
	@out.push(']');
}

my sub emit-object(str @out, \object, int $mode, $data-members --> Nil) {
	@out.push('{');
	my Bool $first = True;
	for sorted-pairs(object) -> $pair {
		@out.push(',') unless $first;
		$first = False;

		my Str $name = $pair.key.Str;
		@out.push(quote($name));
		@out.push(':');

		my \value = $pair.value;
		if $mode == DATA {
			emit(@out, value, DATA);
		}
		elsif $data-members.defined && $data-members{$name} {
			emit(@out, value, DATA);
		}
		elsif $name eq 'properties' && value.defined && value ~~ Associative {
			emit-name-map(@out, property-order(value, object<required>));
		}
		elsif NAME-MAP-KEYWORDS{$name} && value.defined && value ~~ Associative {
			emit-name-map(@out, sorted-pairs(value));
		}
		elsif DATA-KEYWORDS{$name} {
			emit(@out, value, DATA);
		}
		else {
			emit(@out, value, SCHEMA);
		}
	}
	@out.push('}');
}

# The members of a name-to-schema map, in the order already decided.
# Every value is a schema, so each is serialized in SCHEMA mode; the
# names themselves are never read as keywords.
my sub emit-name-map(str @out, @pairs --> Nil) {
	@out.push('{');
	my Bool $first = True;
	for @pairs -> $pair {
		@out.push(',') unless $first;
		$first = False;
		@out.push(quote($pair.key.Str));
		@out.push(':');
		emit(@out, $pair.value, SCHEMA);
	}
	@out.push('}');
}

my sub sorted-pairs(\object --> List:D) {
	object.pairs.sort(*.key.Str).List;
}

# A property map's members: the names in `required`, in its order,
# then everything else sorted.
my sub property-order(\properties, Mu \required --> List:D) {
	my %by-name;
	for properties.pairs -> $pair {
		%by-name{$pair.key.Str} = $pair;
	}

	my @ordered;
	my %taken;
	if required.defined && (required ~~ Positional || required ~~ Seq) {
		# A Seq is read through its cache: `required` is serialized
		# after this, and an uncached Seq can only be iterated once.
		for (required ~~ Seq ?? required.cache !! required.list) -> \entry {
			next unless entry.defined && entry ~~ Str;
			my Str $name = entry.Str;
			next unless %by-name{$name}:exists;
			next if %taken{$name}:exists;
			%taken{$name} = True;
			@ordered.push(%by-name{$name});
		}
	}
	for %by-name.keys.sort -> $name {
		@ordered.push(%by-name{$name}) unless %taken{$name}:exists;
	}
	@ordered.List;
}

# JSON string literal for $s, escaped in one pass over its NFC code
# points. The common case (nothing to escape) is found by the first
# scan and returned without rebuilding the string.
my sub quote(Str:D $s --> Str:D) {
	my $codes := $s.NFC;
	my int $n = nqp::elems($codes);
	my int $i = -1;
	my int $first = -1;
	while ++$i < $n {
		my int $c = nqp::atpos_i($codes, $i);
		if $c < 32 || $c == 34 || $c == 92 {
			$first = $i;
			last;
		}
	}
	return '"' ~ $s ~ '"' if $first < 0;

	my $out := nqp::create(Uni);
	nqp::push_i($out, 34);
	$i = -1;
	nqp::push_i($out, nqp::atpos_i($codes, $i)) while ++$i < $first;

	# Set while the output ends in an escape sequence. A combining mark
	# written raw at that point would compose with the escape's last
	# letter under NFC (`\n` + U+0301 is `\ń`), so it is escaped too —
	# and so is every mark after it, since `\u0301` ends in a letter or
	# digit as well. The first starter clears it: no starter composes
	# with a preceding ASCII character.
	my int $after-escape = 0;
	$i = $first - 1;
	while ++$i < $n {
		my int $c = nqp::atpos_i($codes, $i);
		if $c == 34 {
			nqp::push_i($out, 92);
			nqp::push_i($out, 34);
			$after-escape = 1;
		}
		elsif $c == 92 {
			nqp::push_i($out, 92);
			nqp::push_i($out, 92);
			$after-escape = 1;
		}
		elsif $c < 32 {
			if $c == 10 {
				nqp::push_i($out, 92);
				nqp::push_i($out, 110);
			}
			elsif $c == 13 {
				nqp::push_i($out, 92);
				nqp::push_i($out, 114);
			}
			elsif $c == 9 {
				nqp::push_i($out, 92);
				nqp::push_i($out, 116);
			}
			else {
				push-u-escape($out, $c);
			}
			$after-escape = 1;
		}
		elsif $after-escape && $c >= 0x300 && is-nonstarter($c) {
			if $c >= 0x10000 {
				my int $base = $c - 0x10000;
				push-u-escape($out, 0xD800 + ($base +> 10));
				push-u-escape($out, 0xDC00 + ($base +& 0x3FF));
			}
			else {
				push-u-escape($out, $c);
			}
		}
		else {
			nqp::push_i($out, $c);
			$after-escape = 0;
		}
	}
	nqp::push_i($out, 34);
	nqp::strfromcodes($out);
}

my sub is-nonstarter(int $c --> Bool:D) {
	$c.uniprop('Canonical_Combining_Class') ne '0';
}

# \uXXXX with four lowercase hex digits, the spelling JSON::Fast uses.
my sub push-u-escape(\out, int $c --> Nil) {
	nqp::push_i(out, 92);
	nqp::push_i(out, 117);
	my int $shift = 12;
	while $shift >= 0 {
		my int $digit = ($c +> $shift) +& 15;
		nqp::push_i(out, $digit < 10 ?? 48 + $digit !! 87 + $digit);
		$shift = $shift - 4;
	}
}
