#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# Know where the repo root is so we can reference things relative to it
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source bingo so we can use kustomize and yq
. "${REPO_ROOT}/.bingo/variables.env"

# We're going to do file manipulation, so let's work in a temp dir
TMP_ROOT="$(mktemp -p . -d 2>/dev/null || mktemp -d ./tmpdir.XXXXXXX)"
# Make sure to delete the temp dir when we exit
trap 'rm -rf $TMP_ROOT' EXIT

# Copy all kustomize files into a temp dir
TMP_CONFIG="${TMP_ROOT}/config"
cp -a "${REPO_ROOT}/config" "$TMP_CONFIG"

# Override namespace to openshift-operator-controller
$YQ -i '.namespace = "openshift-operator-controller"' "${TMP_CONFIG}/default/kustomization.yaml"

# Create a temp dir for manifests
TMP_MANIFEST_DIR="${TMP_ROOT}/manifests"
mkdir -p "$TMP_MANIFEST_DIR"

# Run kustomize, which emits a single yaml file
TMP_KUSTOMIZE_OUTPUT="${TMP_MANIFEST_DIR}/temp.yaml"
$KUSTOMIZE build "${TMP_CONFIG}/default" -o "$TMP_KUSTOMIZE_OUTPUT"

# Use yq to split the single yaml file into 1 per document.
# Naming convention: $index-$kind-$namespace-$name. If $namespace is empty, just use the empty string.
(
  cd "$TMP_MANIFEST_DIR"

  # shellcheck disable=SC2016
  ${YQ} -s '$index +"-"+ (.kind|downcase) +"-"+ (.metadata.namespace // "") +"-"+ .metadata.name' temp.yaml
)

# Delete the single yaml file
rm "$TMP_KUSTOMIZE_OUTPUT"

# Delete and recreate the actual manifests directory
MANIFEST_DIR="${REPO_ROOT}/openshift/manifests"
rm -rf "${MANIFEST_DIR}"
mkdir -p "${MANIFEST_DIR}"

# Copy everything we just generated and split into the actual manifests directory
cp "$TMP_MANIFEST_DIR"/* "$MANIFEST_DIR"/

# Update file names to be in the format nn-$kind-$namespace-$name
(
  cd "$MANIFEST_DIR"

  for f in *; do
    # Get the numeric prefix from the filename
    index=$(echo "$f" | cut -d '-' -f 1)
    # Keep track of the full file name without the leading number and dash
    name_without_index=${f#$index-}
    # Fix the double dash in cluster-scoped names
    name_without_index=${name_without_index//--/-}
    # Reformat the name so the leading number is always padded to 2 digits
    new_name=$(printf "%02d" "$index")-$name_without_index
    # Some file names (namely CRDs) don't end in .yml - make them
    if ! [[ "$new_name" =~ yml$ ]]; then
      new_name="${new_name}".yml
    fi
    if [[ "$f" != "$new_name" ]]; then
      # Rename
      mv "$f" "${new_name}"
    fi
  done
)

