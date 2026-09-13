{
  pkgs,
  optionDocs,
  defaultConfigText,
}:

# One file per top-level option group, plus an index. The single 6k-line page was
# not navigable.
pkgs.runCommand "proxy-suite-options-doc" { } ''
  mkdir -p "$out" "$TMPDIR/bodies"
  all="$TMPDIR/all.md"
  index_tsv="$TMPDIR/sections-index.tsv"

  cat ${optionDocs.optionsCommonMark} >"$all"

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

  for group in $groups; do
    {
      printf '# services.proxy-suite.%s\n\n' "$group"
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
    for group in $groups; do
      printf -- '- [%s](./%s.md)\n' "$group" "$group"
    done
    printf '\n'

    printf '## Complete default config\n\n'
    printf '```nix\n'
    printf 'services.proxy-suite = %s;\n' ${pkgs.lib.escapeShellArg defaultConfigText}
    printf '```\n\n'

    if [ -f "$TMPDIR/bodies/index.md" ]; then
      cat "$TMPDIR/bodies/index.md"
    fi
  } >"$TMPDIR/index.out"

  # Collapse runs of blank lines, drop trailing ones.
  for group in $groups index; do
    awk 'NF { if (blank) print ""; blank = 0; print; next } { blank = 1 }' \
      "$TMPDIR/$group.out" >"$out/$group.md"
  done
''
