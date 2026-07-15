# One-shot scripts — build the bundle, then run everything

Two helper scripts that automate the full [QUICKSTART.md](./QUICKSTART.md) procedure.
They exist for convenience and repeatability; the guide remains the source of truth and
the *why* behind each step. Because of the air gap between the internet laptop and the
offline jump server, this is **two scripts with one manual copy in between** — a single
process cannot cross that gap.

> ⚠️ **Test these in a lab first** (see [LAB.md](./LAB.md)) before using them with a
> customer. They are read-only against the SAP servers, but you want to see the prompts
> and output on a throwaway environment first.

## 1. `build-bundle.sh` — on the operator laptop (internet, Linux)

Fully automatic; no customer-specific input. It creates a build venv, clones the
framework + tools, downloads the wheels (pinned to `ansible-core<2.17` so nothing is
installed on the SAP servers), downloads the Ansible collections, optionally fetches the
jump-server RPMs (on a RHEL host), and packs everything into `sapqa-offline-bundle.tar.gz`
with a SHA-256.

```bash
./build-bundle.sh
# then copy the bundle AND the runner to the jump server:
scp ~/sapqa-offline/sapqa-offline-bundle.tar.gz \
    ~/sapqa-offline/setup-and-run.sh <user>@<jump-server>:~/
```

For convenience the build also drops a copy of `setup-and-run.sh` and
`answers.env.example` **next to** the bundle in the output folder, so you can transfer
the runner without first extracting it from `tools.tar.gz` inside the bundle.

Common overrides (environment variables): `WORKDIR`, `TARGET_PYVER`, `TARGET_PLATFORM`,
`ANSIBLE_CORE_CONSTRAINT`.

> **Needs podman or docker (for the jump's python3.11 RPMs).** A fresh RHEL 9 jump ships
> only python3.9, but ansible-core 2.16 needs a ≥3.10 control interpreter, so the jump
> needs python3.11 — which an offline jump can't install itself. `build-bundle.sh` fetches
> the python3.11 RPMs into the bundle using a **UBI9 container** (Red Hat's free base image;
> no subscription needed). So the build machine needs `podman` or `docker` (on a RHEL host
> it falls back to host `dnf`). If neither is present, `jump_rpms/` comes out empty and
> `setup-and-run.sh` will stop at "python3.11 not present" — install one (`sudo apt-get
> install -y podman`) and re-build. On WSL/Ubuntu, podman works well.

## 2. `setup-and-run.sh` — on the jump server (offline)

Asks for the customer-specific inputs up front, then does everything else automatically:
offline install (Step 4), workspace generation (Step 6), `vars.yaml` (Step 7a), an SSH
connectivity check, the run (Step 8), and a report summary with the offline scope note
(Step 9). It shows a summary and asks for confirmation before it generates anything.

```bash
# interactive:
./setup-and-run.sh

# non-interactive (recommended for a security review of the inputs, and for repeats):
cp answers.env.example answers.env    # fill it in
./setup-and-run.sh --answers answers.env
```

What it asks (interactive) / reads (answers file): SID, workspace name, SSH user, the SAP
servers (`tier:hostname:ip`), the credential method, and whether the jump can reach Azure.

**Credentials — two modes, matching QUICKSTART 6.4:**

- `agent` (default, recommended): uses `ssh-agent`, **no key file on disk**. Load the key
  first: `eval "$(ssh-agent -s)"; ssh-add <key>`. The script runs the playbook directly.
- `keyfile`: you give a path; the script copies it into the workspace as `ssh_key.ppk`
  (`chmod 600`) and uses the wrapper. Consider `shred -u` afterwards.

**Flags:** `--answers <file>`, `--reinstall` (rebuild the offline install), `--yes`
(skip confirmations), `-h`.

**Safety notes:** the script never asks for or stores a password; the checks are
read-only; re-running is safe (idempotent — proven in the lab). Azure-collector checks
stay `N/A` offline by design — see the scope note the script prints at the end.

## Typical end-to-end

```
[laptop]  ./build-bundle.sh
[laptop]  scp .../sapqa-offline-bundle.tar.gz .../setup-and-run.sh user@jump:~/
[jump]    eval "$(ssh-agent -s)"; ssh-add ~/sap-checks-key     # if using agent mode
[jump]    bash ~/setup-and-run.sh       # or: --answers answers.env
[laptop]  scp user@jump:".../CONFIG_*.html" .                  # collect the report
```
