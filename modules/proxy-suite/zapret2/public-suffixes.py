# The ICANN section of the public suffix list, one rule per line, every label in the
# xn-- form a TLS SNI carries ("рф" is "xn--p1ai" on the wire). With --private, the
# PRIVATE section too (workers.dev, github.io): names there belong to unrelated parties.
import sys

with_private = "--private" in sys.argv[1:]
source = next(arg for arg in sys.argv[1:] if arg != "--private")


def ascii_label(label):
    return label if label == "*" or label.isascii() else "xn--" + label.encode("punycode").decode()


def ascii_rule(rule):
    bang = "!" if rule.startswith("!") else ""
    return bang + ".".join(ascii_label(label) for label in rule.removeprefix("!").lower().split("."))


inside = False
rules = []
with open(source, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line == "// ===BEGIN ICANN DOMAINS===" or (with_private and line == "// ===BEGIN PRIVATE DOMAINS==="):
            inside = True
        elif line == "// ===END ICANN DOMAINS===" and with_private:
            inside = False
        elif line in ("// ===END ICANN DOMAINS===", "// ===END PRIVATE DOMAINS==="):
            break
        elif inside and line and not line.startswith("//"):
            rules.append(ascii_rule(line.split()[0]))

if len(rules) < 1000:
    sys.exit(f"only {len(rules)} ICANN rules: did the list's format change?")
print("\n".join(rules))
