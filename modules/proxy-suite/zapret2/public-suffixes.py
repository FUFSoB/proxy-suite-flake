# The ICANN section of the public suffix list, one rule per line, every label in the
# xn-- form a TLS SNI carries ("рф" is "xn--p1ai" on the wire).
import sys


def ascii_label(label):
    return label if label == "*" or label.isascii() else "xn--" + label.encode("punycode").decode()


def ascii_rule(rule):
    bang = "!" if rule.startswith("!") else ""
    return bang + ".".join(ascii_label(label) for label in rule.removeprefix("!").lower().split("."))


inside = False
rules = []
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line == "// ===BEGIN ICANN DOMAINS===":
            inside = True
        elif line == "// ===END ICANN DOMAINS===":
            break
        elif inside and line and not line.startswith("//"):
            rules.append(ascii_rule(line.split()[0]))

if len(rules) < 1000:
    sys.exit(f"only {len(rules)} ICANN rules: did the list's format change?")
print("\n".join(rules))
