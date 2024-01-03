#!/usr/bin/env bash
set -euo pipefail
set -x

# This script is triggered by a scheduled pipeline

# Check if the scheduled tag does not exist or scheduled does not point to HEAD
if ! [ "$(git tag -l "scheduled")" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse scheduled)" ]; then
    echo "Previous on-commit pipeline did not seem to run successfully. Aborting." >&2
    exit 1
fi

source .ci/util.shlib

TMPDIR="${TMPDIR:-/tmp}"

PACKAGES=()
declare -A AUR_TIMESTAMPS
MODIFIED_PACKAGES=()
UTIL_GET_PACKAGES PACKAGES

# Loop through all packages to do optimized aur RPC calls
# $1 = Output associative array
function collect_aur_timestamps() {
    local -n collect_aur_timestamps_output=$1
    local AUR_PACKAGES=()

    for package in "${PACKAGES[@]}"; do
        unset VARIABLES
        declare -gA VARIABLES
        if UTIL_READ_MANAGED_PACAKGE "$package" VARIABLES; then
            if [ -v "VARIABLES[CI_PKGBUILD_SOURCE]" ]; then
                local PKGBUILD_SOURCE="${VARIABLES[CI_PKGBUILD_SOURCE]}"
                if [[ "$PKGBUILD_SOURCE" == aur ]]; then
                    AUR_PACKAGES+=("$package")
                fi
            fi
        fi
    done

    # Get all timestamps from AUR
    UTIL_FETCH_AUR_TIMESTAMPS collect_aur_timestamps_output "${AUR_PACKAGES[*]}"
}

# $1: dir1
# $2: dir2
function package_changed() {
    # Check if the package has changed
    # NOTE: We don't care if anything but the PKGBUILD or .SRCINFO has changed.
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
    local -n VARIABLES_VIA_GIT=${1:-VARIABLES}
    local pkgbase="${VARIABLES_VIA_GIT[PKGBASE]}"

    git clone --depth=1 "$2" "$TMPDIR/aur-pulls/$pkgbase"

    # We always run shfmt on the PKGBUILD. Two runs of shfmt on the same file should not change anything
    shfmt -w "$TMPDIR/aur-pulls/$pkgbase/PKGBUILD"
    
    if package_changed "$TMPDIR/aur-pulls/$pkgbase" "$pkgbase"; then
        # Rsync: delete files in the destination that are not in the source. Exclude deleting .CI_CONFIG, exclude copying .git
        rsync -a --delete --exclude=.CI_CONFIG --exclude=.git --exclude=.gitignore "$TMPDIR/aur-pulls/$pkgbase/" "$pkgbase/"
        MODIFIED_PACKAGES+=("$pkgbase")
    fi
}

function update_pkgbuild() {
    local -n VARIABLES_UPDATE_PKGBUILD=${1:-VARIABLES}
    local pkgbase="${VARIABLES_UPDATE_PKGBUILD[PKGBASE]}"
    if ! [ -v "VARIABLES_UPDATE_PKGBUILD[CI_PKGBUILD_SOURCE]" ]; then
        return 0
    fi

    local PKGBUILD_SOURCE="${VARIABLES_UPDATE_PKGBUILD[CI_PKGBUILD_SOURCE]}"

    # Check if the package is from the AUR
    if [[ "$PKGBUILD_SOURCE" != aur ]]; then
        update_via_git VARIABLES_UPDATE_PKGBUILD "$PKGBUILD_SOURCE"
    else
        local git_url="https://aur.archlinux.org/${pkgbase}.git"

        # Fetch from optimized AUR RPC call
        if ! [ -v "AUR_TIMESTAMPS[$pkgbase]" ]; then
            echo "Warning: Could not find $pkgbase in cached AUR timestamps." >&2
            return 0
        fi
        local NEW_TIMESTAMP="${AUR_TIMESTAMPS[$pkgbase]}"

        # Check if CI_PKGBUILD_TIMESTAMP is set
        if [ -v "VARIABLES_UPDATE_PKGBUILD[CI_PKGBUILD_TIMESTAMP]" ]; then
            local PKGBUILD_TIMESTAMP="${VARIABLES_UPDATE_PKGBUILD[CI_PKGBUILD_TIMESTAMP]}"
            if [ "$PKGBUILD_TIMESTAMP" != "$NEW_TIMESTAMP" ]; then
                update_via_git VARIABLES_UPDATE_PKGBUILD "$git_url"
                UTIL_UPDATE_AUR_TIMESTAMP VARIABLES_UPDATE_PKGBUILD "$NEW_TIMESTAMP"
            fi
        else
            update_via_git VARIABLES_UPDATE_PKGBUILD "$git_url"
            UTIL_UPDATE_AUR_TIMESTAMP VARIABLES_UPDATE_PKGBUILD "$NEW_TIMESTAMP"
        fi
    fi
}

