#!/usr/bin/env bash

set -e

sync_ref_file=".template-sync-ref"
TEMPLATE_NAME=${TEMPLATE_REPOSITORY#*/}

gh auth setup-git

git config user.name ContextualDevOps
git config user.email devops@contextual.io
git config merge.ours.driver true

# Load custom `merge=<name>` attribute drivers.
for driver in bin/merge/*.ts; do
  [ -e "${driver}" ] || continue
  git config "merge.$(basename "${driver}" .ts).driver" "node ${driver} %O %A %B"
done

# Load .templatesyncignore entries.
if [ -f .templatesyncignore ]; then
  # Normalize entries: strip whitespace and trailing slashes, anchor "./" to the repo root, and
  # cover both files and dirs.
  awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); sub(/\/+$/, ""); sub(/^\.\//, "/") }
       !/^#/ && NF { print $0 " merge=ours"; print $0 "/** merge=ours" }' \
    .templatesyncignore >> "$(git rev-parse --git-dir)/info/attributes"
fi

# Fetch the remote template and pin the commit this run will sync to.
git fetch --no-tags "https://github.com/${TEMPLATE_REPOSITORY}.git" "${TEMPLATE_BRANCH}"
template_head=$(git rev-parse FETCH_HEAD)
template_head_short=$(git rev-parse --short FETCH_HEAD)

# Without a record of the last sync there is no base to merge against.
if [ ! -f "${sync_ref_file}" ]; then
  echo "${sync_ref_file} file is missing. Cannot sync with template." >&2
  exit 1
fi

last_sync_commit=$(cat "${sync_ref_file}")

template_version () {
  git show "$1:package.json" | node -p "JSON.parse(require('fs').readFileSync(0, 'utf8')).version"
}

# Template changelog entries newer than any this repository already has.
template_changelog_entries () {
  local seen
  seen=$(git show "$1:TEMPLATE_CHANGELOG.md" 2>/dev/null | grep '^## ' || true)
  git show "$2:TEMPLATE_CHANGELOG.md" 2>/dev/null | SEEN="${seen}" awk '
    BEGIN { n = split(ENVIRON["SEEN"], headings, "\n"); for (i = 1; i <= n; i++) seen[headings[i]] = 1 }
    /^## / { if ($0 in seen) exit; found = 1 }
    found'
}

# The PR description's conflict section: a prompt for resolving it with an AI assistant, each
# conflicted file with links to its conflicts, and what the template changed in each file.
conflict_report () {
  local commit=$1 files=$2 url="https://github.com/${GITHUB_REPOSITORY}/blob/$1"
  local path start end links change list="" changes=""
  while IFS= read -r path; do
    links=""
    while read -r start end; do
      links+="${links:+, }[lines ${start}–${end}](${url}/${path}#L${start}-L${end})"
    done < <(git show "${commit}:${path}" 2>/dev/null \
      | awk '/^<<<<<<< / { start = NR } /^>>>>>>> / && start { print start, NR; start = 0 }')
    list+=$'\n'"- [\`${path}\`](${url}/${path}): ${links:-no conflict markers (a binary file, or one side edited it and the other deleted it), so check which version this branch kept}"
    case "${path}" in
      yarn.lock | package-lock.json | pnpm-lock.yaml)
        list+=". Resolve \`package.json\` first, then regenerate this file by installing dependencies instead of editing the markers."
        continue
        ;;
    esac
    change=$(git diff "${last_sync_commit}" "${template_head}" -- "${path}")
    if [ -n "${change}" ] && [ "$(wc -l <<< "${change}")" -le 150 ] && [ "${#changes}" -lt 30000 ]; then
      changes+=$'\n\n'"<details><summary>What the template changed in <code>${path}</code></summary>"$'\n\n````diff\n'"${change}"$'\n````\n\n</details>'
    fi
  done <<< "${files}"

  echo "> [!WARNING]"
  echo "> This sync could not be merged cleanly. Resolve the conflict markers in the files below on this branch before merging. In each conflict, the part after \`<<<<<<<\` is this repository's version and the part between \`=======\` and \`>>>>>>>\` is the template's new version."
  echo
  echo "To have an AI assistant resolve it, give it this prompt:"
  echo
  echo '````text'
  cat <<EOF
Resolve the merge conflicts in a template sync.

The repository https://github.com/${GITHUB_REPOSITORY} is built from the ${TEMPLATE_NAME} template. Its branch ${branch} merges ${TEMPLATE_NAME} @ ${template_head_short} into the repository, and the merge left conflict markers committed in these files:
$(sed 's/^/- /' <<< "${files}")

In each conflict, the part after <<<<<<< is this repository's version and the part between ======= and >>>>>>> is the template's new version.

1. Clone the repository if needed, then check out the branch: git fetch origin ${branch} && git switch ${branch}
2. For each conflicted file, see what the template changed: git diff ${last_sync_commit:0:7} ${template_head_short} -- <file>
3. Resolve every conflict so the file keeps this repository's own changes and also applies the template's change. Only drop one side's change when the other side clearly replaces it, and tell me when you do.
4. If package.json conflicts, keep this repository's own dependencies and scripts while taking the template's updates. Never hand-edit a lockfile: once package.json is resolved, regenerate it by installing dependencies.
5. Read the new entries at the top of TEMPLATE_CHANGELOG.md, if it has them, and follow any instructions in them.
6. Check that no conflict markers remain (git grep -nE '^(<<<<<<<|>>>>>>>) '), then install dependencies and run the build.
7. Commit the resolution to this branch and push it.
8. Take the pull request out of draft so it can be reviewed: gh pr ready ${branch}. Don't merge it.
9. Summarize how you resolved each conflict.
EOF
  echo '````'
  echo "${list}${changes}"
}

if git merge-base --is-ancestor "${template_head}" "${last_sync_commit}"; then
  echo "Already up to date with ${TEMPLATE_NAME} @ ${template_head_short}."
  exit 0
fi

# Named for the commit being synced from, so if a sync round is missed the branch name is reused.
branch="template-sync/from-${last_sync_commit:0:7}" # Slice instead of --short to guarantee consistency

# An open sync PR is updated in place below, unless it already carries this template commit or
# someone has pushed commits of their own to it.
pending_pr=$(gh pr list --head "${branch}" --state open --json number --jq '.[0].number // empty')
if [ -n "${pending_pr}" ] && git fetch --no-tags origin "${branch}" 2>/dev/null; then
  if [ "$(git show "FETCH_HEAD:${sync_ref_file}")" = "${template_head}" ]; then
    echo "Sync for ${TEMPLATE_NAME} @ ${template_head_short} is already open in #${pending_pr}."
    exit 0
  fi
  if [ -n "$(git rev-list "$(git log -1 --format=%H --author=ContextualDevOps FETCH_HEAD)..FETCH_HEAD")" ]; then
    echo "#${pending_pr} has commits of its own; merge it before syncing ${TEMPLATE_NAME} @ ${template_head_short}."
    exit 0
  fi
fi

default_head=$(git rev-parse HEAD)

# Land all changes on the sync branch; never on the default branch.
git switch -c "${branch}"

# Only merge changes since the last sync point.
git merge -s ours --allow-unrelated-histories --no-edit \
  -m "chore(template): base on ${TEMPLATE_NAME} @ $(git rev-parse --short "${last_sync_commit}")" "${last_sync_commit}"

pre_sync_tree=$(git rev-parse 'HEAD^{tree}')

# Commit conflict markers when changes cannot be reconciled.
if ! git merge --no-edit -m "chore(template): sync ${TEMPLATE_NAME} template" "${template_head}"; then
  conflicted_files=$(git diff --name-only --diff-filter=U)
  draft_on_conflict=--draft # Conflicted branches land as draft PRs to ensure they're handled.
  git add -A
  git commit -m "chore(template): sync ${TEMPLATE_NAME} template (unresolved conflicts)"
fi

# Changesets the merge brought in are the template's own and would block this repository's releases.
template_changesets=$(comm -13 \
  <(git ls-tree -r --name-only "${pre_sync_tree}" -- .changeset | sort) \
  <(git ls-tree -r --name-only HEAD -- .changeset | grep '\.md$' | grep -v '/README\.md$' | sort))
if [ -n "${template_changesets}" ]; then
  echo "${template_changesets}" | xargs git rm -q --ignore-unmatch --
  git commit -m "chore(template): drop changesets that reference the template"
fi

# Write a changeset file for this sync run so that a versioning PR gets cut, unless the sync changed nothing.
if [ -d .changeset ] && [ "$(git rev-parse 'HEAD^{tree}')" != "${pre_sync_tree}" ]; then
  package_name=$(node -p "require('./package.json').name")
  {
    echo "---"
    echo "\"${package_name}\": patch"
    echo "---"
    echo
    if [ "$(template_version "${last_sync_commit}")" = "$(template_version "${template_head}")" ]; then
      echo "chore(template): sync ${TEMPLATE_NAME} @ ${template_head_short}"
    else
      echo "chore(template): sync ${TEMPLATE_NAME} $(template_version "${last_sync_commit}") → $(template_version "${template_head}")"
    fi
  } > ".changeset/template-sync-${template_head_short}.md"
  git add ".changeset/template-sync-${template_head_short}.md"
  git commit -m "chore(template): add a changeset for the synced changes"
fi

# Update the sync ref file so the next sync can identify this as the base.
echo "${template_head}" > "${sync_ref_file}"
git add "${sync_ref_file}"
git commit -m "chore(template): record ${TEMPLATE_NAME} @ ${template_head_short} as synced"

# Squash the sync into one commit on the default branch, so the template's history stays out of this repository.
title="chore(template): sync ${TEMPLATE_NAME} @ ${template_head_short}"
git reset --soft "${default_head}"
git commit -m "${title}"

# Open a PR with the sync results.
body="Syncs \`${TEMPLATE_NAME}\` @ \`${template_head_short}\`."
if [ -n "${conflicted_files}" ]; then
  body+=$'\n\n'"$(conflict_report "$(git rev-parse HEAD)" "${conflicted_files}")"
fi
changelog_entries=$(template_changelog_entries "${last_sync_commit}" "${template_head}")
if [ -n "${changelog_entries}" ]; then
  body+=$'\n\n'"What changed in the template, from \`TEMPLATE_CHANGELOG.md\`. Follow any instructions before merging."$'\n\n'"${changelog_entries}"
fi

git push --force -u origin "${branch}"
if [ -z "${pending_pr}" ]; then
  gh pr create ${draft_on_conflict} --base "${DEFAULT_BRANCH}" --head "${branch}" --title "${title}" --body "${body}"
else
  gh pr edit "${pending_pr}" --title "${title}" --body "${body}"
  is_draft=$(gh pr view "${pending_pr}" --json isDraft --jq .isDraft)
  if [ -n "${draft_on_conflict}" ] && [ "${is_draft}" = false ]; then
    gh pr ready "${pending_pr}" --undo
  elif [ -z "${draft_on_conflict}" ] && [ "${is_draft}" = true ]; then
    gh pr ready "${pending_pr}"
  fi
fi
