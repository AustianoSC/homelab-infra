# Phase 5: Dependency updates with Renovate

Goal: every pinned version in this repo is watched, and a new release arrives as
a pull request that says what merging it does. "Done" means Renovate opens PRs
for the Helm charts, k3s, the Palworld image, the OpenTofu providers, the
Ansible collections, the CI actions and the pre-commit hooks; changes that only
affect CI merge themselves once CI passes; and everything that touches the
cluster waits for you.

This phase doesn't depend on phase 4 and touches neither the router nor the
cluster, so it can be done before it or alongside it. It comes before
observability on purpose: that phase adds more charts, and they should be
tracked from the day they land.

## Decisions

| Topic | Decision | Why |
| --- | --- | --- |
| Tool | Renovate, not Dependabot | Dependabot doesn't read chart versions in Argo CD `Application`s, and has no way to track a version in a Makefile or an Ansible variable. Both are where most of this repo's versions are |
| Where it runs | The hosted Mend Renovate GitHub App, installed on this repo only | Free, nothing to run or update, no token to look after. Running it in the cluster would add nothing but a failure mode: no update PRs while the cluster is down |
| Config | `.github/renovate.json5` | JSON5 allows comments, like every other config file in this repo |
| Schedule | Saturday before 6am, Pacific | One batch a week, ready to review when you're free to watch a deploy. Security fixes ignore the schedule |
| New releases | Wait 3 days (`minimumReleaseAge`) | A broken release is usually pulled or patched within days |
| Major versions | Only when ticked in the Dependency Dashboard | Majors need reading release notes first; they shouldn't open PRs on their own |
| Auto-merge | Only for files under `.github/`, `.pre-commit-config.yaml` and `scripts/requirements.txt`, minor and patch only | They change CI and local tooling, never the cluster, and CI tests them |
| Everything else | Manual merge, labelled `deploys-on-merge` or `needs-make` | Merging a `kubernetes/` change deploys it within minutes. k3s, the Argo CD chart, providers and collections do nothing until a `make` target runs |
| Not tracked | The Ubuntu cloud image, kubeconform, `python-version` in CI | Each is pinned with a checksum or by date that Renovate can't recompute. Checked by hand (see Notes) |
| Argo CD Image Updater | Not used | Renovate already proposes new image tags as PRs, so every deploy stays a commit in Git |

## What changes in the repo

| Path | Change |
| --- | --- |
| `.github/renovate.json5` | New: the config below |
| `Makefile` | A `# renovate:` comment above `ARGOCD_CHART_VERSION` |
| `ansible/inventory/group_vars/all.yml` | A `# renovate:` comment above `k3s_version` |
| `ansible/requirements.yml` | Collections pinned to exact versions instead of `>=` |
| `.github/workflows/lint.yml` | `# renovate:` comments for `tofu_version` and ansible-lint (moved into an `env` variable) |
| `.pre-commit-config.yaml` | New hook: `renovate-config-validator` |
| `kubernetes/infra/metallb/README.md` | The chart version line removed; the Application is the one place it's set |
| `docs/adr/0010-renovate-for-dependency-updates.md` | New: the decisions above |
| `README.md`, `docs/bootstrap.md` | How updates arrive, what the labels mean; installing the app as a one-time setup step |

## Part 1: Get the repo ready

- [ ] **1. Mark the versions Renovate can't find by itself.** Renovate
  understands Helm charts in Argo CD Applications, container images,
  providers, collections, Actions and pre-commit hooks without help. The
  versions in plain variables need a comment on the line directly above,
  which the custom manager in step 4 reads.

  `Makefile`:
  ```make
  # renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm
  ARGOCD_CHART_VERSION := 10.11.1
  ```
  `scripts/validate_k8s.py` reads this variable with a regex anchored on
  `ARGOCD_CHART_VERSION`, so the extra comment line doesn't affect it.

  `ansible/inventory/group_vars/all.yml`:
  ```yaml
  # renovate: datasource=github-releases depName=k3s-io/k3s
  k3s_version: v1.36.5+k3s1
  ```

  `.github/workflows/lint.yml`: the OpenTofu version gets a comment, and
  ansible-lint moves from the `run` line into a variable so it can have one:
  ```yaml
        - uses: opentofu/setup-opentofu@... # v2.0.2
          with:
            # renovate: datasource=github-releases depName=opentofu/opentofu
            tofu_version: 1.13.1
  ```
  ```yaml
        - name: Install ansible-lint and collections
          env:
            # renovate: datasource=pypi depName=ansible-lint
            ANSIBLE_LINT_VERSION: 26.10.0
          run: |
            pip install "ansible-lint==${ANSIBLE_LINT_VERSION}"
            ansible-galaxy collection install -r ansible/requirements.yml
  ```

