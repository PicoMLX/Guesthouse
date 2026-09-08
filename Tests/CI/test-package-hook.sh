#!/bin/bash
set -euo pipefail

test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "${test_directory}/../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/guesthouse-ci-hook.XXXXXX")"
trap 'rm -rf -- "${test_root}"' EXIT

checkout="${test_root}/selected checkout"
mkdir -p "${checkout}/ci_scripts" "${test_root}/bin" "${test_root}/elsewhere"
cp "${repository_root}/ci_scripts/ci_pre_xcodebuild.sh" "${checkout}/ci_scripts/"
cp "${test_directory}/Fixtures/swift" "${test_root}/bin/swift"
chmod +x "${test_root}/bin/swift"
hook="${checkout}/ci_scripts/ci_pre_xcodebuild.sh"
for package in "Alpha Kit" Beta Zebra; do
    mkdir -p "${checkout}/Packages/${package}"
    touch "${checkout}/Packages/${package}/Package.swift"
done
mkdir -p "${checkout}/Fixtures/Skipped" "${checkout}/Packages/NoManifest"
touch "${checkout}/Fixtures/Skipped/Package.swift"

export PATH="${test_root}/bin:${PATH}"
export CI_HOOK_EXPECTED_ROOT="$(cd -- "${checkout}" && pwd -P)"
export CI_HOOK_INVOCATIONS="${test_root}/invocations"
unset CI_HOOK_FAIL_PACKAGE CI_XCODEBUILD_ACTION
cd -- "${test_root}/elsewhere"

assert_all_packages() {
    printf '%s\n' 'Packages/Alpha Kit' Packages/Beta Packages/Zebra |
        cmp - "${CI_HOOK_INVOCATIONS}"
}

# Xcode Cloud selects the checkout even when the hook starts in another directory.
: > "${CI_HOOK_INVOCATIONS}"
CI_PRIMARY_REPOSITORY_PATH="${checkout}" CI_XCODEBUILD_ACTION=build-for-testing "${hook}"
assert_all_packages

# Local calls find the repository from the script, with either unset or empty CI path.
: > "${CI_HOOK_INVOCATIONS}"
(unset CI_PRIMARY_REPOSITORY_PATH; "${hook}")
assert_all_packages
: > "${CI_HOOK_INVOCATIONS}"
CI_PRIMARY_REPOSITORY_PATH= "${hook}"
assert_all_packages

# A package failure must stop later packages and preserve Swift's exit status.
: > "${CI_HOOK_INVOCATIONS}"
status=0
CI_PRIMARY_REPOSITORY_PATH="${checkout}" CI_HOOK_FAIL_PACKAGE=Packages/Beta "${hook}" || status=$?
[[ "${status}" == 23 ]]
printf '%s\n' 'Packages/Alpha Kit' Packages/Beta | cmp - "${CI_HOOK_INVOCATIONS}"

# The source-free second test phase must succeed without any Swift invocation.
: > "${CI_HOOK_INVOCATIONS}"
CI_PRIMARY_REPOSITORY_PATH="${test_root}/missing" CI_XCODEBUILD_ACTION=test-without-building "${hook}"
[[ ! -s "${CI_HOOK_INVOCATIONS}" ]]

# A bad explicit CI checkout must not silently fall back to another repository.
status=0
CI_PRIMARY_REPOSITORY_PATH="${test_root}/missing" "${hook}" 2>/dev/null || status=$?
[[ "${status}" != 0 && ! -s "${CI_HOOK_INVOCATIONS}" ]]

# Missing packages must fail instead of producing a green check with no tests.
mkdir -p "${test_root}/empty checkout"
status=0
CI_PRIMARY_REPOSITORY_PATH="${test_root}/empty checkout" "${hook}" 2>/dev/null || status=$?
[[ "${status}" == 1 && ! -s "${CI_HOOK_INVOCATIONS}" ]]

printf 'Package hook: 7 scenarios passed.\n'
