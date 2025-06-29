unit class LLM::Chat::Backend::Settings;

subset Probability of Num where 0 <= * <= 1;
subset PositiveNum of Num where * >= 0;
subset PositiveInt of Int where * >= 0;

has PositiveNum $.temperature     is rw = (1.0).Num;
has Probability $.top_p           is rw = (1.0).Num;
has PositiveInt $.top_k           is rw = 200.int;
has Probability $.min_p           is rw = (0.0).Num;
has Probability $.typical_p       is rw = (1.0).Num;
has PositiveInt $.rep_pen_range   is rw = 0.int;
has PositiveNum $.repetition_pen  is rw = (1.0).Num;
has Num         $.frequency_pen   is rw = (0.0).Num;
has Num         $.presence_pen    is rw = (0.0).Num;
has Probability $.xtc_probability is rw = (0.0).Num;
has Probability $.xtc_threshold   is rw = (0.0).Num;
has PositiveInt $.dry_allowed_len is rw = 2.int;
has PositiveNum $.dry_multiplier  is rw = (0.0).Num;
has PositiveNum $.dry_base        is rw = (1.75).Num;
has Str         @.dry_seq_break   is rw = ("\n", ":", "\"", "*");
has PositiveInt $.max_tokens      is rw = 256.int;
has PositiveInt $.max_context     is rw = 16384.int;
has Str         @.stop            is rw = ();

