# Security

This repository configures one person's home server. It is published as an example; it is not
a product, and there is no support or bug bounty. Reports are still very welcome.

## Reporting a problem

Please report privately, not in a public issue:

- GitHub's **private vulnerability reporting** on this repository (Security → Report a
  vulnerability), or
- e-mail to **contact@arbikullakshi.com**, with "security" in the subject.

Say what you found, where (file and line, or the behaviour you saw), and how to reproduce it.
You should get an answer within a week; a fix for a real problem on the running server comes
first, and the write-up after. Please give a reasonable time to fix before you publish, and do
not test against the live server or its sites beyond what is needed to show the problem; never
try to read other people's data.

## In scope

- Anything in this repository that would let someone reach the server, its containers or its
  data other than the intended ways: the firewall and Tailscale-only SSH, the forced-command
  release path (`infra-deploy-gate`, `infra-apply`, `infra-compose-guard`), the bundle and its
  checks, Home's power requests (`home-power`), the backup script, the edge and tunnel
  configuration, and the down-page Worker.
- A secret, credential or private value committed to this repository or its history.
- The GitHub workflows (for example, anything that could expose the `production` Environment).

Out of scope here: the apps themselves (report those to their own repositories, such as
[home](https://github.com/somethim-home/home) and
[home-crypto](https://github.com/somethim-home/home-crypto)), third-party software the server
runs (report upstream), and Cloudflare's or Tailscale's own services.

## Settings a public copy needs

The workflows are safe to run in a public repository only with these settings, which live in
GitHub rather than in the files:

- **The `production` Environment** holds every secret. Restrict its deployment branches to
  `master` and require a reviewer (the owner) before a job may use it. The Deploy workflow also
  refuses any ref but `master`, but the Environment rule is what keeps the secrets out of
  anything else.
- **Deploy is `workflow_dispatch` only**: only people with write access can start it. Keep
  the repository's collaborators to the owner.
- **`checks.yml` runs on pull requests on GitHub-hosted runners with no secrets** (it renders
  the bundle from `ci/sample-extra-vars.json`, which holds only fake values). Keep it that way:
  never give a `pull_request` job access to the Environment, and do not switch it to
  `pull_request_target`.
- **Never add self-hosted runners to a public repository**: a fork's pull request could run
  code on them. Every job here uses `ubuntu-latest`.
- Set Actions → General → "Fork pull request workflows" to require approval for outside
  contributors.