function update_vcs() {
    local -n VARIABLES_UPDATE_VCS=${1:-VARIABLES}
    local pkgbase="${VARIABLES_UPDATE_VCS[PKGBASE]}"

    # Check if pkgbase ends with -git or if CI_GIT_COMMIT is set
    if [[ "$pkgbase" != *-git ]] && [ ! -v "VARIABLES_UPDATE_VCS[CI_GIT_COMMIT]" ]; then
        return 0
    fi

    local _NEWEST_COMMIT
    if ! _NEWEST_COMMIT="$(UTIL_FETCH_VCS_COMMIT VARIABLES_UPDATE_VCS)"; then
        echo "Warning: Could not fetch latest commit for $pkgbase via heuristic." >&2
        return 0
    fi

    if [ -z "$_NEWEST_COMMIT" ]; then
        unset VARIABLES_UPDATE_VCS[CI_GIT_COMMIT]
        return 0
    fi

    # Check if CI_GIT_COMMIT is set
    if [ -v "VARIABLES_UPDATE_VCS[CI_GIT_COMMIT]" ]; then
        local CI_GIT_COMMIT="${VARIABLES_UPDATE_VCS[CI_GIT_COMMIT]}"
        if [ "$CI_GIT_COMMIT" != "$_NEWEST_COMMIT" ]; then
            UTIL_UPDATE_VCS_COMMIT VARIABLES_UPDATE_VCS "$_NEWEST_COMMIT"
            MODIFIED_PACKAGES+=("$pkgbase")
        fi
    else
        UTIL_UPDATE_VCS_COMMIT VARIABLES_UPDATE_VCS "$_NEWEST_COMMIT"
        MODIFIED_PACKAGES+=("$pkgbase")
    fi
}

# Collect last modified timestamps from AUR in an efficient way
collect_aur_timestamps AUR_TIMESTAMPS

mkdir "$TMPDIR/aur-pulls"

# Loop through all packages to check if they need to be updated
for package in "${PACKAGES[@]}"; do
    unset VARIABLES
    declare -A VARIABLES
    if UTIL_READ_MANAGED_PACAKGE "$package" VARIABLES; then
        update_pkgbuild VARIABLES
        update_vcs VARIABLES
        UTIL_PRUNE_UNKNOWN_VARIABLES VARIABLES
        UTIL_WRITE_VARIABLES_TO_FILE "$package/.CI_CONFIG" VARIABLES
    fi
done

COMMIT=false

if ! git diff --exit-code --quiet; then
    git config --global user.name "$GIT_AUTHOR_NAME"
    git config --global user.email "$GIT_AUTHOR_EMAIL"
    git add .
    git commit -m "chore(packages): update packages [skip ci]"
    COMMIT=true
fi

if [ ${#MODIFIED_PACKAGES[@]} -ne 0 ]; then
    "$(dirname "$(realpath "$0")")"/schedule-packages.sh "${MODIFIED_PACKAGES[*]}"
fi

if [ "$COMMIT" = true ]; then
    git tag -f scheduled
    git push --atomic origin HEAD:main +refs/tags/scheduled
fi