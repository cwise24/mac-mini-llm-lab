#!/usr/bin/env python3
"""Substitute __VAR__ tokens in a template from the environment.

Unresolved tokens are a HARD ERROR.

The previous inline version left unknown tokens in place. A helm values file then
received the literal string "__LITELLM_WITH_DB__" where a boolean belonged, and
the install either failed with a type error far from the cause or quietly took a
default. Since lib.sh now supplies defaults for every config key, anything still
unresolved at this point is a genuine bug and should stop the run by name.
"""
import os, re, sys

def main() -> int:
    tpl, out = sys.argv[1], sys.argv[2]
    src = open(tpl).read()
    missing = set()

    def sub(m):
        key = m.group(1)
        val = os.environ.get(key)
        if val is None:
            missing.add(key)
            return m.group(0)
        return val

    rendered = re.sub(r"__([A-Z0-9_]+)__", sub, src)
    if missing:
        sys.stderr.write(
            "unresolved template tokens in %s: %s\n" % (tpl, ", ".join(sorted(missing)))
        )
        return 2
    open(out, "w").write(rendered)
    return 0

if __name__ == "__main__":
    sys.exit(main())
