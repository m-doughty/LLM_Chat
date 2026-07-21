unit class LLM::Chat::Backend::Settings;

subset Probability of Num where 0 <= * <= 1;
subset PositiveNum of Num where * >= 0;
subset PositiveInt of Int where * >= 0;
subset ReasoningEffort of Str where * eq any('low', 'medium', 'high');

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
#|( Reasoning-effort hint for thinking-capable models. Currently
    consumed by L<LLM::Chat::Backend::OpenRouter>, which forwards it
    via the OpenRouter-compatible C<reasoning: { effort: ... }>
    request field. Other backends ignore it. Leave undefined to omit
    the field entirely (default behaviour). Only the strings 'low',
    'medium', and 'high' are accepted. )
has ReasoningEffort $.reasoning_effort is rw;

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
    C<properties>, C<required>, C<enum>, ...). )
has $.json_schema is rw;

#|( Name attached to the schema in OpenAI-style C<response_format>
    payloads (some providers require it). Ignored by KoboldCpp. )
has Str $.json_schema_name is rw = 'response';

