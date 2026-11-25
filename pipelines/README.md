# Shared pipeline library

Pipeline pieces the homelab app repositories use by reference, never by copy (#40, [ADR 021](../docs/adr/021-dependency-updates-renovate.md)). A fix here reaches every app at its next run.

## Layout

| Kind | Where | How an app uses it |
|---|---|---|
| Composite action (steps inside a job) | `pipelines/actions/<name>/action.yaml` | `uses: Bemesko/homelab/pipelines/actions/<name>@main` in a step |
| Reusable workflow (whole jobs) | `.github/workflows/lib-<name>.yaml` | `uses: Bemesko/homelab/.github/workflows/lib-<name>.yaml@main` in a job |

GitHub only loads reusable workflows from `.github/workflows/`, without subfolders, so only composite actions can live in this folder. There is no reusable workflow yet.

## Rules

- Callers reference `@main`. `main` only takes pull requests with a green `ci-ok`, but the homelab CI does not run these files: check a change in one app before relying on it, and keep inputs backwards compatible.
- Public repository: no secrets, hostnames or tailnet names. Credentials arrive as inputs from the caller.
- Pin third-party actions by commit SHA.

## Actions

### `dispatch-homelab-update`

Last step of an app's release job: starts the homelab's Renovate workflow, which opens (and automerges) the pull request with the new tag.

```yaml
- name: Update the homelab
  uses: Bemesko/homelab/pipelines/actions/dispatch-homelab-update@main
  with:
    client-id: ${{ vars.HOMELAB_DISPATCH_CLIENT_ID }}
    private-key: ${{ secrets.HOMELAB_DISPATCH_PRIVATE_KEY }}
```

It never fails the release: without the variable it does nothing, and an error is a warning. The daily Renovate run is the fallback. Credentials: [ADR 021](../docs/adr/021-dependency-updates-renovate.md#the-dispatch-app-homelab-dispatch). Organization secrets do not reach private repositories on the Free plan, so a private app needs them in the repository itself.
