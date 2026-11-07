#!/usr/bin/env bash
set -Eeuo pipefail

readonly TARGET_BRANCH="zectrix"
readonly UPSTREAM_REMOTE="upstream"
readonly UPSTREAM_REPOSITORY="https://github.com/usetrmnl/trmnl-firmware.git"
readonly REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
readonly GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:?GH_TOKEN or GITHUB_TOKEN is required}}"

log() {
	printf '::notice::%s\n' "$*"
}

fail() {
	printf '::error::%s\n' "$*" >&2
	exit 1
}

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
	git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_REPOSITORY"
fi
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git fetch --no-tags origin "+refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}"
git fetch "$UPSTREAM_REMOTE" \
	"+refs/heads/main:refs/remotes/${UPSTREAM_REMOTE}/main" \
	--tags

readonly START_ZECTRIX_SHA="$(git rev-parse "refs/remotes/origin/${TARGET_BRANCH}")"
readonly UPSTREAM_MAIN_SHA="$(git rev-parse "refs/remotes/${UPSTREAM_REMOTE}/main")"

sync_mainline() {
	local candidate_branch upstream_short conflict_branch open_pr body_file path
	local -a rebase_conflicts merge_conflicts all_conflicts
	local -A seen_conflicts=()
	upstream_short="${UPSTREAM_MAIN_SHA:0:12}"
	candidate_branch="automation/rebase-upstream-${upstream_short}"
	git switch --detach "$START_ZECTRIX_SHA"
	git switch --create "$candidate_branch"

	if git -c rebase.updateRefs=false rebase "$UPSTREAM_MAIN_SHA"; then
		log "Rebase onto upstream/main succeeded; building Note 4C before updating ${TARGET_BRANCH}."
		INCLUDE_GIT_HASH_IN_VERSION_NUMBER=true pio run -e zectrix_note4c
		git push origin \
			"--force-with-lease=refs/heads/${TARGET_BRANCH}:${START_ZECTRIX_SHA}" \
			"HEAD:refs/heads/${TARGET_BRANCH}"
		return
	fi

	mapfile -d '' -t rebase_conflicts < <(git diff --name-only --diff-filter=U -z)
	git rebase --abort
	if ((${#rebase_conflicts[@]} == 0)); then
		fail "Rebase failed without a merge conflict; refusing to create a fallback branch."
	fi

	open_pr="$(gh pr list --repo "$REPOSITORY" --base "$TARGET_BRANCH" --state open \
		--json headRefName,url \
		--jq '.[] | select(.headRefName | startswith("automation/upstream-conflict-")) | .url' \
		| head -n 1)"
	if [[ -n "$open_pr" ]]; then
		gh pr comment "$open_pr" --repo "$REPOSITORY" --body \
			"A newer weekly sync found upstream/main at \`${UPSTREAM_MAIN_SHA}\`. This run left the existing PR branch untouched to preserve local conflict-resolution work."
		log "An upstream conflict PR is already open ($open_pr); left it and its branch unchanged."
		return
	fi

	conflict_branch="automation/upstream-conflict-${upstream_short}"
	git switch --detach "$START_ZECTRIX_SHA"
	git switch --create "$conflict_branch"
	if git merge --no-commit --no-ff "$UPSTREAM_MAIN_SHA"; then
		merge_conflicts=()
	else
		mapfile -d '' -t merge_conflicts < <(git diff --name-only --diff-filter=U -z)
	fi
	for path in "${rebase_conflicts[@]}" "${merge_conflicts[@]}"; do
		if [[ -z "${seen_conflicts[$path]+x}" ]]; then
			all_conflicts+=("$path")
			seen_conflicts["$path"]=1
		fi
	done

	# Keep upstream's version for every path that conflicted in the rebase,
	# even if the fallback merge happens to apply that path without conflict.
	# The original Zectrix branch remains untouched for local reconciliation.
	for path in "${all_conflicts[@]}"; do
		if git cat-file -e "${UPSTREAM_MAIN_SHA}:${path}" 2>/dev/null; then
			git restore --source="$UPSTREAM_MAIN_SHA" --staged --worktree -- "$path"
		else
			# The upstream side deleted the path.
			git rm -f --ignore-unmatch -- "$path"
		fi
	done
	if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
		fail "The fallback merge still has unresolved paths."
	fi
	git -c user.name="github-actions[bot]" \
		-c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
		commit -m "Merge upstream/main; defer Zectrix conflict paths"
	git push origin "HEAD:refs/heads/${conflict_branch}"

	body_file="$(mktemp)"
	{
		cat <<EOF
The weekly rebase of Zectrix commit \`${START_ZECTRIX_SHA}\` onto
upstream/main \`${UPSTREAM_MAIN_SHA}\` conflicted. This draft branch preserves
both histories and uses the upstream version for the conflict paths listed
below. The original \`${TARGET_BRANCH}\` branch was not modified.

Resolve each path locally by comparing the pre-sync Zectrix version with the
upstream version. See \`AGENTS.md\` in the branch for the resolution procedure.

Conflicted paths:
EOF
		printf -- '- `%s`\n' "${all_conflicts[@]}"
		cat <<'EOF'

Do not merge until the Zectrix behavior has been restored and reviewed. Keep
the upstream commits and this merge commit; add focused resolution commits.
EOF
	} >"$body_file"
	gh pr create --repo "$REPOSITORY" --draft --base "$TARGET_BRANCH" \
		--head "$conflict_branch" \
		--title "Sync upstream/main into Zectrix (resolve conflicts)" \
		--body-file "$body_file"
	rm -f "$body_file"
	log "Opened a draft conflict-resolution PR; the existing ${TARGET_BRANCH} branch was left untouched."
}

release_latest_upstream_tag() {
	local upstream_tag release_tag release_worktree release_sha release_ref existing_tag
	local patches patch patch_list ota_asset flash_asset notes_file

	upstream_tag="$(gh api repos/usetrmnl/trmnl-firmware/releases/latest --jq '.tag_name')"
	if [[ -z "$upstream_tag" || "$upstream_tag" == "null" ]]; then
		log "No published stable upstream release tag was found."
		return
	fi
	release_tag="${upstream_tag}-zectrix4c"
	if gh release view "$release_tag" --repo "$REPOSITORY" >/dev/null 2>&1; then
		log "Release ${release_tag} already exists; no duplicate release will be published."
		return
	fi

	git fetch "$UPSTREAM_REMOTE" "refs/tags/${upstream_tag}:refs/tags/${upstream_tag}"
	existing_tag="$(git ls-remote --refs origin "refs/tags/${release_tag}" | awk 'NR == 1 {print $1}')"
	if [[ -n "$existing_tag" ]]; then
		git fetch origin "refs/tags/${release_tag}:refs/tags/${release_tag}"
		release_ref="refs/tags/${release_tag}"
		log "Found tag ${release_tag} without a GitHub Release; rebuilding its exact commit for recovery."
	else
		git fetch origin "+refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}"
		mapfile -t patches < <(git rev-list --reverse --no-merges \
			"${UPSTREAM_MAIN_SHA}..refs/remotes/origin/${TARGET_BRANCH}")
		if ((${#patches[@]} == 0)); then
			fail "No Zectrix-only commits were found between upstream/main and ${TARGET_BRANCH}; refusing to publish an uncustomized image."
		fi

		release_worktree="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/zectrix-release.XXXXXX")"
		rmdir "$release_worktree"
		git worktree add --detach "$release_worktree" "refs/tags/${upstream_tag}"
		for patch in "${patches[@]}"; do
			if ! git -C "$release_worktree" cherry-pick "$patch"; then
				git -C "$release_worktree" cherry-pick --abort || true
				git worktree remove --force "$release_worktree"
				fail "Zectrix commit ${patch} does not apply cleanly to upstream release ${upstream_tag}; no release was published."
			fi
		done
		release_ref="$(git -C "$release_worktree" rev-parse HEAD)"
	fi

	if [[ -z "${release_worktree:-}" ]]; then
		release_worktree="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/zectrix-release.XXXXXX")"
		rmdir "$release_worktree"
		git worktree add --detach "$release_worktree" "$release_ref"
	fi

	if ! (cd "$release_worktree" && INCLUDE_GIT_HASH_IN_VERSION_NUMBER=true pio run -e zectrix_note4c); then
		git worktree remove --force "$release_worktree"
		fail "Note 4C build failed for ${release_tag}; no release was published."
	fi
	release_sha="$(git -C "$release_worktree" rev-parse HEAD)"
	ota_asset="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/zectrix4c-${release_tag}-ota.bin"
	flash_asset="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/zectrix4c-${release_tag}-flash.bin"
	cp "$release_worktree/.pio/build/zectrix_note4c/firmware.bin" "$ota_asset"
	cp "$release_worktree/.pio/build/zectrix_note4c/merged_firmware.bin" "$flash_asset"
	git worktree remove --force "$release_worktree"

	if [[ -z "$existing_tag" ]]; then
		git tag "$release_tag" "$release_sha"
		if ! git push origin "refs/tags/${release_tag}"; then
			git tag -d "$release_tag" >/dev/null 2>&1 || true
			fail "Could not publish release tag ${release_tag}; no GitHub Release was created."
		fi
	fi

	patch_list="$(git rev-list --reverse --no-merges \
		"${UPSTREAM_MAIN_SHA}..refs/remotes/origin/${TARGET_BRANCH}" | sed 's/^/- `/; s/$/`/')"
	notes_file="$(mktemp)"
	cat >"$notes_file" <<EOF
ZecTrix Note 4C firmware based on upstream release [${upstream_tag}](https://github.com/usetrmnl/trmnl-firmware/releases/tag/${upstream_tag}).

- Upstream release tag: \`${upstream_tag}\`
- Release source commit: \`${release_sha}\`
- Zectrix-specific commits replayed from the fork:
${patch_list}

Assets:
- OTA/application image preserves device settings.
- Merged flash image starts at flash offset 0.
EOF
	gh release create "$release_tag" "$ota_asset" "$flash_asset" \
		--repo "$REPOSITORY" \
		--title "ZecTrix Note 4C ${release_tag}" \
		--notes-file "$notes_file"
	rm -f "$notes_file" "$ota_asset" "$flash_asset"
	log "Published ${release_tag} from upstream release ${upstream_tag}."
}

case "${1:-all}" in
	sync)
	sync_mainline
	;;
	release)
	release_latest_upstream_tag
	;;
	all)
	sync_mainline
	release_latest_upstream_tag
	;;
	*)
	fail "Usage: $0 [sync|release|all]"
	;;
esac
