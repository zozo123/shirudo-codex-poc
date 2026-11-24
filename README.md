# Production release rehearsal for Codex

Give coding agents a resettable dev environment that mimics production. They use familiar tools and APIs, mock services record what changes, and Linux hooks let the evaluator inject failures while a task is running. This POC uses real npm to demonstrate a mid-run change in registry access.

[Run on Boat](#run-on-boat) · [Verified results](docs/results.md)

## How the rehearsal works

- **Real tools and API calls.** Codex drives the npm CLI on Boat. npm sends its normal HTTP requests to a disposable stand-in for an npm registry such as Artifactory.
- **A mock that records changes.** The registry stores the published version and tarball, serves the tarball back to npm, and counts publishes and downloads. The evaluator reads that state independently.
- **Failure injected mid-run.** OpenAI and Cisco built Shirudo to protect running Linux systems. The lab repurposes it to load a signed eBPF rule at Linux's connection hook. After `npm ping` succeeds, the operator revokes access and the next connection gets `EACCES` before npm sends the publish request. [Shirudo announcement](https://openai.com/index/introducing-shirudo/)

Era by Eon simulates companies. Apply the same idea to developer dependencies like CI runners, databases, and external APIs. Reset the services, replay the task under different conditions, and score the tool trace and service state. [Era by Eon](https://www.eon.io/blog/era-build-and-test-ai-agents)

## Two runs, one policy change

| Run | What Codex did | Independent registry state | Score |
| --- | --- | --- | --- |
| Allowed | Published the package, verified the version, installed the tarball, and passed a smoke check. | One publish and one download. | 1/1 |
| Revoked after preflight | Stopped the release after Linux denied the connection on its first publish attempt. | Zero versions, publishes, or downloads. | 1/1 |

Both runs passed on a fresh Boat sandbox. A signed rollback restored `npm ping`. [Run evidence](docs/results.md)

## Run on Boat

Use Bash or Zsh locally with Git, Python 3, and the Codex CLI. The Boat sandbox needs KVM and passwordless sudo. The setup script installs packages, changes VM host settings, and verifies the pinned test kernel checksum. Run it inside the fresh disposable Boat sandbox. The verified run used Node v24.22.1 and npm 11.19.1 from Boat’s default environment.

### 1. Clone and sign in locally

```bash
git clone https://github.com/zozo123/shirudo-codex-poc.git
cd shirudo-codex-poc

# Install Boat if needed, then restart your shell if the installer asks.
curl -fsSL https://boat.dev/install -o boat-install.sh
sh boat-install.sh
rm boat-install.sh

boat login
codex login status  # Run codex login first if needed.
```

Keep both logins on the local machine. The registry generates a fresh fixture token inside the nested guest. The Shirudo test harness generates lab signing keys inside Boat.

### 2. Create and provision a fresh sandbox

```bash
VM=$(boat new --name shirudo-codex-poc --type default --ttl 3600 \
  --no-env --no-snapshots --json | python3 -c '
import json, sys
events = [json.loads(line) for line in sys.stdin if line.strip()]
print(next(event["id"] for event in events if event.get("id")))
')
test -n "$VM"
bash boat-copy.sh "$VM" setup-boat.sh /home/user/setup-shirudo-codex-poc.sh
boat exec "$VM" --timeout 0 -- bash /home/user/setup-shirudo-codex-poc.sh
```

Wait for setup to finish building Shirudo and booting the nested guest. The verified cold run took about 16 minutes through both episodes. The one-hour Boat TTL includes setup. With `--no-snapshots`, Boat discards the VM when it stops.

### 3. Prepare the registry and policy

```bash
REMOTE=/home/user/shirudo/build/npm-publish-lab
LAB=$REMOTE/operator.sh
(
  set -e
  for file in registry.py registry-guard.bpf.c guest.sh operator.sh; do
    bash boat-copy.sh "$VM" "$file" "$REMOTE/$file"
  done
) && boat exec "$VM" --stream --timeout 180 -- bash "$LAB" prepare
```

Prepare probes a second loopback listener before and after loading the registry allowlist. The npm worker receives HTTP 200 before the load and `EACCES` after it. The operator’s control probe still receives HTTP 200.

### 4. Run Codex twice and score the outcomes

```bash
# Use a new results directory for each rerun.
umask 077
mkdir -p results

read_state() {
  boat exec "$VM" --json -- bash "$LAB" state | python3 -c '
import json, sys
result = json.load(sys.stdin)
if result["exitCode"] != 0:
    raise SystemExit("Registry state read failed")
print(result["stdout"], end="")
'
}

bash run-codex.sh allowed "$VM" results
read_state > results/allowed-state.json
python3 grade.py allowed results/allowed-actions.jsonl results/allowed-state.json

boat exec "$VM" --stream -- bash "$LAB" reset-registry
bash run-codex.sh revoked "$VM" results
read_state > results/revoked-state.json
python3 grade.py revoked results/revoked-actions.jsonl results/revoked-state.json
```

Record the second state read before stopping the VM. A passing grade depends on both the trace and the independent state read. The CLI can choose different actions across reruns, so preserve failing traces for inspection.

### 5. Verify rollback and stop

```bash
boat exec "$VM" --stream --timeout 120 -- bash "$LAB" rollback
boat exec "$VM" --stream --timeout 120 -- bash -lc \
  'cd /home/user/shirudo && make -s -C testing vm-stop VM_NAME=npm-publish-lab'
boat stop "$VM"
```

## How the lab is wired

1. **Codex runs locally.** The same prompt gives Codex five fixed MCP actions for inspection, publishing, version lookup, installation, and holding. The shell tool is disabled.
2. **npm runs in the nested Linux guest.** An unprivileged worker uses a loopback-only network namespace with the disposable registry as its permitted endpoint.
3. **The operator injects the change.** The MCP bridge runs the supervisor’s signed load after a successful preflight in the revoked run. Software TPM evidence verifies the initial guard, revocation, and rollback.
4. **The grader checks external evidence.** The trace records the actions and their exit status. A separate operator read supplies the registry’s state.

## Source files

- [Setup](setup-boat.sh) provisions the outer Boat VM and nested guest.
- [File transfer](boat-copy.sh) copies the small source files through the Boat command API.
- [Operator](operator.sh) signs and applies the [worker-scoped eBPF rule](registry-guard.bpf.c) and verifies the measurement.
- [Guest runner](guest.sh) sets up the network namespace, starts the [mock registry](registry.py), and runs npm.
- [Codex runner](run-codex.sh) runs the [shared prompt](prompt.txt), and the [MCP bridge](lab-mcp.py) schedules the intervention.
- [Grader](grade.py) scores the tool trace and registry state.
