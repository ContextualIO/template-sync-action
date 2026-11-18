# Contextual template sync

Keeps a repository created from a template up to date. Each run merges the template's new commits into a branch and opens a pull request for you to review, so the template's changes arrive the same way any other change does.

## Usage

```yaml
on:
  schedule:
    - cron: "0 14 * * *"
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

concurrency: template-sync

jobs:
  template-sync:
    runs-on: ubuntu-latest
    steps:
      - uses: ContextualIO/template-sync-action@v1
        with:
          template-repository: my-org/my-template
```

The action checks out the repository's default branch itself, so the job needs no checkout step.

The repository needs a `.template-sync-ref` file containing the template commit it was created from. Each merged sync updates it. Don't edit or delete it: without it there's nothing to merge against, so the sync stops with an error.

## Inputs

| Input | Default | Description |
|---|---|---|
| `template-repository` | | The template, as `owner/name`. |
| `template-branch` | `main` | The template branch to sync from. |
| `directory` | `.` | The folder holding this repository's copy of the template, relative to the repository root. |
| `organization` | | The Contextual organization whose GitHub connection covers this repository. The sync then uses a token from the organization's GitHub App instead of `token`. Defaults to `CONTEXTUAL_ORGANIZATION` in a `contextual-deploy.env` committed in `directory`, the file [`deploy-workers-action`](https://github.com/ContextualIO/deploy-workers-action) reads. |
| `token` | `github.token` | The token that checks out the repository, pushes the sync branch and opens the pull request, when no `organization` is given. |

The default `github.token` works with three limits: the repository must allow GitHub Actions to create pull requests (Settings → Actions → General), the sync pull requests don't trigger other workflows, and a template change to `.github/workflows/` can't be pushed. A token with the Contents, Pull requests and Workflows permissions removes all three.

With an organization, the job also needs `id-token: write`. The action exchanges the job's GitHub Actions OIDC token for a token from the Contextual GitHub App, limited to this repository and to those three permissions, so none of the limits apply. The repository must be covered by one of the organization's GitHub connections. Outside production, set `CONTEXTUAL_SILO` in the job's environment, or `CONTEXTUAL_CONNECTIONS_URL` to name the connections API directly.

## How a sync works

- **It merges, it doesn't overwrite.** The sync is a three-way merge between the commit in `.template-sync-ref`, the template's branch and your repository, so your own edits to template files survive.
- **Conflicts arrive as a draft pull request.** When you and the template changed the same lines, the conflict markers are committed on the sync branch, and the pull request lists each conflict with a prompt you can give an AI assistant to resolve them.
- **One sync pull request at a time.** If the template moves again, the open pull request is updated in place. Once you have pushed commits to it, such as conflict resolutions, it's left alone until you merge it.
- **`.templatesyncignore`** lists paths whose template changes you never want, one per line, matched like `.gitignore`.
- **Custom merge drivers.** A `.gitattributes` entry `merge=<name>` uses `bin/merge/<name>.ts`, run with Node.js, to merge that file.
- **Changesets.** In a repository with a `.changeset/` directory, a sync that changes anything adds a patch changeset, and changesets from the template itself are removed.
- **Template notes.** New entries in the template's `TEMPLATE_CHANGELOG.md` are copied into the pull request description.

## A template in a folder

In a repository that holds several projects, such as a monorepo, set `directory` to the folder created from the template. The sync then merges the template's changes into that folder only:

- `.template-sync-ref`, `.templatesyncignore`, `.gitattributes`, `bin/merge/` and `contextual-deploy.env` are read from the folder, and `.templatesyncignore` paths are relative to it.
- The changeset goes in the repository's root `.changeset/`, for the package in the folder's `package.json`. Changesets from the template are removed from the folder.
- The sync branch and pull request name the folder, so each folder gets its own sync pull request.

Keep every template file in the folder, including ones that only matter at a repository root, such as `.github/`. A template change to a file the folder doesn't have conflicts.

To sync several folders, run one job per folder:

```yaml
jobs:
  template-sync:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        directory: [sites/marketing, sites/docs]
    concurrency: template-sync-${{ matrix.directory }}
    steps:
      - uses: ContextualIO/template-sync-action@v1
        with:
          template-repository: my-org/my-template
          directory: ${{ matrix.directory }}
```

## License

[MIT](LICENSE)
