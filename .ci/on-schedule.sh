#!/usr/bin/env bash
set -e -o pipefail

# This script is triggered by a scheduled pipeline

# Check if the scheduled tag does not exist or scheduled does not point to HEAD
if ! [ "$(git tag -l "scheduled")" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse scheduled)" ]; then
    echo "Previous on-commit pipeline did not seem to run successfully. Aborting." >&2
    exit 1
fi

source .ci/util.shlib

TMPDIR="${TMPDIR:-/tmp}"

PACKAGES=()
MODIFIED_PACKAGES=()
UTIL_GET_PACKAGES PACKAGES

# $1: dir1
# $2: dir2
function package_changed() {
    # Check if the package has changed
    # NOTE: Pay attention! Okay, *snaps fingers*. We don't care if anything but the PKGBUILD or .SRCINFO has changed.
    # Any properly built PKGBUILD will use hashes, which will change
    if diff -q "$1/PKGBUILD" "$2/PKGBUILD" >/dev/null; then
        if [ ! -f "$1/.SRCINFO" ] && [ ! -f "$2/.SRCINFO" ]; then
            return 1
        elif [ -f "$1/.SRCINFO" ] && [ -f "$2/.SRCINFO" ]; then
            if diff -q "$1/.SRCINFO" "$2/.SRCINFO" >/dev/null; then
                return 1
            fi
        fi
    fi
    return 0
}

# $1: VARIABLES
# $2: git URL
function update_via_git() {
    local -n VARIABLES=${1:-VARIABLES}
    local pkgbase="${VARIABLES[PKGBASE]}"

    git clone --depth=1 "$2" "$TMPDIR/aur-pulls/$pkgbase"

    # We always run shfmt on the PKGBUILD. Two runs of shfmt on the same file should not change anything
    shfmt -w "$TMPDIR/aur-pulls/$pkgbase/PKGBUILD"
    
    if package_changed "$TMPDIR/aur-pulls/$pkgbase" "$pkgbase"; then
        # Rsync: delete files in the destination that are not in the source. Exclude deleting .CI_CONFIG, exclude copying .git
        rsync -a --delete --exclude=.CI_CONFIG --exclude=.git "$TMPDIR/aur-pulls/$pkgbase/" "$pkgbase/"
        MODIFIED_PACKAGES+=("$pkgbase")
    fi
}

# $1: VARIABLES
# $2: new timestamp
function update_aur_timestamp() {
    local -n VARIABLES=${1:-VARIABLES}
    local new_timestamp="$2"

    if [ "$new_timestamp" != "0" ]; then
        VARIABLES[CI_PKGBUILD_TIMESTAMP]="$new_timestamp"
    fi
}

function update_pkgbuild() {
    local -n VARIABLES=${1:-VARIABLES}
    local pkgbase="${VARIABLES[PKGBASE]}"
    if ! [ -v "VARIABLES[CI_PKGBUILD_SOURCE]" ]; then
        return 0
    fi

    local PKGBUILD_SOURCE="${VARIABLES[CI_PKGBUILD_SOURCE]}"

    # Check if format is aur:pkgbase
    if [[ "$PKGBUILD_SOURCE" != aur:* ]]; then
        update_via_git VARIABLES "$PKGBUILD_SOURCE"
    else
        local pkgbase="${PKGBUILD_SOURCE#aur:}"
        local git_url="https://aur.archlinux.org/${pkgbase}.git"

        local NEW_TIMESTAMP
        NEW_TIMESTAMP="$(curl -s "https://aur.archlinux.org/rpc/v5/info?arg[]=$pkgbase" | jq -r '.results[0].LastModified' || echo "0")"

        # Check if CI_PKGBUILD_TIMESTAMP is set
        if [ -v "VARIABLES[CI_PKGBUILD_TIMESTAMP]" ]; then
            local PKGBUILD_TIMESTAMP="${VARIABLES[CI_PKGBUILD_TIMESTAMP]}"
            if [ "$PKGBUILD_TIMESTAMP" != "$NEW_TIMESTAMP" ]; then
                update_via_git VARIABLES "$git_url"
                update_aur_timestamp VARIABLES "$NEW_TIMESTAMP"
            fi
        else
            update_via_git VARIABLES "$git_url"
            update_aur_timestamp VARIABLES "$NEW_TIMESTAMP"
        fi
    fi
}

# $1: VARIABLES
# $2: new commit
function update_vcs_commit() {
    local -n VARIABLES=${1:-VARIABLES}
    local new_commit="$2"

    if [ "$new_commit" != "0" ]; then
        VARIABLES[CI_GIT_COMMIT]="$new_commit"
    fi
}

function update_vcs() {
    local -n VARIABLES=${1:-VARIABLES}
    local pkgbase="${VARIABLES[PKGBASE]}"

    # Check if pkgbase ends with -git
    if [[ "$pkgbase" != *-git ]]; then
        return 0
    fi

    # Check if .SRCINFO exists. We can't work with a -git package without it
    if ! [ -f "$pkgbase/.SRCINFO" ]; then
        return 0
    fi

    # Parse the first source from the .SRCINFO file
    local source
    source=$(grep -m 1 -oP '\ssource\s=\s.*git\+\K.*$' "$pkgbase/.SRCINFO")

    if [ -z "$source" ]; then
        return 0
    fi

    local _NEWEST_COMMIT
    _NEWEST_COMMIT="$(git ls-remote "$_SOURCE" | grep -m1 -oP '\w+(?=\tHEAD)' || echo "0")"

    # Check if CI_GIT_COMMIT is set
    if [ -v "VARIABLES[CI_GIT_COMMIT]" ]; then
        local CI_GIT_COMMIT="${VARIABLES[CI_GIT_COMMIT]}"
        if [ "$CI_GIT_COMMIT" != "$_NEWEST_COMMIT" ]; then
            update_vcs_commit "$_NEWEST_COMMIT"
            MODIFIED_PACKAGES+=("$pkgbase")
        fi
    else
        update_vcs_commit "$_NEWEST_COMMIT"
        MODIFIED_PACKAGES+=("$pkgbase")
    fi
}

mkdir "$TMPDIR/aur-pulls"

# Loop through all packages
for package in "${PACKAGES[@]}"; do
    declare -A VARIABLES
    if UTIL_READ_MANAGED_PACAKGE "$package" VARIABLES; then
        update_pkgbuild VARIABLES
        update_vcs VARIABLES
        UTIL_WRITE_VARIABLES_TO_FILE "$package/.CI_CONFIG" VARIABLES
    fi
done

if ! git diff --exit-code --quiet; then
    git add .
    git commit -m "chore(packages): update packages [skip ci]"
fi

"$(dirname "$(realpath "$0")")"/schedule-packages.sh "${MODIFIED_PACKAGES[*]}"

git tag -f scheduled
git push --atomic "$REPO_URL" HEAD:main refs/tags/scheduled
