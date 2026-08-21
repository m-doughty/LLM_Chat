# DeepSeek V4 golden oracle

`encoding_dsv4.py` is the unmodified MIT-licensed encoder/decoder reference
from `deepseek-ai/DeepSeek-V4-Flash-0731`, pinned to commit
`7872f01b1d1fe23eabc4c98b48bffcef5a386062`.

Normal Raku tests only read the checked-in fixtures and do not need Python.
To compare those fixtures with the reference implementation:

```sh
python3 tools/deepseek-v4/regenerate-goldens.py
```

Updating files is deliberately explicit:

```sh
python3 tools/deepseek-v4/regenerate-goldens.py --write
```

The first upstream input originally stored tools beside `messages`; the local
fixture places that same tools array on its system message, exactly as the
upstream test does immediately before calling `encode_messages`.
