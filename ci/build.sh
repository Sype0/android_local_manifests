#!/bin/bash
# Build; when an attempt fails, keep the synced tree and wait for a fix pushed to
# this repo or to any project in local_manifests.xml, re-sync only what changed,
# then build again. Stops at the job time budget.
# Run from the top of the source tree. Needs JOB_START, JOB_BUDGET_MIN, DEVICE,
# VARIANT, TARGET, WAIT_FOR_FIX, MANIFESTS_DIR.
set -u

deadline=$(( JOB_START + JOB_BUDGET_MIN * 60 ))
minutes_left() { echo $(( (deadline - $(date +%s)) / 60 )); }
manifest_head() { git ls-remote "https://github.com/$GITHUB_REPOSITORY" "refs/heads/$GITHUB_REF_NAME" | cut -f1; }

# "<path> <url> <sha>" for every project in local_manifests.xml
project_heads() {
    python3 - "$MANIFESTS_DIR/local_manifests.xml" <<'PY' |
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
remotes = {r.get("name"): r.get("fetch").rstrip("/") for r in root.iter("remote")}
for p in root.iter("project"):
    print(p.get("path"), f'{remotes[p.get("remote")]}/{p.get("name")}', p.get("revision"))
PY
    while read -r path url rev; do
        echo "$path $url $(git ls-remote "$url" "refs/heads/$rev" | cut -f1)"
    done
}

# Publish the failure to the ci-status branch so it can be read while the job waits.
publish_status() {
    local dir=/tmp/ci-status
    rm -rf "$dir" && mkdir -p "$dir" && cd "$dir" || return
    git init -q && git checkout -q -b ci-status
    {
        echo "run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
        echo "attempt: $1  rc: $2  state: $3  time: $(date -u +%FT%TZ)  minutes_left: $(minutes_left)"
        df -h /build | tail -1
        echo "---- errors ----"
        grep -nE -A6 'error:|FAILED:|ERROR:|Error:|fatal:' /build/build.log | grep -v '^\[ *[0-9]*% ' | head -300
        echo "---- tail ----"
        tail -80 /build/build.log
    } > status.txt
    git add status.txt && git -c user.name=ci -c user.email=ci@localhost commit -qm "attempt $1: $3"
    git push -qf "https://x-access-token:$GH_TOKEN@github.com/$GITHUB_REPOSITORY" ci-status
    cd - > /dev/null
}

wait_for_fix() {
    local old_manifest=$1 now_manifest
    echo "::warning::Build failed. Waiting for a fix to be pushed ($(minutes_left)m left; cancel the run to stop)."
    while [ "$(minutes_left)" -gt 20 ]; do
        sleep 60
        now_manifest=$(manifest_head)
        if [ -n "$now_manifest" ] && [ "$now_manifest" != "$old_manifest" ]; then
            git -C "$MANIFESTS_DIR" fetch -q origin "$GITHUB_REF_NAME" && git -C "$MANIFESTS_DIR" reset -q --hard FETCH_HEAD
            return 0
        fi
        project_heads > /tmp/heads.new
        cmp -s /tmp/heads.old /tmp/heads.new || return 0
    done
    return 1
}

resync_changed() {
    cp "$MANIFESTS_DIR/local_manifests.xml" "$MANIFESTS_DIR/ci/remove_unneeded.xml" .repo/local_manifests/
    project_heads > /tmp/heads.new
    local changed
    changed=$(diff /tmp/heads.old /tmp/heads.new | sed -n 's/^> \([^ ]*\) .*/\1/p')
    echo "Re-syncing: ${changed:-nothing}"
    for path in $changed; do
        rm -rf "$path" ".repo/projects/$path.git"
        repo sync -c --force-sync --no-clone-bundle --no-tags "$path" < /dev/null || return 1
    done
    mv /tmp/heads.new /tmp/heads.old
}

# Projects dropped from the CI manifest after the tree was synced still sit on disk.
for path in $(sed -n 's/.*<remove-project path="\([^"]*\)".*/\1/p' "$MANIFESTS_DIR/ci/remove_unneeded.xml"); do
    [ -e "$path" ] && { echo "Removing $path (dropped in ci/remove_unneeded.xml)"; rm -rf "$path"; }
done

# Projects added back to the manifest after the tree was synced are missing on disk.
missing=$(repo list --all -p 2>/dev/null | while read -r path; do [ -e "$path" ] || echo "$path"; done)
if [ -n "$missing" ]; then
    echo "Syncing missing projects:" $missing
    repo sync -c --force-sync --no-clone-bundle --no-tags $missing < /dev/null
fi

[ -f /tmp/heads.old ] || project_heads > /tmp/heads.old
attempt=${ATTEMPT:-1}
while :; do
    left=$(minutes_left)
    [ "$left" -gt 5 ] || { rc=124; break; }
    echo "=== Attempt $attempt, building for at most ${left}m"
    (
        set +u  # envsetup.sh is not nounset-clean
        # Emulator/cuttlefish host tools reference prebuilts dropped in ci/remove_unneeded.xml.
        export ALLOW_MISSING_DEPENDENCIES=true
        source build/envsetup.sh
        breakfast "$DEVICE" "$VARIANT" || exit 1
        timeout --signal=INT --kill-after=2m "${left}m" m "$TARGET" -j"$(nproc)"
    ) 2>&1 | tee /build/build.log
    rc=${PIPESTATUS[0]}
    df -h /build | tail -1
    [ "$rc" = 0 ] && { publish_status "$attempt" 0 success; break; }
    if [ "$rc" = 124 ] || [ "$rc" = 130 ]; then
        echo "::warning::Build stopped at the time budget. ccache is saved; re-run the workflow to continue."
        break
    fi
    cp /build/build.log "/build/build-attempt$attempt.log"
    if [ "$WAIT_FOR_FIX" != true ]; then publish_status "$attempt" "$rc" failed; break; fi
    publish_status "$attempt" "$rc" waiting-for-fix
    head=$(manifest_head)
    wait_for_fix "$head" || break
    resync_changed || { publish_status "$attempt" "$rc" resync-failed; break; }
    attempt=$((attempt + 1))
    publish_status "$attempt" "" building
    # Continue with the freshly pushed version of this script.
    cp "$MANIFESTS_DIR/ci/build.sh" "/build/ci-build-$attempt.sh"
    ATTEMPT=$attempt exec "/build/ci-build-$attempt.sh"
done
exit "$rc"
