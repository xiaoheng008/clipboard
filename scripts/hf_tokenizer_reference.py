#!/usr/bin/env python3
"""Reference token ids for HFTokenizerTests (pip install tokenizers==0.22.2).
Usage: hf_tokenizer_reference.py <tokenizer.json> [--lower] <text>...
"""
import json, sys
from tokenizers import Tokenizer

path, args = sys.argv[1], sys.argv[2:]
lower = "--lower" in args
tk = Tokenizer.from_file(path)
tk.no_padding(); tk.no_truncation()
for s in [a for a in args if a != "--lower"]:
    print(json.dumps(s, ensure_ascii=False), tk.encode(s.lower() if lower else s).ids)
