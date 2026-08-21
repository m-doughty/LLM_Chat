#!/usr/bin/env python3
"""Check or explicitly rewrite the pinned DeepSeek V4 prompt goldens.

The adjacent oracle is copied unmodified from DeepSeek-V4-Flash-0731 commit
7872f01b1d1fe23eabc4c98b48bffcef5a386062 under its MIT licence.
"""

import argparse
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True

from encoding_dsv4 import encode_messages


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "t" / "fixtures" / "deepseek-v4"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--write",
        action="store_true",
        help="replace checked-in outputs; without this flag only verify them",
    )
    args = parser.parse_args()

    failed = False
    for case in range(1, 5):
        messages = json.loads((FIXTURES / f"test-input-{case}.json").read_text())
        actual = encode_messages(
            messages,
            thinking_mode="chat" if case == 4 else "thinking",
        )
        output = FIXTURES / f"test-output-{case}.txt"
        if args.write:
            output.write_text(actual)
            print(f"wrote {output.relative_to(ROOT)}")
        elif output.read_text() != actual:
            failed = True
            print(f"DIFF {output.relative_to(ROOT)}")
        else:
            print(f"ok {output.relative_to(ROOT)}")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
