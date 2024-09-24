#!/usr/bin/env bash
set -euo pipefail

# This script is triggered by a scheduled pipeline
# shellcheck source=./util.shlib
source .ci/util.shlib

# Read config file into global variables
UTIL_READ_CONFIG_FILE

export TMPDIR="${TMPDIR:-/tmp}"

# Special case: We are told to trigger a specific trigger
if [ -v TRIGGER ]; then
    PACKAGES=()
    TO_BUILD=()
    UTIL_GET_PACKAGES PACKAGES
    for package in "${PACKAGES[@]}"; do
        unset VARIABLES
        declare -A VARIABLES=()
        if UTIL_READ_MANAGED_PACAKGE "$package" VARIABLES; then
            if [ -v "VARIABLES[CI_ON_TRIGGER]" ]; then
                if [ "${VARIABLES[CI_ON_TRIGGER]}" == "$TRIGGER" ]; then
                    TO_BUILD+=("$package")
                fi
            fi
        fi
    done
    if [ ${#TO_BUILD[@]} -ne 0 ]; then
        .ci/schedule-packages.sh schedule "${TO_BUILD[@]}"
    fi
    exit 0
fi

git config --global user.name "$GIT_AUTHOR_NAME"
git config --global user.email "$GIT_AUTHOR_EMAIL"

# Silence some very insane log spam. Master is set by default and the silenced
# message is declared as hint.
git config --global init.defaultBranch "master"

if [ -v TEMPLATE_ENABLE_UPDATES ] && [ "$TEMPLATE_ENABLE_UPDATES" == "true" ]; then
    .ci/update-template.sh && UTIL_PRINT_INFO "Updated CI template." && exit 0 || true
fi

# Check if the scheduled tag does not exist or scheduled does not point to HEAD
if ! [ "$(git tag -l "scheduled")" ] || [ "$(git rev-parse HEAD)" != "$(git rev-parse scheduled)" ]; then
    UTIL_PRINT_ERROR "Previous on-commit pipeline did not seem to run successfully. Aborting."
    exit 1
fi

PACKAGES=()
declare -A AUR_TIMESTAMPS
MODIFIED_PACKAGES=()
# shellcheck disable=SC2034
declare -A CHANGED_LIBS=()
DELETE_BRANCHES=()
UTIL_GET_PACKAGES PACKAGES
COMMIT="${COMMIT:-false}"
PUSH=false

# Manage the .state worktree to confine the state of packages to a separate branch
# The goal is to keep the commit history clean
function manage_state() {
    if git show-ref --quiet "origin/state"; then
        git worktree add .state origin/state --detach -q
        # We have to make sure that the commit is still in the history of the state branch
        # Otherwise, this implies a force push happened. We need to re-create the state from scratch.
        if [ ! -f .state/.commit ] || ! git branch --contains "$(cat .state/.commit)" &>/dev/null; then
            git worktree remove .state
        fi
    fi
    git worktree add .newstate -B state --orphan -q
}

# Check if the current commit is already an automatic commit
# If it is, check if we should overwrite it
function manage_commit() {
    if [ -v CI_OVERWRITE_COMMITS ] && [ "$CI_OVERWRITE_COMMITS" == "true" ]; then
        local COMMIT_MSG=""
        local REGEX="^chore\(packages\): update packages( \[skip ci\])?$"
        if COMMIT_MSG="$(git log -1 --pretty=%s)"; then
            if [[ "$COMMIT_MSG" =~ $REGEX ]]; then
                # Signal that we should not only append to the commit, but also force push the branch
                COMMIT=force
            fi
        fi
    fi
}

# Loop through all packages to do optimized aur RPC calls
# $1 = Output associative array
function collect_aur_timestamps() {
    set -euo pipefail
    # shellcheck disable=SC2034
    local -n collect_aur_timestamps_output=$1
    local AUR_PACKAGES=()

    for package in "${PACKAGES[@]}"; do
        unset VARIABLES
        declare -A VARIABLES=()
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
    http_proxy="$CI_AUR_PROXY" https_proxy="$CI_AUR_PROXY" UTIL_FETCH_AUR_TIMESTAMPS collect_aur_timestamps_output "${AUR_PACKAGES[*]}"
}

function collect_changed_libs() {
    set -euo pipefail

    if [ -z "$CI_LIB_DB" ]; then
        return 0
    fi
    if [ ! -f .state/versions ]; then
        mkdir -p .state || true
        touch .state/versions
    fi

    IFS=' ' read -r -a link_array <<<"${CI_LIB_DB//\"/}"

    _TEMP_LIB="$(mktemp -d)"

    for repo in "${link_array[@]}"; do
        UTIL_PARSE_DATABASE "${repo}" "${_TEMP_LIB}"
    done

    # Sort versions file in-place because comm requires it
    sort -o "${_TEMP_LIB}/versions.new"{,}
    comm -23 .state/versions "${_TEMP_LIB}/versions.new" >"$_TEMP_LIB/versions.diff"

    while IFS= read -r line; do
        IFS=':' read -r -a pkg <<<"$line"
        CHANGED_LIBS["${pkg[0]}"]="true"
    done <"$_TEMP_LIB/versions.diff"
}

function update-lib-bump() {
    local bump=0
    local -n pkg_config=${1:-VARIABLES}

    if [[ ! -v pkg_config[CI_REBUILD_TRIGGERS] ]]; then
        return 0
    fi

    # Split the string on : into an array
    IFS=':' read -r -a LIBS <<<"${CONFIG[CI_REBUILD_TRIGGERS]}"
    for library in "${LIBS[@]}"; do
        if [[ -v CHANGED_LIBS["$library"] ]]; then
            bump=1
            break
        fi
    done

    if [ $bump -eq 1 ]; then
        UTIL_PRINT_INFO "Bumping pkgrel of $package because of a detected library mismatch"
        
        local _PKGVER _BUMPCOUNT _PKGVER_IN_DB
        # Example format: 1:1.2.3-1/1 or 1.2.3
        # Split at slash, but if it doesnt exist, set it to 1
        _PKGVER="${CONFIG[CI_PACKAGE_BUMP]%%/*}"
        _BUMPCOUNT="${CONFIG[CI_PACKAGE_BUMP]#*/}"
        _PKGVER_IN_DB=$(grep "$package:" "${_TEMP_LIB}/versions.new" | cut -d ":" -f 2)

        if [[ "${_BUMPCOUNT}" == "${CONFIG[CI_PACKAGE_BUMP]}" ]]; then
            _BUMPCOUNT=1
        fi

        if [ "$(vercmp "${_PKGVER}" "${_PKGVER_IN_DB}")" = "0" ]; then
            pkg_config[CI_PACKAGE_BUMP]="$_PKGVER_IN_DB/$_BUMPCOUNT"
        else 
            pkg_config[CI_PACKAGE_BUMP]=""
        fi
    fi
}

# $1: dir1
# $2: dir2
function package_changed() {
    set -euo pipefail
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

# Check if the package has gotten major changes
# Any change that is not a pkgver or pkgrel bump is considered a major change
# $1: dir1
# $2: dir2
function package_major_change() {
    set -euo pipefail
    local sdiff_output
    if sdiff_output="$(sdiff -ds <(gawk -f .ci/awk/remove-checksum.awk "$1/PKGBUILD") <(gawk -f .ci/awk/remove-checksum.awk "$2/PKGBUILD"))"; then
        return 1
    fi

    if [ $? -eq 2 ]; then
        UTIL_PRINT_ERROR "$2: sdiff failed"
        return 2
    fi

    if gawk -f .ci/awk/check-diff.awk <<<"$sdiff_output"; then
        # Check the rest of the files in the folder for changes
        # Excluding PKGBUILD .SRCINFO, .gitignore, .git .CI
        # shellcheck disable=SC2046
        if diff -q $(UTIL_GET_EXCLUDE_LIST "-x" "PKGBUILD .SRCINFO") -r "$1" "$2" >/dev/null; then
            return 1
        fi
    fi
    return 0
}

# $1: VARIABLES
# $2: git URL
function update_via_git() {
    set -euo pipefail
    local -n VARIABLES_VIA_GIT=${1:-VARIABLES}
    local pkgbase="${VARIABLES_VIA_GIT[PKGBASE]}"

    for i in {1..2}; do
        if git clone -q --depth=1 "$2" "$TMPDIR/aur-pulls/$pkgbase" 2>/dev/null; then
            break
        fi
        if [ "$i" -ne 2 ]; then
            UTIL_PRINT_WARNING "$pkgbase: Failed to clone $2. Retrying in 30 seconds."
            sleep 30
        else
            # Give up
            false
        fi
    done

    # Ratelimits
    sleep "$CI_CLONE_DELAY"

    # We always run shfmt on the PKGBUILD. Two runs of shfmt on the same file should not change anything
    shfmt -w "$TMPDIR/aur-pulls/$pkgbase/PKGBUILD"

    if package_changed "$TMPDIR/aur-pulls/$pkgbase" "$pkgbase"; then
        if [ -v CI_HUMAN_REVIEW ] && [ "$CI_HUMAN_REVIEW" == "true" ] && package_major_change "$TMPDIR/aur-pulls/$pkgbase" "$pkgbase"; then
            UTIL_PRINT_INFO "$pkgbase: Major change detected."
            VARIABLES_VIA_GIT[CI_REQUIRES_REVIEW]=true
        fi
        # Rsync: delete files in the destination that are not in the source. Exclude deleting .CI, exclude copying .git
        # shellcheck disable=SC2046
        rsync -a --delete $(UTIL_GET_EXCLUDE_LIST "--exclude") "$TMPDIR/aur-pulls/$pkgbase/" "$pkgbase/"
    fi
}

# $1: VARIABLES
# $2: source
function update_from_gitlab_tag() {
    set -euo pipefail
    local -n VARIABLES_UPDATE_FROM_GITLAB_TAG=${1:-VARIABLES}
    local pkgbase="${VARIABLES_UPDATE_FROM_GITLAB_TAG[PKGBASE]}"
    local project_id="${2:-}"

    if [ ! -f "$pkgbase/.SRCINFO" ]; then
        UTIL_PRINT_ERROR "$pkgbase: .SRCINFO does not exist."
        return
    fi

    local TAG_OUTPUT
    if ! TAG_OUTPUT="$(curl --fail-with-body --silent "https://gitlab.com/api/v4/projects/${project_id}/repository/tags?order_by=version&per_page=1")" || [ -z "$TAG_OUTPUT" ]; then
        UTIL_PRINT_ERROR "$pkgbase: Failed to get list of tags."
        return
    fi

    local COMMIT_URL VERSION
    COMMIT_URL="$(jq -r '.[0].commit.web_url' <<<"$TAG_OUTPUT")"
    VERSION="$(jq -r '.[0].name' <<<"$TAG_OUTPUT")"

    if [ -z "$COMMIT_URL" ] || [ -z "$VERSION" ]; then
        UTIL_PRINT_ERROR "$pkgbase: Failed to get latest tag."
        return
    fi

    # Parse .SRCINFO file for PKGVER
    local SRCINFO_PKGVER
    if ! SRCINFO_PKGVER="$(grep -m 1 -oP '\tpkgver\s=\s\K.*$' "$pkgbase/.SRCINFO")"; then
        UTIL_PRINT_ERROR "$pkgbase: Failed to parse PKGVER from .SRCINFO."
        return
    fi

    # Check if the tag is different from the PKGVER
    if [ "$VERSION" == "$SRCINFO_PKGVER" ]; then
        return
    fi

    # Extract project URL and commit hash from commit URL
    # shellcheck disable=2034
    local DOWNLOAD_URL BASE_URL COMMIT PROJECT_NAME
    if [[ "$COMMIT_URL" =~ ^(.*)/([^/]+)/-/commit/([^/]+)$ ]]; then
        PROJECT_NAME="${BASH_REMATCH[2]}"
        COMMIT="${BASH_REMATCH[3]}"
        BASE_URL="${BASH_REMATCH[1]}/${PROJECT_NAME}/-/archive"
    else
        UTIL_PRINT_ERROR "$pkgbase: Failed to parse commit URL."
        return
    fi

    shfmt -w "$pkgbase/PKGBUILD"

    gawk -i inplace -f .ci/awk/update-pkgbuild.awk -v TARGET_VERSION="$VERSION" -v BASE_URL="$BASE_URL" -v TARGET_URL="${BASE_URL}/\${_commit}/${PROJECT_NAME}-\${_commit}.tar.gz" -v COMMIT="$COMMIT" "$pkgbase/PKGBUILD"
    gawk -i inplace -f .ci/awk/update-srcinfo.awk -v TARGET_VERSION="$VERSION" -v BASE_URL="$BASE_URL" -v TARGET_URL="${BASE_URL}/${COMMIT}/${PROJECT_NAME}-${COMMIT}.tar.gz" "$pkgbase/.SRCINFO"
}

function update_pkgbuild() {
    set -euo pipefail
    local -n VARIABLES_UPDATE_PKGBUILD=${1:-VARIABLES}
    local pkgbase="${VARIABLES_UPDATE_PKGBUILD[PKGBASE]}"

    if ! [ -v "VARIABLES_UPDATE_PKGBUILD[CI_PKGBUILD_SOURCE]" ] || [ -z "${VARIABLES_UPDATE_PKGBUILD[CI_PKGBUILD_SOURCE]}" ]; then
        UTIL_PRINT_WARNING "$pkgbase: CI_PKGBUILD_SOURCE is not set. If this is on purpose, please set it to 'custom'."
        return 0
    fi

    local PKGBUILD_SOURCE="${VARIABLES_UPDATE_PKGBUILD[CI_PKGBUILD_SOURCE]}"

    if [[ "$PKGBUILD_SOURCE" == "custom" ]]; then
        return 0
    # Check if the source starts with gitlab:
    elif [[ "$PKGBUILD_SOURCE" =~ ^gitlab:(.*) ]]; then
        update_from_gitlab_tag VARIABLES_UPDATE_PKGBUILD "${BASH_REMATCH[1]}"
    # Check if the package is from the AUR
    elif [[ "$PKGBUILD_SOURCE" != aur ]]; then
        update_via_git VARIABLES_UPDATE_PKGBUILD "$PKGBUILD_SOURCE"
    else
        local git_url="https://aur.archlinux.org/${pkgbase}.git"

        # Fetch from optimized AUR RPC call
        if ! [ -v "AUR_TIMESTAMPS[$pkgbase]" ]; then
            UTIL_PRINT_WARNING "Could not find $pkgbase in cached AUR timestamps."
            return 0
        fi
        local NEW_TIMESTAMP="${AUR_TIMESTAMPS[$pkgbase]}"

        # Check if CI_PKGBUILD_TIMESTAMP is set
        if [ -v "VARIABLES_UPDATE_PKGBUILD[CI_PKGBUILD_TIMESTAMP]" ]; then
            local PKGBUILD_TIMESTAMP="${VARIABLES_UPDATE_PKGBUILD[CI_PKGBUILD_TIMESTAMP]}"
            if [ "$PKGBUILD_TIMESTAMP" == "$NEW_TIMESTAMP" ]; then
                return 0
            fi
        fi
        http_proxy="$CI_AUR_PROXY" https_proxy="$CI_AUR_PROXY" update_via_git VARIABLES_UPDATE_PKGBUILD "$git_url"
        UTIL_UPDATE_AUR_TIMESTAMP VARIABLES_UPDATE_PKGBUILD "$NEW_TIMESTAMP"
    fi
}

function update_vcs() {
    set -euo pipefail
    local -n VARIABLES_UPDATE_VCS=${1:-VARIABLES}
    local pkgbase="${VARIABLES_UPDATE_VCS[PKGBASE]}"

    # Check if pkgbase ends with -git or if CI_GIT_COMMIT is set
    if [[ "$pkgbase" != *-git ]] && [ ! -v "VARIABLES_UPDATE_VCS[CI_GIT_COMMIT]" ]; then
        return 0
    fi

    local _NEWEST_COMMIT
    if ! _NEWEST_COMMIT="$(UTIL_FETCH_VCS_COMMIT VARIABLES_UPDATE_VCS)"; then
        UTIL_PRINT_WARNING "Could not fetch latest commit for $pkgbase via heuristic."
        return 0
    fi

    if [ -z "$_NEWEST_COMMIT" ]; then
        unset "VARIABLES_UPDATE_VCS[CI_GIT_COMMIT]"
        return 0
    fi

    # Check if CI_GIT_COMMIT is set
    if [ -v "VARIABLES_UPDATE_VCS[CI_GIT_COMMIT]" ]; then
        local CI_GIT_COMMIT="${VARIABLES_UPDATE_VCS[CI_GIT_COMMIT]}"
        if [ "$CI_GIT_COMMIT" != "$_NEWEST_COMMIT" ]; then
            UTIL_UPDATE_VCS_COMMIT VARIABLES_UPDATE_VCS "$_NEWEST_COMMIT"
        fi
    else
        UTIL_UPDATE_VCS_COMMIT VARIABLES_UPDATE_VCS "$_NEWEST_COMMIT"
    fi
}

# Create .state and .newstate worktrees
manage_state

# Reduce history pollution from automatic commits
manage_commit

# Collect last modified timestamps from AUR in an efficient way
collect_aur_timestamps AUR_TIMESTAMPS

# Parse database files for library version changes
collect_changed_libs CHANGED_LIBS

mkdir "$TMPDIR/aur-pulls"
if [ -f "./.editorconfig" ]; then
    cp "./.editorconfig" "$TMPDIR/aur-pulls/.editorconfig"
fi

# Loop through all packages to check if they need to be updated
for package in "${PACKAGES[@]}"; do
    unset VARIABLES
    declare -A VARIABLES=()
    UTIL_READ_MANAGED_PACAKGE "$package" VARIABLES || true
    update_pkgbuild VARIABLES
    update_vcs VARIABLES
    update-lib-bump VARIABLES
    UTIL_LOAD_CUSTOM_HOOK "./${package}" "./${package}/.CI/update.sh" || true
    UTIL_WRITE_MANAGED_PACKAGE "$package" VARIABLES

    if ! git diff --exit-code --quiet -- "$package"; then
        # shellcheck disable=SC2102
        if [[ -v VARIABLES[CI_REQUIRES_REVIEW] ]] && [ "${VARIABLES[CI_REQUIRES_REVIEW]}" == "true" ]; then
            # The updated state of the package will still be written to the state branch, even if the main content goes onto the PR branch
            # This is okay, because merging the PR branch will trigger a build, so that behavior is expected and prevents a double execution
            if [ "$COMMIT" == "false" ]; then
                .ci/create-pr.sh "$package" false
            else
                # If we already made a commit, we should go one commit further back to avoid merge conflicts
                # This is because there is a very high chance this current commit will be amended
                .ci/create-pr.sh "$package" true
            fi
            PUSH=true
        else
            git add "$package"
            if [ "$COMMIT" == "false" ]; then
                COMMIT=true
                [ -v GITLAB_CI ] && git commit -q -m "chore(packages): update packages"
                [ -v GITHUB_ACTIONS ] && git commit -q -m "chore(packages): update packages [skip ci]"
            else
                git commit -q --amend --no-edit --date=now
            fi
            PUSH=true

            # We don't want to schedule packages that have a specific trigger to prevent 
            # large packages getting scheduled too often and wasting resources (e.g. llvm-git)
            if [[ ${VARIABLES[CI_ON_TRIGGER]+x} ]]; then 
                UTIL_PRINT_INFO "Will not schedule $package because it has trigger ${VARIABLES[CI_ON_TRIGGER]} set."
            else 
                MODIFIED_PACKAGES+=("$package")
            fi 

            if [ -v CI_HUMAN_REVIEW ] && [ "$CI_HUMAN_REVIEW" == "true" ] && git show-ref --quiet "origin/update-$package"; then
                DELETE_BRANCHES+=("update-$package")
            fi
        fi
    # We also need to check the worktree for changes, because we might have an updated git hash
    elif ! UTIL_CHECK_STATE_DIFF "$package"; then
        MODIFIED_PACKAGES+=("$package")
    fi
done

# Update the lib versions state file
if [ $PUSH == true ]; then
    mv "$_TEMP_LIB/versions.new" .newstate/versions
    git add .newstate/versions
    git commit -q --amend --no-edit --date=now
fi

git rev-parse HEAD >.newstate/.commit
git -C .newstate add -A
git -C .newstate commit -q -m "chore(state): update state" --allow-empty

if [ ${#MODIFIED_PACKAGES[@]} -ne 0 ]; then
    .ci/schedule-packages.sh schedule "${MODIFIED_PACKAGES[@]}"
    .ci/manage-aur.sh "${MODIFIED_PACKAGES[@]}"
fi

if [ "$PUSH" = true ]; then
    git tag -f scheduled
    git_push_args=()
    for branch in "${DELETE_BRANCHES[@]}"; do
        git_push_args+=(":$branch")
    done
    [ -v GITLAB_CI ] && git_push_args+=("-o" "ci.skip")
    [ "$COMMIT" == "force" ] && git_push_args+=("--force-with-lease=main")
    git push --atomic origin HEAD:main +state +refs/tags/scheduled "${git_push_args[@]}"
fi
