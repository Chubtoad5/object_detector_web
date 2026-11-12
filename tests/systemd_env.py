"""Reads an EnvironmentFile= the way systemd does (src/basic/env-file.c, parse_env_file_internal), for the unit
tests, which have no systemd (spec 21, O12). Unquoted, a value loses its spaces at either end and each \\ escapes the
next character (a \\ before the end of the line joins the next line on). In double quotes, only \\ " ` and $ are
escaped; any other \\ stays. In single quotes nothing is.

As a command: systemd_env.py <file> prints the variables as JSON.
"""
import json
import sys

NEWLINE = "\n\r"
WHITESPACE = " \t\n\r"
COMMENTS = "#;"
SHELL_NEED_ESCAPE = "\"\\`$"


def parse(text):
    out = {}
    state = "PRE_KEY"
    key, value = [], []
    last_key_ws = last_value_ws = None

    def push():
        k = key[:last_key_ws] if last_key_ws is not None else key
        out["".join(k)] = "".join(value)

    for c in text:
        if state == "PRE_KEY":
            if c in COMMENTS:
                state = "COMMENT"
            elif c not in WHITESPACE:
                state, key, last_key_ws = "KEY", [c], None
        elif state == "KEY":
            if c in NEWLINE:
                state, key = "PRE_KEY", []
            elif c == "=":
                state, value, last_value_ws = "PRE_VALUE", [], None
            else:
                if c not in WHITESPACE:
                    last_key_ws = None
                elif last_key_ws is None:
                    last_key_ws = len(key)
                key.append(c)
        elif state == "PRE_VALUE":
            if c in NEWLINE:
                push()
                state, key, value = "PRE_KEY", [], []
            elif c == "'":
                state = "SINGLE_QUOTE_VALUE"
            elif c == '"':
                state = "DOUBLE_QUOTE_VALUE"
            elif c == "\\":
                state = "VALUE_ESCAPE"
            elif c not in WHITESPACE:
                state = "VALUE"
                value.append(c)
        elif state == "VALUE":
            if c in NEWLINE:
                if last_value_ws is not None:
                    del value[last_value_ws:]
                push()
                state, key, value = "PRE_KEY", [], []
            elif c == "\\":
                state, last_value_ws = "VALUE_ESCAPE", None
            else:
                if c not in WHITESPACE:
                    last_value_ws = None
                elif last_value_ws is None:
                    last_value_ws = len(value)
                value.append(c)
        elif state == "VALUE_ESCAPE":
            state = "VALUE"
            if c not in NEWLINE:
                value.append(c)
        elif state == "SINGLE_QUOTE_VALUE":
            if c == "'":
                state = "PRE_VALUE"
            else:
                value.append(c)
        elif state == "DOUBLE_QUOTE_VALUE":
            if c == '"':
                state = "PRE_VALUE"
            elif c == "\\":
                state = "DOUBLE_QUOTE_VALUE_ESCAPE"
            else:
                value.append(c)
        elif state == "DOUBLE_QUOTE_VALUE_ESCAPE":
            state = "DOUBLE_QUOTE_VALUE"
            if c in SHELL_NEED_ESCAPE:
                value.append(c)
            elif c != "\n":
                value.extend(["\\", c])
        elif state == "COMMENT":
            if c == "\\":
                state = "COMMENT_ESCAPE"
            elif c in NEWLINE:
                state = "PRE_KEY"
        elif state == "COMMENT_ESCAPE":
            state = "PRE_KEY" if c in NEWLINE else "COMMENT"
    if state in ("PRE_VALUE", "VALUE", "VALUE_ESCAPE", "SINGLE_QUOTE_VALUE", "DOUBLE_QUOTE_VALUE",
                 "DOUBLE_QUOTE_VALUE_ESCAPE"):
        if state == "VALUE" and last_value_ws is not None:
            del value[last_value_ws:]
        push()
    return out


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8", errors="surrogateescape") as f:
        print(json.dumps(parse(f.read())))
