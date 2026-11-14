#!/usr/bin/env bash
# Test the alternative `gcrypt://` URL spelling.
#
# Covers:
#   * native `gcrypt::<backend>` syntax still works
#   * `gcrypt:///absolute/path` (local backend) round-trips a push/clone
#   * branch selection via `?gcrypt-branch=next` works on the git backend
#   * the native `#next` fragment still selects the same branch
#   * `gcrypt://host`, unknown query parameters and a double branch
#     selector are rejected rather than silently mis-handled
#   * `gcrypt://[user@]host[:port]/path` is rewritten to an ssh URL
#   * a bare GIT_DIR/GIT_WORK_TREE fetch (as used by Nix) works
#
# Requires bash, git, gpg and a writable temp directory.  It never touches
# the user's ~/.gnupg.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
PATH="${repo_root}:${PATH}"
export PATH

tempdir=$(mktemp -d)
readonly tempdir
trap 'rm -rf -- "${tempdir}"' EXIT

# Keep the user's keyring and any ambient GIT_* variables out of the test.
git_env=$(env | sed -n 's/^\(GIT_[^=]*\)=.*$/\1/p')
# shellcheck disable=SC2086
IFS=$'\n' unset ${git_env}

export GNUPGHOME="${tempdir}/gnupg"
mkdir -m 700 "${GNUPGHOME}"
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key 'gcrypt nix-urls test <test@example.invalid>' \
    default default never >/dev/null 2>&1

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

failures=0
check() {
    local desc=$1
    shift
    if "$@"; then
        echo "ok   - ${desc}"
    else
        echo "FAIL - ${desc}"
        failures=$((failures + 1))
    fi
}

make_src() {
    local dir=$1 content=$2
    git init -q -b master "${dir}"
    printf '%s\n' "${content}" > "${dir}/payload.txt"
    git -C "${dir}" add payload.txt
    git -C "${dir}" commit -qm initial
    git -C "${dir}" config gcrypt.participants simple
}

# 1. Native syntax still works, end to end.
make_src "${tempdir}/native-src" native
git -C "${tempdir}/native-src" remote add enc "gcrypt::${tempdir}/native-remote"
check 'native push' git -C "${tempdir}/native-src" push -q enc master
check 'native clone' git clone -q "gcrypt::${tempdir}/native-remote" "${tempdir}/native-clone"
check 'native round-trip content' \
    grep -qx native "${tempdir}/native-clone/payload.txt"

# 2. gcrypt:///absolute/path, local backend, end to end.
make_src "${tempdir}/alt-src" alt
git -C "${tempdir}/alt-src" remote add enc "gcrypt://${tempdir}/alt-remote"
check 'gcrypt:/// push' git -C "${tempdir}/alt-src" push -q enc master
check 'gcrypt:/// clone' git clone -q "gcrypt://${tempdir}/alt-remote" "${tempdir}/alt-clone"
check 'gcrypt:/// round-trip content' \
    grep -qx alt "${tempdir}/alt-clone/payload.txt"

# 3. Branch selection on the git backend, alternative spelling.
git init -q --bare "${tempdir}/branch.git"
make_src "${tempdir}/branch-src" branch
git -C "${tempdir}/branch-src" remote add enc \
    "gcrypt://${tempdir}/branch.git?gcrypt-branch=next"
check 'gcrypt-branch push' git -C "${tempdir}/branch-src" push -q enc master
check 'gcrypt-branch stored on refs/heads/next' \
    git --git-dir="${tempdir}/branch.git" rev-parse --verify --quiet refs/heads/next
check 'gcrypt-branch clone' git clone -q \
    "gcrypt://${tempdir}/branch.git?gcrypt-branch=next" "${tempdir}/branch-clone"
check 'gcrypt-branch round-trip content' \
    grep -qx branch "${tempdir}/branch-clone/payload.txt"

# 4. The native `#next` fragment selects the same branch.
git init -q --bare "${tempdir}/hash.git"
make_src "${tempdir}/hash-src" hash
git -C "${tempdir}/hash-src" remote add enc "gcrypt::${tempdir}/hash.git#next"
check 'native #next push' git -C "${tempdir}/hash-src" push -q enc master
check 'native #next stored on refs/heads/next' \
    git --git-dir="${tempdir}/hash.git" rev-parse --verify --quiet refs/heads/next

# 5. Invalid alternative spellings are rejected with a useful message.
if git ls-remote "gcrypt://nohostslash" >"${tempdir}/out" 2>"${tempdir}/err"; then
    check 'gcrypt://host rejected' false
else
    check 'gcrypt://host rejected' \
        grep -q "neither an absolute local path" "${tempdir}/err"
fi

if git ls-remote "gcrypt://example.invalid/repo?bogus=1" \
        >"${tempdir}/out" 2>"${tempdir}/err"; then
    check 'unknown query rejected' false
else
    check 'unknown query rejected' \
        grep -q "unsupported query parameter" "${tempdir}/err"
fi

if git ls-remote "gcrypt://example.invalid/repo?gcrypt-branch=next#next" \
        >"${tempdir}/out" 2>"${tempdir}/err"; then
    check 'double branch selector rejected' false
else
    check 'double branch selector rejected' \
        grep -q "both a #fragment and gcrypt-branch" "${tempdir}/err"
fi

# 6. ssh URL translation: a fake ssh records the host, user, port and path.
cat > "${tempdir}/fakessh" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "${GCRYPT_TEST_SSH_LOG}"
exit 1
EOF
chmod +x "${tempdir}/fakessh"
GCRYPT_TEST_SSH_LOG="${tempdir}/ssh.log"
export GCRYPT_TEST_SSH_LOG
: > "${GCRYPT_TEST_SSH_LOG}"
git init -q "${tempdir}/ssh-src"
GIT_SSH_COMMAND="${tempdir}/fakessh" GIT_SSH_VARIANT=ssh \
    git -C "${tempdir}/ssh-src" ls-remote \
    "gcrypt://alice@example.invalid:2222/repo" \
    >"${tempdir}/out" 2>"${tempdir}/err" || true
check 'ssh translation passes user@host' \
    grep -q 'alice@example.invalid' "${GCRYPT_TEST_SSH_LOG}"
check 'ssh translation passes port' grep -qx '2222' "${GCRYPT_TEST_SSH_LOG}"
check 'ssh translation passes path' \
    grep -q "git-upload-pack '/repo'" "${GCRYPT_TEST_SSH_LOG}"

# 7. Bare GIT_DIR/GIT_WORK_TREE fetch, as Nix does it.
git init -q --bare "${tempdir}/nix/.git"
mkdir -p "${tempdir}/nix/work"
if (
    cd "${tempdir}/nix/work"
    GIT_DIR="${tempdir}/nix/.git" GIT_WORK_TREE="${tempdir}/nix" \
        git fetch -q "gcrypt://${tempdir}/alt-remote" master
    GIT_DIR="${tempdir}/nix/.git" git rev-parse --verify --quiet FETCH_HEAD
) >/dev/null; then
    check 'GIT_DIR fetch from gcrypt:/// works' true
else
    check 'GIT_DIR fetch from gcrypt:/// works' false
fi

echo
if [ "${failures}" -ne 0 ]; then
    echo "${failures} test(s) failed"
    exit 1
fi
echo "All nix-urls tests passed."
