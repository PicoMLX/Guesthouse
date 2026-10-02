#!/bin/bash
set -euo pipefail

# Xcode Cloud's second test phase has test products, but no source checkout.
# https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions
if [[ "${CI_XCODEBUILD_ACTION:-}" == "test-without-building" ]]; then
    exit 0
fi

if [[ -n "${CI_PRIMARY_REPOSITORY_PATH:-}" ]]; then
    repository_root="${CI_PRIMARY_REPOSITORY_PATH}"
else
    script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    repository_root="${script_directory}/.."
fi
cd -- "${repository_root}"

shopt -s nullglob
package_manifests=(Packages/*/Package.swift)
if (( ${#package_manifests[@]} == 0 )); then
    printf 'error: No package manifests found under Packages/.\n' >&2
    exit 1
fi

for manifest in "${package_manifests[@]}"; do
    package_directory="${manifest%/Package.swift}"
    printf 'Testing %s with warnings treated as errors\n' "${package_directory}"
    swift test --package-path "${package_directory}" -Xswiftc -warnings-as-errors \
        -Xcc -Wall -Xcc -Wextra -Xcc -Werror
done

# The shared Xcode Test action is Debug. Exercise the actual GUI launch factory in
# Release as well, so moving a simulation override outside DEBUG cannot pass CI.
client_package_directory="Packages/GuesthouseClientKit"
if [[ -f "${client_package_directory}/Package.swift" ]]; then
    printf 'Testing %s in Release with warnings treated as errors\n' "${client_package_directory}"
    swift test --package-path "${client_package_directory}" --configuration release \
        -Xswiftc -warnings-as-errors -Xcc -Wall -Xcc -Wextra -Xcc -Werror
fi
