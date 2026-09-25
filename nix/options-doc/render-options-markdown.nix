{
  pkgs,
  optionDocs,
  defaultConfigText,
  groupSummaries,
}:

let
  # Type, Default and Example as one short paragraph per option instead of three
  # headed blocks each; short values inline, the rest as code after it.
  compactFields = pkgs.writeText "compact-fields.py" ''
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
  '';

  summaryTsv = pkgs.writeText "group-summaries.tsv" (
    pkgs.lib.concatMapStrings (group: "${group.name}\t${group.summary}\n") groupSummaries
  );
in
# One file per top-level option group, plus an index. The single 6k-line page was
# not navigable.
pkgs.runCommand "proxy-suite-options-doc" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  mkdir -p "$out" "$TMPDIR/bodies"
  all="$TMPDIR/all.md"
  index_tsv="$TMPDIR/sections-index.tsv"

  cat ${optionDocs.optionsCommonMark} >"$all"
  python ${compactFields} "$all"

  summary() { awk -F '\t' -v want="$1" '$1 == want { print $2 }' ${summaryTsv}; }

  # Anchor every section and file it under its top-level group. Options directly
  # under services.proxy-suite (only `enable`) stay on the index.
  : >"$index_tsv"
  awk -v outdir="$TMPDIR/bodies" -v index_tsv="$index_tsv" '
    function slugify(text,    slug) {
      slug = text
      gsub(/\\/, "", slug)
      slug = tolower(slug)
      gsub(/[^a-z0-9]+/, "-", slug)
      sub(/^-+/, "", slug)
      sub(/-+$/, "", slug)
      return slug
    }

    /^## / {
      title = substr($0, 4)
      normalized = title
      gsub(/\\/, "", normalized)
      count = split(normalized, parts, /\./)
      group = (count <= 3) ? "index" : parts[3]
      slug = slugify(title)
      current = outdir "/" group ".md"

      print title "\t" slug "\t" group >> index_tsv
      print "<a id=\"" slug "\"></a>" >> current
      print $0 >> current
      next
    }

    { if (current != "") print >> current }
  ' "$all"

  groups="$(cut -f3 "$index_tsv" | grep -v '^index$' | awk '!seen[$0]++')"

  # Per-group table of contents, nested by option path.
  mkToc() {
    awk -F '\t' -v want="$1" '
      function indent(depth,    i, prefix) {
        prefix = ""
        for (i = 0; i < depth; i++) {
          prefix = prefix "  "
        }
        return prefix
      }

      function displayLabel(label) {
        if (label == "*") {
          return "item"
        }
        if (label ~ /^<.*>$/) {
          return "`" label "`"
        }
        return label
      }

      function addChild(parent, child,    key) {
        key = parent SUBSEP child
        if (!(key in seenChild)) {
          seenChild[key] = 1
          childCount[parent]++
          childOrder[parent, childCount[parent]] = child
        }
      }

      function printNode(path, label, depth,    i, child, childPath, text) {
        text = displayLabel(label)
        if (path in slugByPath) {
          text = "[" text "](#" slugByPath[path] ")"
        }
        print indent(depth) "- " text
        for (i = 1; i <= childCount[path]; i++) {
          child = childOrder[path, i]
          childPath = path "." child
          printNode(childPath, child, depth + 1)
        }
      }

      $3 == want {
        normalized = $1
        gsub(/\\/, "", normalized)
        slugByPath[normalized] = $2

        count = split(normalized, parts, /\./)
        parent = "services.proxy-suite"
        for (i = 3; i <= count; i++) {
          child = parts[i]
          addChild(parent, child)
          parent = parent "." child
        }
      }

      END { printNode("services.proxy-suite." want, want, 0) }
    ' "$index_tsv"
  }

  # Groups in the summary list's order, then any it misses.
  ordered="$(
    { cut -f1 ${summaryTsv}; printf '%s\n' $groups; } \
      | awk -v groups=" $(echo $groups) " 'index(groups, " " $0 " ") && !seen[$0]++'
  )"

  for group in $groups; do
    {
      printf '# services.proxy-suite.%s\n\n' "$group"
      text="$(summary "$group")"
      if [ -n "$text" ]; then printf '%s\n\n' "$text"; fi
      printf 'Part of the [proxy-suite options reference](./index.md).\n\n'
      printf '## Options\n\n'
      mkToc "$group"
      printf '\n'
      cat "$TMPDIR/bodies/$group.md"
    } >"$TMPDIR/$group.out"
  done

  {
    printf '# proxy-suite options\n\n'
    printf 'Generated from the `services.proxy-suite` option descriptions under\n'
    printf '[`modules/proxy-suite/options/`](/modules/proxy-suite/options/).\n'
    printf 'Update the module option docs there instead of editing these files by hand.\n\n'

    printf '## Option groups\n\n'
    printf '| Group | What it covers |\n|---|---|\n'
    for group in $ordered; do
      printf '| [%s](./%s.md) | %s |\n' "$group" "$group" "$(summary "$group")"
    done
    printf '\n'

    if [ -f "$TMPDIR/bodies/index.md" ]; then
      cat "$TMPDIR/bodies/index.md"
      printf '\n'
    fi

    printf '## Complete default config\n\n'
    printf '<details>\n<summary>Every option at its default</summary>\n\n'
    printf '```nix\n'
    printf 'services.proxy-suite = %s;\n' ${pkgs.lib.escapeShellArg defaultConfigText}
    printf '```\n\n</details>\n'
  } >"$TMPDIR/index.out"

  # Collapse runs of blank lines, drop trailing ones.
  for group in $groups index; do
    awk 'NF { if (blank) print ""; blank = 0; print; next } { blank = 1 }' \
      "$TMPDIR/$group.out" >"$out/$group.md"
  done
''