- [ ] **2. Pin the Ansible collections.** `>=1.6.0` installs whatever is
  newest on the day, so two runs of `make cluster` can use different code, and
  Renovate has nothing to bump. Pin each to the version installed now
  (`ansible-galaxy collection list ansible.posix community.general`):
  ```yaml
  collections:
    - name: ansible.posix
      version: "2.1.0"        # the version listed, not this placeholder
    - name: community.general
      version: "13.5.0"
  ```

- [ ] **3. Drop the second copy of the MetalLB version.** Delete the
  `Chart version: **0.16.1**` line from `kubernetes/infra/metallb/README.md`
  and leave the sentence that says the version is `targetRevision` in the
  Application. Otherwise every MetalLB PR leaves the README out of date.

- [ ] **4. Write `.github/renovate.json5`.**
  ```json5
  // Dependency updates. Run by the hosted Mend Renovate GitHub App; see
  // docs/adr/0010-renovate-for-dependency-updates.md.
  {
    $schema: "https://docs.renovatebot.com/renovate-schema.json",
    extends: [
      "config:recommended",
      "helpers:pinGitHubActionDigests",
      ":semanticCommits",
    ],
    timezone: "America/Los_Angeles",
    schedule: ["* 0-5 * * 6"],
    minimumReleaseAge: "3 days",
    // The old Docker Compose Palworld, kept only until VM 200 is retired.
    ignorePaths: ["apps/**"],
    major: { dependencyDashboardApproval: true },

    "pre-commit": { enabled: true },
    argocd: { managerFilePatterns: ["/^kubernetes/argocd/applications/.+\\.yaml$/"] },
    kubernetes: { managerFilePatterns: ["/^kubernetes/apps/.+\\.yaml$/"] },

    customManagers: [
      {
        customType: "regex",
        description: "Versions with a `# renovate:` comment on the line above",
        managerFilePatterns: [
          "/^Makefile$/",
          "/^ansible/inventory/group_vars/all\\.yml$/",
          "/^\\.github/workflows/.+\\.ya?ml$/",
        ],
        matchStrings: [
          "# renovate: datasource=(?<datasource>\\S+) depName=(?<depName>\\S+)(?: registryUrl=(?<registryUrl>\\S+))?\\s*\\n\\s*\\S+\\s*:?=?\\s*\"?(?<currentValue>[^\"\\s]+)\"?",
        ],
      },
    ],

    packageRules: [
      {
        description: "required_version is checked by OpenTofu, not a Terraform release to track",
        matchManagers: ["terraform"],
        matchDepTypes: ["required_version"],
        enabled: false,
      },
      {
        description: "Rewrite `~> 0.116` to the new minor, so the lock file moves with it",
        matchManagers: ["terraform"],
        matchDepTypes: ["required_provider"],
        rangeStrategy: "bump",
        addLabels: ["needs-make"],
        prBodyNotes: ["After merging, run `make plan`: it should show no changes to the VMs."],
      },
      {
        description: "k3s tags look like v1.36.5+k3s1; one PR per minor, never a jump",
        matchDepNames: ["k3s-io/k3s"],
        versioning: "regex:^v(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)\\+k3s(?<build>\\d+)$",
        separateMultipleMinor: true,
        addLabels: ["needs-make"],
        prBodyNotes: [
          "Merging changes nothing on the cluster. Take an etcd snapshot (`sudo k3s etcd-snapshot save` on k3s-cp-1), then run `make cluster`: it upgrades the server, then the agents. Upgrade one minor version at a time.",
        ],
      },
      {
        description: "Tags are v1.13.1; CI wants 1.13.1",
        matchDepNames: ["opentofu/opentofu"],
        extractVersion: "^v(?<version>.+)$",
      },
      {
        matchDepNames: ["argo-cd"],
        addLabels: ["needs-make"],
        prBodyNotes: ["Merging changes nothing on the cluster. Run `make argocd` afterwards."],
      },
      {
        matchManagers: ["ansible-galaxy"],
        addLabels: ["needs-make"],
        prBodyNotes: ["Used from the next `make cluster`."],
      },
      {
        description: "Argo CD applies anything under kubernetes/ within minutes of reaching main",
        matchFileNames: ["kubernetes/**"],
        addLabels: ["deploys-on-merge"],
        prBodyNotes: ["Argo CD applies this within minutes of the merge. Check `kubectl -n argocd get applications` afterwards."],
      },
      {
        matchDepNames: ["thijsvanloef/palworld-server-docker"],
        prBodyNotes: ["Restarts the Palworld pod and disconnects players. Merge when nobody is online."],
      },
      {
        description: "CI and local tooling only: nothing on the cluster changes, and CI tests it",
        matchFileNames: [".github/**", ".pre-commit-config.yaml", "scripts/requirements.txt"],
        matchUpdateTypes: ["minor", "patch", "digest", "pinDigest"],
        groupName: "CI and tooling",
        automerge: true,
      },
    ],
  }
  ```

- [ ] **5. Check the config before it goes live.** Two checks, both with Node
  installed (`brew install node`), neither touching GitHub:

  | Check | Command | Expected |
  | --- | --- | --- |
  | Valid config | `npx --yes --package renovate -- renovate-config-validator .github/renovate.json5` | `Config validated successfully` |
  | What it finds | `LOG_LEVEL=debug npx --yes renovate --platform=local --dry-run=lookup 2>&1 \| tee /tmp/renovate.log` | The dependencies listed below, each with its current version |

  In the log, search for `packageFiles with updates`. It should list:
  MetalLB and External Secrets (`argocd`), the Palworld image
  (`kubernetes`), `argo-cd` and `k3s-io/k3s` and `opentofu/opentofu` and
  `ansible-lint` (`regex`), `bpg/proxmox` and `hashicorp/local`
  (`terraform`), the two collections (`ansible-galaxy`), the Actions
  (`github-actions`), the hooks (`pre-commit`) and `pyyaml`
  (`pip_requirements`). If one is missing, its comment or file pattern is
  wrong. If `k3s-io/k3s` shows `invalid-version`, the `versioning` regex is
  wrong.

  Then add the validator to `.pre-commit-config.yaml` so a broken config
  can't be committed (pin `rev` to the latest tag of
  `renovatebot/pre-commit-hooks`; Renovate keeps it current from then on):
  ```yaml
    - repo: https://github.com/renovatebot/pre-commit-hooks
      rev: <latest tag>
      hooks:
        - id: renovate-config-validator
          args: [--strict]
  ```

- [ ] **6. Commit and push** steps 1 to 5. CI should pass unchanged. The
  ansible-lint and OpenTofu versions are the same, only written differently.

## Part 2: Turn it on

- [ ] **7. Protect `main` so auto-merge waits for CI.** In the repo on GitHub:
  1. Settings, General: tick **Allow auto-merge**.
  2. Settings, Rules, Rulesets: a new branch ruleset for `main`, with
     **Require status checks to pass** listing the four lint jobs
     (`OpenTofu fmt, validate, tflint`, `ansible-lint`,
     `Kubernetes manifests (helm template, kubeconform)`, `gitleaks`). Add the
     **Repository admin** role to the bypass list, so your own pushes to
     `main` keep working as they do now.

  Without this, an auto-merge PR could merge before CI finishes.

- [ ] **8. Install the app.** Install the
  [Renovate GitHub App](https://github.com/apps/renovate) with **Only select
  repositories**: `homelab-infra`. The config is already on `main`, so it
  skips its onboarding PR (if it opens one anyway, close it). Within an hour
  or so:

  | Check | Where | Expected |
  | --- | --- | --- |
  | Dashboard | Issues | A `Dependency Dashboard` issue listing every dependency from step 5 |
  | Runs | [developer.mend.io](https://developer.mend.io), sign in with GitHub | A job per run, with logs. The first place to look when something is missing |
  | Labels | Issues, Labels | `deploys-on-merge` and `needs-make` appear with the first PRs that use them |

  PRs only open in the Saturday window. To get the first round sooner, tick
  the boxes in the dashboard; ticked items ignore the schedule.

  Leave Dependabot **alerts** on (Settings, Advanced Security): Renovate reads
  them and opens security PRs immediately. Don't add a `dependabot.yml`, or
  both tools open PRs for the same thing.

## Part 3: The first round

- [ ] **9. Work through the first PRs, in this order.** The first round is the
  biggest, because nothing has been updated by a tool before.
  1. **CI and tooling** (one grouped PR): merges itself when CI passes. If
     CI fails, read why before re-running; that's the case auto-merge is
     meant to stop.
  2. **Charts** (`deploys-on-merge`), one at a time: read the release notes,
     merge, then check the Application is Synced and Healthy before the next.
     External Secrets: also check `kubectl get clustersecretstore onepassword`
     is still `Valid`.
  3. **Providers** (`needs-make`): check the PR changed
     `infra/.terraform.lock.hcl` as well as the constraint. If it didn't, or CI
     fails on the lock, check out the branch and run
     `cd infra && tofu init -upgrade && tofu providers lock -platform=linux_amd64 -platform=darwin_arm64`,
     push, then merge and run `make plan` (no changes expected).
  4. **Palworld**: when nobody is online.
  5. **k3s** last, on its own: etcd snapshot, merge, `make cluster`, then
     `kubectl get nodes` shows the new version on all three nodes and every
     Application is Healthy.

- [ ] **10. Docs.** ADR 0010 (the decisions table above). In `README.md`, a
  short "Dependency updates" section: Renovate opens PRs on Saturdays, the
  Dependency Dashboard issue lists everything, and what the two labels mean.
  In `docs/bootstrap.md`, installing the app and the ruleset as one-time
  setup.

## Rolling back

- **A bad update:** revert the merge commit. For anything under
  `kubernetes/`, Argo CD rolls back to the previous chart or image. For
  `needs-make` changes, revert and run the same `make` target.
- **k3s can't be downgraded** by changing the version back. Restore the
  snapshot taken before the upgrade
  ([k3s etcd-snapshot](https://docs.k3s.io/cli/etcd-snapshot)), or rebuild.
  This is why that PR asks for a snapshot first.
- **Renovate itself:** add `enabled: false` to the config to pause it, or
  uninstall the app. Nothing on the cluster depends on it.

## Notes

- **Checked by hand,** every few months: the Ubuntu cloud image in
  `infra/image.tf` (dated URL plus checksum), kubeconform in `lint.yml`
  (version plus sha256 of the tarball) and `python-version` in CI. A new
  cloud image only matters for VMs created after the change.
- **Argo CD doesn't manage itself.** Its chart is installed by `make argocd`,
  which is why its PR is `needs-make`. Moving Argo CD into its own Application
  would make it `deploys-on-merge` like the other charts; a separate change
  if it's ever worth it.
- **Personal projects later:** an app image added under `kubernetes/apps/` is
  picked up by the `kubernetes` manager with no config change, so a new tag
  becomes a PR. That covers what Argo CD Image Updater would do, with a commit
  per deploy. A private GHCR image needs a `hostRules` entry with a read-only
  token, stored as a secret in the Mend developer portal, not in the repo.
- **Self-hosting** (a CronJob in the cluster, with a GitHub App key through
  External Secrets) is possible later as a portfolio exercise. It gains
  nothing over the hosted app here, and stops when the cluster does.
- **Noise:** if a week brings too many PRs, group the charts as well
  (`groupName` on the `kubernetes/**` rule), or move the schedule to monthly.

## After phase 5

1. Observability (VictoriaMetrics and Grafana), phase 6. Its charts get
   Renovate PRs from the start.
2. Nice to have: off-host backups of the Palworld volume, and Reloader.
