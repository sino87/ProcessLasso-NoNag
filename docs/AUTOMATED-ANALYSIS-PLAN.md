# Automated analysis and patch candidates

Status: implementation plan. No workflow behavior is changed by this document.

## Goal

Extend the existing stable-x64 upstream check so an unregistered executable can produce a reproducible patch candidate, a draft PR, and a Discord notification. Candidate generation assists review; it does not establish support or replace manual VM validation.

The first implementation handles the three known reminder routes when their surrounding structure remains recognizable. Unsupported transformations produce an explanation and stop without generating a patch.

## Existing behavior to preserve

- Official installer checksum and Bitsum signature verification.
- Executable architecture, version, signature, and exact-hash checks.
- Registered-build Apply/Restore, older-backup replacement, and rollback behavior.
- Successful registered-build checks update only the automated README row.
- Manual-test status changes only after reported VM validation.
- Releases remain manually started drafts.
- Existing users retain support for both registered builds.

## Dependencies and design

Use Python with `pefile` for PE headers, sections, resources, imports, and runtime-function metadata, and Capstone's detailed x64 instruction decoding for operands and branch targets. Use the standard library for schemas, deterministic serialization, reports, and tests where practical. Pin tested dependency versions and package hashes during implementation.

Start with these two libraries already used in local analysis. Do not add Ghidra, BSim, an external database, or an AI service to the first implementation. Reconsider heavier analysis only after real unsupported updates establish a need.

Expose one analysis module through a small CLI: executable path, English-resource DLL path, trusted template directory, and output directory. Return a structured result and diagnostic report. Network access, GitHub writes, and Discord delivery remain outside this module.

Move per-version patch definitions from embedded PowerShell tables into a single validated `src/profiles.json`. The CLI, checker, candidate generator, and package builder consume the same schema. Include the file in distribution ZIPs and remove the embedded tables; do not maintain a second source of truth. Keep templates and analysis dependencies out of the user ZIP.

Extract reusable logic from the local `analysis/inspect_update.py` and `analysis/verify_update.py` into repository-owned scripts. Those exploratory scripts currently contain fixed versions, addresses, and host paths and cannot serve as CI entry points directly.

## Result model

Keep compatibility status separate from analysis status. An unknown executable remains `review` even after a candidate is generated.

| Compatibility status | Analysis status | Outcome |
|---|---|---|
| `pass` | Not needed | Existing registered-profile verification and README update |
| `review` | `candidate` | Verified candidate definition, report, preview package, and draft PR |
| `review` | `inconclusive` | No candidate; explain missing, changed, or ambiguous evidence |
| `error` | `error` | Acquisition, parsing, tool, or test failure; retry and error notification |

Report a stable reason code and readable explanation for each outcome. A successful analyzer process is not a compatibility pass.

## Candidate eligibility

Build reviewed structural templates from the verified 18.3.0.34 and 18.4.0.48 files. Templates identify the GUI redisplay reminder, startup discount offer, and startup reminder independently.

Templates contain normalized instructions and basic-block relationships, relevant calls/imports, resource roles, and the conditional branch to change. Normalize only understood address relocations and equivalent encodings; preserve constants, conditions, and meaningful operands. Never remove all immediate values or memory references merely to obtain a match.

For each new executable:

1. Verify the downloaded installer and executable with the existing checks. Extract `pl_rsrc_english.dll` from that same checksum-verified, signed installer as well as the executable. Obtain its resource metadata without loading or running the DLL.
2. Locate relevant resource content and references. Current IDs `0x291` and `0x13BF` are evidence, not sufficient identity checks. Changed or missing resource roles stop automatic generation.
3. Follow decoded references, imports, calls, and runtime-function ranges to identify the three routes.
4. Require a unique structural match for every route. Similarity scores may rank diagnostics but cannot authorize generation. Contradictory templates or multiple matches are inconclusive.
5. Confirm source instructions and targets are valid boundaries in executable sections and in the expected function/control-flow region.
6. Confirm the bypass skips the identified display path, retains the intended continuation and required initialization/cleanup, and does not modify the shared predicate or generic dialog helper. Any unresolved dependency on skipped instructions is inconclusive.
7. Preserve the original conditional branch target when encoding the unconditional branch. Only the existing two-byte and six-byte forms are supported initially; fill unused bytes with NOPs. Reject overlapping sites, out-of-range targets, or unrecognized forms.
8. Validate all three sites before producing any patch. Record exact source bytes, replacements, offsets, RVAs, targets, source hash, output hash, and analyzer/template versions.

These conditions limit automatic candidates to recognized transformations. They are not a proof of semantic equivalence or purchase-reminder suppression.

## Candidate validation

- Generate modified bytes in an isolated temporary directory without executing vendor binaries.
- Independently decode original and replacement instructions and compare their targets.
- Confirm file size, PE layout, and every byte outside declared patch ranges remain unchanged.
- For the supported forms, confirm the expected six changed bytes across three sites. Changes outside those forms require manual analysis.
- Verify reversal restores the original SHA-256 exactly.
- Exercise the proposed profile through the production patch engine in an isolated candidate workspace, including Apply/Restore, older-backup replacement, interruption/error recovery, and restart-result tests with stubbed GUI operations.
- Keep candidate definitions out of the default branch until review and VM validation finish. Creating a source/output hash pair alone is not evidence that a patch is correct.

## Actions flow

Extend `check-upstream.yml` rather than adding a second periodic downloader. Keep the daily schedule and manual entry point. Retain the existing `publish_results=false` diagnostic mode, which performs analysis but does not send notifications, create PRs, or change repository state.

