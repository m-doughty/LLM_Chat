unit class LLM::Chat::Backend::Settings;

subset Probability of Num where 0 <= * <= 1;
subset PositiveNum of Num where * >= 0;
subset PositiveInt of Int where * >= 0;
subset ReasoningEffort of Str where * eq any('none', 'minimal', 'low', 'medium', 'high');
subset SlotId of Int where * >= 0;

has PositiveNum     $.temperature     is rw = (1.0).Num;
has Probability     $.top_p           is rw = (1.0).Num;
has PositiveInt     $.top_k           is rw = 200.int;
has Probability     $.min_p           is rw = (0.0).Num;
has Probability     $.typical_p       is rw = (1.0).Num;
has PositiveInt     $.rep_pen_range   is rw = 0.int;
has PositiveNum     $.repetition_pen  is rw = (1.0).Num;
has Num             $.frequency_pen   is rw = (0.0).Num;
has Num             $.presence_pen    is rw = (0.0).Num;
has Probability     $.xtc_probability is rw = (0.0).Num;
has Probability     $.xtc_threshold   is rw = (0.0).Num;
has PositiveInt     $.dry_allowed_len is rw = 2.int;
has PositiveNum     $.dry_multiplier  is rw = (0.0).Num;
has PositiveNum     $.dry_base        is rw = (1.75).Num;
has Str             @.dry_seq_break   is rw = ("\n", ":", "\"", "*");
has PositiveInt     $.max_tokens      is rw = 256.int;
has PositiveInt     $.max_context     is rw = 16384.int;
has Str             @.stop            is rw = ();
#|( Reasoning-effort level for thinking-capable models: one of
    C<'none'>, C<'minimal'>, C<'low'>, C<'medium'> or C<'high'>. Leave
    undefined (the default) to send nothing, so the server's chat
    template decides. L<LLM::Chat::Backend::OpenAICommon> sends it as
    the top-level C<reasoning_effort> field: llama.cpp's server passes
    it to the chat template (C<'none'> turns thinking off; a Mistral
    Small 4 template takes C<'none'> and C<'high'>).
    L<LLM::Chat::Backend::KoboldCpp> sends the same field, which
    KoboldCpp reads as a thinking level. L<LLM::Chat::Backend::OpenRouter>
    sends C<reasoning: { effort: ... }> instead, as OpenRouter expects.
    Whatever the model thinks arrives on the Response's
    C<reasoning-text>, never in its content, and is never sent back.
    Its tokens are part of the completion tokens a server reports, so
    they count against C<max_tokens>: give a reasoning request room for
    both the thinking and the answer. )
has ReasoningEffort $.reasoning_effort is rw;

#|( A per-request cap on thinking tokens, for servers that take one.
    Undefined (the default) sends nothing. llama.cpp's server reads it
    as C<reasoning_budget_tokens>, overriding its C<--reasoning-budget>
    flag for this request, and forces the end of thinking once the
    budget is spent; it applies only when the chat template marks its
    thinking (Mistral's C<[THINK]> ... C<[/THINK]> does). KoboldCpp
    reads it as C<thinking_budget_tokens>, and only when
    C<reasoning_effort> is not one of its named levels (it derives a
    budget from those itself). OpenRouter ignores it. C<0> means "end
    thinking at once". )
has PositiveInt $.reasoning_budget_tokens is rw;

#|( The llama.cpp server slot to run this request on, sent as
    C<id_slot>. Undefined (the default) sends nothing and lets the
    server choose. A llama.cpp server keeps each slot's last prompt in
    its KV cache and reuses the longest common prefix of the next
    request on that slot, so pinning requests that share a long
    prefix (the same system rules, say) to one slot makes those cache
    hits dependable instead of depending on which slot happened to be
    idle. The server wraps an index past its slot count
    (C<id % total_slots>). Two requests pinned to one slot run one
    after the other. Only L<LLM::Chat::Backend::OpenAICommon> sends
    it; KoboldCpp and OpenRouter have no slots and never do. )
has SlotId $.id_slot is rw;

#|( Optional JSON Schema (as a plain Hash) constraining the model's
    output shape — structured outputs. Leave undefined (the default)
    to omit any constraint. How it reaches the wire is per-backend:

    =item OpenAI-compatible / OpenRouter — sent as
      C<response_format: { type: 'json_schema', json_schema: { name,
      strict: false, schema } }>. Enforcement depends on the serving
      provider/model; providers that don't support structured outputs
      typically ignore the field, so callers should keep their own
      parse validation as the backstop.
    =item KoboldCpp — sent as the native C<json_schema> generate
      field, which KoboldCpp compiles to a grammar and enforces at
      the sampler (hard guarantee, local).

    The schema Hash is passed through verbatim — build it with plain
    nested Hashes/Arrays using JSON Schema vocabulary (C<type>,
    C<properties>, C<required>, C<enum>, ...).

    B<Field order.> A Hash has no order of its own, so on the wire
    every schema's C<properties> are listed in the order of that
    schema's C<required> array, then any optional properties
    alphabetically — at every nesting level. Grammar-compiling servers
    (llama.cpp, KoboldCpp) make the model write the fields in exactly
    that order, so list C<required> in the order you want them
    generated:

        json_schema => %(
            type       => 'object',
            properties => %(
                verdict => %( type => 'string' ),
                quote   => %( type => 'string' ),
            ),
            required   => [ 'quote', 'verdict' ],  # quote is written first
        )

    See L<LLM::Chat::WireJSON> for the complete rule. )
has $.json_schema is rw;

#|( Name attached to the schema in OpenAI-style C<response_format>
    payloads (some providers require it). Ignored by KoboldCpp. )
has Str $.json_schema_name is rw = 'response';

