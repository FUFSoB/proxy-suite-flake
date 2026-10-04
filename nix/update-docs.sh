set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"

if [[ -z "${repo_root}" || ! -f "${repo_root}/flake.nix" ]]; then
  echo "run this helper from inside the proxy-suite-flake repository" >&2
  exit 1
fi

options_output_path="$(nix build --no-link --print-out-paths "${repo_root}#optionsDoc")"
readme_output_path="$(nix build --no-link --print-out-paths "${repo_root}#readmeDoc")"

mkdir -p "${repo_root}/docs"
rm -rf "${repo_root}/docs/options"
cp -r --no-preserve=mode,ownership "${options_output_path}" "${repo_root}/docs/options"
install -Dm644 "${readme_output_path}" "${repo_root}/README.md"

# After the README, whose blocks are among them.
snippets_output_path="$(nix build --no-link --print-out-paths "${repo_root}#usageSnippets")"
rm -rf "${repo_root}/docs/usage/.snippets"
cp -r --no-preserve=mode,ownership "${snippets_output_path}" "${repo_root}/docs/usage/.snippets"

echo "updated ${repo_root}/docs/options/"
echo "updated ${repo_root}/README.md"
echo "updated ${repo_root}/docs/usage/.snippets/"
