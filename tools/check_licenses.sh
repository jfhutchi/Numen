#!/usr/bin/env bash
# Fail if anything under assets/third_party/ is not covered by ATTRIBUTIONS.md.
#
# A file counts as covered when its own repo-relative path, or any ancestor
# directory of it up to assets/third_party, appears verbatim in the ledger.
# That lets a 200-file asset pack be logged as one row for its directory,
# while an unlogged stray file still fails the build.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ledger="ATTRIBUTIONS.md"
asset_dir="assets/third_party"

if [ ! -f "$ledger" ]; then
	echo "FAIL: $ledger is missing" >&2
	exit 1
fi

if [ ! -d "$asset_dir" ]; then
	echo "licences: no $asset_dir directory, nothing to attribute"
	exit 0
fi

checked=0
missing=0

while IFS= read -r file; do
	checked=$((checked + 1))
	path="$file"
	covered=0
	while [ "$path" != "$asset_dir" ] && [ "$path" != "." ] && [ "$path" != "/" ]; do
		if grep -qF -- "$path" "$ledger"; then
			covered=1
			break
		fi
		path="$(dirname "$path")"
	done
	if [ "$covered" -eq 0 ]; then
		echo "FAIL: $file has no entry in $ledger" >&2
		missing=$((missing + 1))
	fi
done < <(find "$asset_dir" -type f ! -name '.gitkeep' ! -name '*.import')

if [ "$missing" -gt 0 ]; then
	echo "licences: $missing of $checked third-party file(s) unattributed" >&2
	exit 1
fi

echo "licences: $checked third-party file(s) checked, all attributed"
