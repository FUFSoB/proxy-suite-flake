import re
import sys
from pathlib import Path

FIELD = re.compile(r"^\*(Type|Default|Example):\*$")
FENCE = re.compile(r"^`{3,}")

path = Path(sys.argv[1])
lines = path.read_text().split("\n")
out = []
option_type = None
para = []
i = 0


def flush():
    # Hard line breaks, not a list: a list would merge with one that ends the
    # description.
    if para:
        if out[-1] != "":
            out.append("")
        out.append("\\\n".join(para))
        para.clear()


def flat(code):
    # `[ "a" "b" ]` and `{ a = 1; }` read fine on one line; multi-line strings do not.
    if any("'" * 2 in line or "`" in line for line in code):
        return None
    text = " ".join(line.strip() for line in code)
    return text if len(text) <= 72 else None


while i < len(lines):
    match = FIELD.match(lines[i])
    if not match:
        out.append(lines[i])
        i += 1
        continue
    name = match.group(1)
    i += 1
    if lines[i] == "" and FENCE.match(lines[i + 1]):
        fence = FENCE.match(lines[i + 1]).group(0)
        end = lines.index(fence, i + 2)
        code, text = lines[i + 2 : end], None
        i = end + 1
    else:
        end = lines.index("", i)
        code, text = None, " ".join(lines[i:end])
        i = end

    if name == "Type":
        option_type = text
    # mkEnableOption's example says nothing.
    if not (name == "Example" and option_type == "boolean" and code == ["true"]):
        label = f"**{name}:**"
        if code is None:
            para.append(f"{label} {text}")
        elif flat(code) is not None:
            para.append(f"{label} `{flat(code)}`")
        else:
            para.append(label)
            flush()
            out.extend(["", f"{fence}nix", *code, fence])

    # Keep the fields of one option together.
    after = i
    while after < len(lines) and lines[after] == "":
        after += 1
    if after < len(lines) and FIELD.match(lines[after]):
        i = after
    else:
        flush()

path.write_text("\n".join(out))
