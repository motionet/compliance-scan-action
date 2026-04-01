# motionet/compliance-scan-action

GitHub Action for EU AI Act (and other regulation) compliance scanning, powered by the [Motionet Compliance API](https://compliance-api.motionet.io).

Add one step to any workflow to get a scored compliance report with file-level evidence, SARIF output for PR annotations, and an optional severity gate that fails your build.

---

## Quick Start

```yaml
steps:
  - uses: actions/checkout@v4

  - uses: motionet/compliance-scan-action@v1
    with:
      api-key: ${{ secrets.MOTIONET_API_KEY }}
```

That's it. The action packages your workspace, submits it to the API, waits for results, and writes `compliance-results.sarif` in your workspace.

---

## With SARIF Upload (PR Annotations)

```yaml
steps:
  - uses: actions/checkout@v4

  - uses: motionet/compliance-scan-action@v1
    id: compliance
    with:
      api-key: ${{ secrets.MOTIONET_API_KEY }}
      fail-on-severity: critical

  - uses: github/codeql-action/upload-sarif@v4
    if: always()
    with:
      sarif_file: ${{ steps.compliance.outputs.sarif-file }}
```

The `if: always()` ensures the SARIF is uploaded even when the severity gate fails the build.

---

## Full Example (Recommended Production Setup)

```yaml
name: Compliance Scan

on:
  pull_request:
  push:
    branches: [main, develop]

jobs:
  compliance:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      security-events: write # required for upload-sarif

    steps:
      - uses: actions/checkout@v4

      - name: Run compliance scan
        id: compliance
        uses: motionet/compliance-scan-action@v1
        with:
          api-key: ${{ secrets.MOTIONET_API_KEY }}
          regulations: EU_AI_ACT
          fail-on-severity: high
          min-severity: medium

      - name: Upload SARIF to GitHub Security tab
        uses: github/codeql-action/upload-sarif@v4
        if: always()
        with:
          sarif_file: ${{ steps.compliance.outputs.sarif-file }}

      - name: Print compliance summary
        if: always()
        run: |
          echo "Compliance Score: ${{ steps.compliance.outputs.compliance-score }}"
          echo "Total Findings:   ${{ steps.compliance.outputs.findings-count }}"
          echo "Critical:         ${{ steps.compliance.outputs.critical-count }}"
          echo "High:             ${{ steps.compliance.outputs.high-count }}"
```

---

## Inputs

| Input              | Required | Default                              | Description                                                                                  |
| ------------------ | -------- | ------------------------------------ | -------------------------------------------------------------------------------------------- |
| `api-key`          | **yes**  | —                                    | Your Motionet API key. Store as a repository secret.                                         |
| `api-url`          | no       | `https://compliance-api.motionet.io` | API base URL. Override for staging or self-hosted.                                           |
| `regulations`      | no       | `EU_AI_ACT`                          | Comma-separated regulation IDs. Supported: `EU_AI_ACT`, `DSGVO`, `CRA`, `NIS2`.              |
| `min-severity`     | no       | `info`                               | Minimum severity to include in output. Options: `info`, `low`, `medium`, `high`, `critical`. |
| `fail-on-severity` | no       | `none`                               | Severity threshold that fails the build. Use `none` to never fail.                           |
| `sarif-output`     | no       | `compliance-results.sarif`           | Output file name or path. Relative paths are resolved from `$GITHUB_WORKSPACE`.              |

---

## Outputs

| Output             | Description                             |
| ------------------ | --------------------------------------- |
| `compliance-score` | Overall compliance score (0–100)        |
| `findings-count`   | Total number of findings                |
| `critical-count`   | Number of critical findings             |
| `high-count`       | Number of high severity findings        |
| `scan-id`          | Scan UUID — use for follow-up API calls |
| `sarif-file`       | Absolute path to the written SARIF file |

---

## Exit Codes

| Code | Meaning                                                             |
| ---- | ------------------------------------------------------------------- |
| `0`  | Scan complete. No findings at or above `fail-on-severity`.          |
| `1`  | Scan complete. One or more findings at or above `fail-on-severity`. |
| `2`  | Error: API unreachable, HTTP 429 (quota), invalid key, or timeout.  |

Exit code `2` is always an infrastructure or quota issue — not a compliance failure. A quota error is never treated as exit `1`.

---

## What Gets Scanned

The action creates a gzip tarball of your `$GITHUB_WORKSPACE` directory, excluding:

- `.git/`
- `node_modules/`
- `__pycache__/`
- `.env`
- `*.pyc`, `.venv/`, `venv/`, `dist/`, `build/`, `.tox/`

The tarball is submitted to the API over HTTPS and deleted from the runner after the scan completes. No source code is retained on the server beyond the scan session.

---

## Async Scans (Large Projects)

For large projects the API returns `202 Accepted` and processes the scan asynchronously. The action automatically polls `GET /api/v2/scans/:id` every 5 seconds, up to 60 attempts (5-minute timeout). If the timeout is reached, the action exits with code `2`.

---

## Setting up Your API Key

1. Log in at [compliance-api.motionet.io/dashboard](https://compliance-api.motionet.io/dashboard)
2. Generate an API key under **Settings → API Keys**
3. Add it as a repository secret: **Settings → Secrets and variables → Actions → New repository secret**
   - Name: `MOTIONET_API_KEY`
   - Value: your API key

---

## SARIF and GitHub Security Tab

The SARIF file output by this action is compatible with `github/codeql-action/upload-sarif`. Once uploaded, findings appear:

- In the **Security → Code scanning alerts** tab
- As inline annotations on pull request diffs
- In the **Security Overview** for your organization

Findings are mapped to SARIF severity levels:

| Compliance Severity | SARIF Level |
| ------------------- | ----------- |
| `critical`          | `error`     |
| `high`              | `error`     |
| `medium`            | `warning`   |
| `low`               | `note`      |
| `info`              | `note`      |

---

## Multiple Regulations

```yaml
- uses: motionet/compliance-scan-action@v1
  with:
    api-key: ${{ secrets.MOTIONET_API_KEY }}
    regulations: EU_AI_ACT,DSGVO,CRA
    fail-on-severity: high
```

---

## Scheduled Weekly Scan

```yaml
on:
  schedule:
    - cron: "0 9 * * 1" # Every Monday at 09:00 UTC

jobs:
  compliance:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: motionet/compliance-scan-action@v1
        with:
          api-key: ${{ secrets.MOTIONET_API_KEY }}
          regulations: EU_AI_ACT,DSGVO
```

---

## Requirements

- GitHub-hosted runner: `ubuntu-latest` (recommended), `ubuntu-22.04`, or `ubuntu-20.04`
- Tools required on runner: `curl`, `tar`, `jq` — all pre-installed on GitHub-hosted Ubuntu runners
- Self-hosted runners: ensure `curl` and `jq` are installed

---

## License

MIT — see [LICENSE](./LICENSE)
