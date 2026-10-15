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

project_heads > /tmp/heads.old
attempt=1
while :; do
    left=$(minutes_left)
    [ "$left" -gt 5 ] || { rc=124; break; }
    echo "=== Attempt $attempt, building for at most ${left}m"
    (
        source build/envsetup.sh
        breakfast "$DEVICE" "$VARIANT" || exit 1
        timeout --signal=INT --kill-after=2m "${left}m" m "$TARGET" -j"$(nproc)"
    ) 2>&1 | tee /build/build.log
    rc=${PIPESTATUS[0]}
    df -h /build | tail -1
    [ "$rc" = 0 ] && break
    if [ "$rc" = 124 ] || [ "$rc" = 130 ]; then
        echo "::warning::Build stopped at the time budget. ccache is saved; re-run the workflow to continue."
        break
    fi
    cp /build/build.log "/build/build-attempt$attempt.log"
    [ "$WAIT_FOR_FIX" = true ] || break
    head=$(manifest_head)
    wait_for_fix "$head" || break
    resync_changed || break
    attempt=$((attempt + 1))
done
exit "$rc"