1. Acquire the official stable-x64 installer and extract the required files once.
2. Run the existing registered-profile check.
3. On `review`, invoke the analyzer in the same ephemeral job using those exact files.
4. Produce diagnostics or validate a complete candidate.
5. Upload only JSON/Markdown diagnostics and, for successful candidates, a preview CLI ZIP containing project code and the proposed profile. Retain artifacts for 30 days. Exclude vendor executables, DLLs, modified binaries, and secrets.
6. In a separate publication job, create or find the matching draft PR, send Discord notifications, and persist state. Do not execute generated code in the publication job.

The analysis job uses read-only repository permissions and receives no webhook secret. The publication job validates artifact schemas and allowed file paths, and uses `contents: write` and `pull-requests: write` only for the required operations. The repository must allow GitHub Actions to create PRs. Prefer the existing `GITHUB_TOKEN`; do not add a personal access token merely to bypass workflow approval behavior.

Bound runtime and input sizes. A timeout, malformed PE/resource table, incomplete decode, or unavailable dependency is an error, never a partial success.

## Draft PR and promotion

Use the full executable hash as the candidate identity. Put the version and a short hash in the branch name and PR title. Different files with the same version must remain distinct candidates.

The draft PR adds a proposed profile with `VmValidated=false` and the analysis report. It does not change workflow files, executable application logic, README verification rows, or existing profiles. Generate the preview ZIP from an isolated copy with this proposed profile included.

Include source metadata, hashes, reference-template identities, the evidence for each route, before/after instructions, branch targets, test results, and a manual VM checklist. State explicitly that runtime behavior is unverified.

For repeated runs, reuse an open PR for the same hash. Do not force-push over human edits. If the PR is closed without merging, suppress automatic recreation; a manual regeneration option can explicitly retry. A change to the analyzer/templates permits reanalysis but does not silently replace a PR edited by a maintainer.

Run candidate tests explicitly in the analysis workflow. Do not assume bot-created PRs will immediately run ordinary PR CI: current GitHub documentation says these runs can require approval. Show that approval requirement in the maintainer instructions.

After static review and manual VM tests, a maintainer marks the profile VM-validated, updates the manual README row and technical details, and merges the PR. A subsequent default-branch upstream check may then update the automated README row. Release creation remains the existing manual workflow.

## Discord and persistent state

| Event | Message |
|---|---|
| Complete candidate | Candidate generated, version/hash, PR and run links, VM validation required |
| Inconclusive analysis | Analysis required, reason, and report/run link |
| Tool or acquisition failure | Check/analysis error, failed stage, and run link |
| Recovery | Recovery from the previously notified error |

Extend `.github/upstream-state.json` with candidate/PR identities and notification outcomes. Key analysis work by executable hash plus analyzer/template revision. Key successful candidate notifications by hash and PR identity; inconclusive notifications by hash and reason, so a new diagnostic outcome can be reported without daily duplicates. Notification failure does not mark an event delivered. State-push failure may cause duplicate delivery on retry and must be disclosed.

Treat existing `NotifiedHashes` entries as delivered legacy review notifications during a one-time state migration. Existing users and the running notification workflow require preserving that history. A newly generated candidate is a different event and must still be notified once.

PR creation and Discord delivery can fail independently. Persist confirmed PR creation before retrying notification, reuse the PR on retry, and preserve already confirmed notification outcomes. Do not mark a tool failure as analysis inconclusive.

## Implementation order and completion gates

| Phase | Work | Required evidence |
|---|---|---|
| 1 | Profile JSON schema and shared loading; update ZIP contents and tests | Existing registered builds produce exactly the same patched hashes and Apply/Restore results |
| 2 | Template extraction and read-only structural analysis CLI | Use 18.3.0.34 as the reference and reproduce the known 18.4.0.48 sites without giving the target offsets to the matcher |
| 3 | Candidate generation, independent validation, and preview ZIP | Candidate hash equals the known 18.4.0.48 patched hash; all transaction tests pass |
| 4 | Add analysis to upstream workflow in diagnostic mode | Actions produces the same deterministic candidate/report as the local analyzer, with no repository or Discord writes |
| 5 | Draft PR publication, state migration, and notifications | One PR/event per identity, successful retry behavior, no default-branch profile or README promotion |
| 6 | Enable periodic candidate publication and document operations | End-to-end manual run verified; ordinary registered-build checks and manual releases still work |

Use synthetic, project-owned PE fixtures for CI tests of relocated code, changed resource IDs/content, duplicated matches, changed conditions, inserted calls or side effects, missing routes, invalid targets, truncated instructions, malformed files, unsupported forms, and profile tampering. Every ambiguous or unsupported fixture must produce no candidate.

Keep real vendor binaries local for the historical regression gate. Do not commit them or depend on old installer URLs remaining available. Commit only the reviewed structural templates and expected hashes/site metadata needed for reproducibility.

## Out of scope

- Automatic VM operation or runtime validation.
- Automatic merge, release publication, or host patch application.
- Universal rewriting across arbitrary compiler, resource, or control-flow changes.
- AI-generated patch decisions or an automatic fallback to a different analyzer.

If the historical gate cannot reproduce the verified candidate under these constraints, publish diagnostics only and revisit the matching design before adding PR generation.

## References

- [Capstone Python bindings](https://www.capstone-engine.org/lang_python.html)
- [pefile](https://github.com/erocarrera/pefile)
- [GitHub: triggering workflows, including GITHUB_TOKEN behavior](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)
- [GitHub Actions repository settings](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)
