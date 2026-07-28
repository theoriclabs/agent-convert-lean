# Loom Inspect Blinded Review

## Review Instructions

Use only the supplied read-only review handoff. Do not inspect source
transcripts, conversion intermediates, administrator provenance, implementation
code, tests, scoring material, the candidate binary, or the package tarball. Do
not run project code during this review.

Obtain the policy-authority public key through the separately authenticated
release-policy channel. A key found only in this handoff is not a trust anchor.
Before opening any case:

```sh
cd /path/to/read-only/review-handoff
shasum -a 256 -c HANDOFF-MANIFEST.sha256
cmp /trusted/policy-authority.pub POLICY-AUTHORITY-PUBLIC-KEY.pub
printf 'policy-authority ' > /private/allowed-policy-signers
cat /trusted/policy-authority.pub >> /private/allowed-policy-signers
ssh-keygen -Y verify -f /private/allowed-policy-signers \
  -I policy-authority -n agent-convert-human-validation-policy \
  -s PRE-REVIEW-RECEIPT.json.sig < PRE-REVIEW-RECEIPT.json
shasum -a 256 PRE-REVIEW-RECEIPT.json HANDOFF-MANIFEST.sha256 \
  PREPARATION-MANIFEST.sha256 POLICY-AUTHORITY-PUBLIC-KEY.pub \
  REVIEWER-PUBLIC-KEY.pub
```

Confirm that the signed receipt names the independently published run id and
nonce, the externally committed preparation-root digest, your pre-registered
reviewer-key digest, the registered ledger-key digest, and the expected ledger
origin. Stop and invalidate the run if any command or comparison fails, the
handoff contains an unlisted file, the policy is expired, or a signed value does
not match the independent release record.

Copy `QUESTIONNAIRE.md` to a private writable path and edit only that copy. Keep
the handoff unchanged. Preparation rejects terminal controls; stop if a file
moves the cursor, changes colours, retitles the terminal, or otherwise renders
oddly.

Answer in your own words. Procedural clarifications are permitted only under the
rules below. Preserve an initial answer when a later clarification changes it,
then append the revised answer and cite the clarification number.

## Review Binding

Transcribe these values exactly from `REVIEW-BINDING.json`, the signed
`PRE-REVIEW-RECEIPT.json`, and the digest commands above. Use
`N/A (not supplied)` for all package fields when `package` is `null`.

Run ID:

Release nonce:

Candidate binary SHA-256:

Candidate binary size in bytes:

Core revision:

Candidate version:

Target triple:

CLI protocol version:

Package name:

Package version:

Package tarball SHA-256:

Claude target harness version:

Pi target harness version:

Preparation manifest SHA-256:

Preparation root manifest SHA-256:

Pre-review receipt SHA-256:

Handoff manifest SHA-256:

Policy authority public key SHA-256:

Reviewer public key SHA-256:

Ledger origin:

## Questions

1. In `CASE-A.inspect.txt`, list the entry roles in order. Which entry is
   active, and how many structural violations are reported?
2. What thinking text is visible? What does the view report about its
   signature, and are opaque signature bytes shown?
3. Describe the tool call and result completely, including their linkage,
   arguments, outcome, and content.
4. Explain each import judgment in Case A. Base the explanation only on the
   rendered evidence.
5. In `CASE-B.inspect.txt`, list the conversation entries in order.
6. What command and background-task information can you recover from Case B?
7. Which records in Case B are outside the conversation, and where does the
   view expose their normalized meaning?
8. In `CASE-C.inspect.txt`, identify each thread and any label or anchor.
9. Assign each user and assistant message in Case C to a thread in order.
10. Describe the thread-related tool call and all reported entry-time
    provenance in Case C.
11. In `CASE-D.inspect.txt`, list every entry in order with its role, concise
    content, and reported disposition. Which entry is active, and how many
    structural violations are reported?
12. Based only on the rendered evidence, what operational or execution status
    should a reviewer assign to each Case D entry? Identify the affected calls
    and results and cite the lines that support the conclusion.
13. List every raw XML/HTML-like harness wrapper visible in any rendered case,
    including opening or closing tags, tags with attributes, and case variants.
    Write `none` if there are none.
14. On a 1-5 scale, could you use these views to audit a migration without
    reading raw JSON? Name every term or layout choice that blocked or slowed
    you, and classify each ambiguity as blocking or non-blocking.

## Answers

### Answer 1
[required answer]

### Answer 2
[required answer]

### Answer 3
[required answer]

### Answer 4
[required answer]

### Answer 5
[required answer]

### Answer 6
[required answer]

### Answer 7
[required answer]

### Answer 8
[required answer]

### Answer 9
[required answer]

### Answer 10
[required answer]

### Answer 11
[required answer]

### Answer 12
[required answer]

### Answer 13
[required answer]

### Answer 14
Usability score (1-5):
Auditability explanation: [required explanation]
Blocking ambiguities:
- none
Non-blocking ambiguities:
- none

## Clarification Log

Use `0` when there were no requested clarifications or unsolicited
administrator comments. Otherwise add exactly that many numbered blocks:

```text
Clarification block 1 (replace this line with heading `### Clarification 1`):
UTC time: 2026-07-20T20:00:00.000Z
Question: 4
Reviewer request: exact request
Administrator response: exact response or unsolicited comment
Answer changed (yes or no): no
```

The administrator may repeat a question, identify a supplied file, or explain
how to record an answer. Definitions, interpretation, relevant-line hints,
answer confirmation, fixture descriptions, and expected-answer paraphrases are
prohibited. Record every exchange before continuing.

Clarification count:

Add any numbered clarification blocks here, after the completed count.

## Protocol Record

Protocol deviations:
- none

Replace `none` with one bullet per deviation. Do not omit or soften a deviation;
failed and invalid reviews are retained as evidence.

## Reviewer Attestation

Use exact UTC timestamps of the form `YYYY-MM-DDTHH:MM:SS.sssZ`. The completion
time must follow the start time, every clarification must fall within that
interval, and the attestation date must be the UTC date of completion.

Reviewer name:

Reviewer role and team:

Administrator name:

Review started at (UTC):

Review completed at (UTC):

Independence from implementation (yes or explain):

Blinding remained intact until answers were final (yes or explain):

- [ ] I received only the allowlisted read-only review handoff.
- [ ] I did not inspect excluded source, provenance, code, tests, scoring
      material, binary, or package bytes before finalizing my answers.
- [ ] I verified the handoff manifest, the externally trusted policy key, the
      policy signature, the signed preparation-root commitment, and all binding
      fields before opening a case.
- [ ] Every answer, ambiguity classification, and usability score is my own
      observation.
- [ ] The clarification and protocol-deviation records are complete, including
      unsolicited administrator comments.

Reviewer signature:

Attestation date (UTC):

## Cryptographic Review Lock

After finalizing this file, derive `REVIEW-SIGNING-PAYLOAD.txt` with the sealing
script. Before signing, independently verify every payload field against this
handoff and completed questionnaire. The payload binds the signed pre-review
receipt, preparation root, handoff manifest, registered reviewer and ledger
keys, ledger origin, and exact completed bytes.

```sh
ssh-keygen -Y sign -f /path/to/reviewer-private-key \
  -n agent-convert-human-validation REVIEW-SIGNING-PAYLOAD.txt
```

Do not permit administrator scoring until the independent ledger has accepted
the signed payload digest and returned its own signed receipt.
