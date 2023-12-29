#!/bin/bash

set -euo pipefail

# This script parses the parameters passed to this script and outputs a list of package names to a file

mapfile -t PACKAGES <<< "$@"

if [ -v "PACKAGES[0]" ] && [ "${PACKAGES[0]}" == "all" ]; then
    echo "Rebuild of all packages requested."
    mapfile -t PACKAGES < <(find . -mindepth 1 -type d -not -path '*/.*' -printf '%P\n')
fi

# Check if the array of packages is empty
if [ ${#PACKAGES[@]} -eq 0 ]; then
    echo "No packages to build."
    exit 0
fi

# Prepend the source repo name to each package name
for i in "${!PACKAGES[@]}"; do
    PACKAGES[i]="${BUILD_REPO}:${PACKAGES[$i]}"
done

echo "schedule --repo=$REPO_NAME ${PACKAGES[*]}" > .ci/schedule-params.txt