# Reference

The complete format, what the validator actually enforces, and how to wire it in.

## File layout

```
.contracts/
  README.md             a short orientation for whoever opens the directory next
  project.json          path zones and the default class
  _template.json        copy to <name>.json; files beginning with _ are skipped
  <name>.json           one contract per file; filename should match `name`
  proposed/             drafts from `discover`; unconfirmed, grant nothing
  proposed/DISCOVERY.md the evidence behind those drafts
  .state/               derived local state; `.gitignore`d by `init`
```

Commit `.contracts/` with the code. The point of keeping it in the repo is that a contract
and the output it describes move together, and that a change to either is reviewed in the
same pull request.

## Contract schema

`schemaVersion` is `1`. Unknown top-level keys are reported as warnings so typos surface
instead of being silently ignored.

### Top level

| key | required | notes |
|---|---|---|
| `schemaVersion` | yes | must be `1` |
| `name` | yes | stable identifier; should match the filename |
| `status` | yes | `confirmed` or `proposed`. `proposed` grants no permission and must pair with `autoApply: "never"` |
| `why` | yes | the business consequence of breaking it, in plain language. Minimum 25 characters; a `TODO`/`TBD`/`FIXME` placeholder is rejected on a `confirmed` contract |
| `owner` | no | team or person to ask |
| `governs` | yes | `{ paths, entrypoints }` — see below |
| `protected` | yes* | the fields that must not drift |
| `tolerant` | no | fields that are explicitly allowed to drift, so nobody has to guess |
| `guardrails` | no | in-code protections this contract asserts still exist |
| `externalBoundary` | no | fields whose real logic is not in this repo |
| `sampler` | no | how to produce samples for `bounded` fields |
| `policy` | yes | `{ autoApply, onDriftUnresolved }` |
| `evidence` | no | where the contract came from; `discover` fills it, review keeps it |
| `confirmedBy`, `confirmedAt` | no | who signed it off, and when |

\* a contract needs at least one `protected` entry **or** one `externalBoundary` entry.
Otherwise it asserts nothing, and the validator says so.

### `why` deserves its own paragraph

It is the only field that cannot be derived, checked by a tool, or reconstructed later. It
is what a reviewer reads to decide whether the rest of the file is right, and it is what
stops a contract being deleted in two years by someone who cannot see the point of it.
Write the consequence, not the mechanism:

- Good: "This figure is printed on the customer's estimate and invoiced against. If it
  moves, the next conversation is a billing dispute, and the customer is right."
- Useless: "This field is important." "Protects the total." "Do not change."

A contract without a stated consequence is a guess. The validator enforces a length floor
and rejects placeholders, which catches laziness but cannot catch vagueness. Reviewers can.

### `governs`

| key | notes |
|---|---|
| `paths` | at least one glob. The deterministic classification layer intersects changed files against these |
| `entrypoints` | informational: function names or routes a human can grep for |

Glob syntax, matched against repo-relative paths:

| pattern | matches |
|---|---|
| `*` | anything within one path segment |
| `?` | one character within one segment |
| `**/` | zero or more directories |
| `**` | anything, segments included |

`src/quote/**` covers `src/quote/a.ts` and `src/quote/deep/b.ts`. `src/**/*.sql` covers any
`.sql` under `src`. Globs that are too broad cause everything to classify C3 and get
ignored; globs that are too narrow are how a protected field escapes. Prefer the directory
that owns the output.

### `protected[]`

| key | required | notes |
|---|---|---|
| `field` | yes | dotted path as it appears to the consumer, e.g. `quote.totalCents` |
| `locator` | recommended | the file where the field is declared. The drift check greps this file for the leaf name; without it the check falls back to searching `governs.paths`, which is slower and vaguer |
| `class` | yes | `deterministic`, `bounded` or `prose` |
| `type` | no | `money`, `quantity`, `identifier`, `shape`, `enum`, `text` — informational, but it is what makes a review fast |
| `assertOn` | no | `value` (default), `shape`, or `presence` |
| `shape` | when `assertOn: "shape"` | the format that must hold, e.g. a regex |
| `tolerance` | when `class: "bounded"` | see below |

`assertOn` exists for the field whose value legitimately varies every call but whose format
is load-bearing. A generated identifier is the usual case: the value is new each time, and
another system parses it. `assertOn: "shape"` with a regex pins the format and says nothing
about the value. `assertOn: "presence"` asserts only that the field is still there, which is
the honest assertion for a value this repo merely forwards.

### `tolerance`, for `bounded`

| key | required | notes |
|---|---|---|
| `samples` | yes | how many runs. Fewer than 5 does not distinguish variance from drift |
| `band` | one of these two | `{ min, max }` — the hard assertion. Every sample must be inside it |
| `bandSource` | one of these two | the `name` of a `guardrail` that defines the band in code. Prefer this: one definition, not two |
| `meanDriftPct` | yes | how far the mean of the samples may move from the pre-change mean |

Both assertions are needed. The band catches a value leaving the legitimate range. The mean
drift catches a systematic shift that stays inside the band — every sample legal, the average
up 30%, the invoices up 30%. A band alone would pass that.

`deterministic` fields must not carry a `tolerance`. If you find yourself adding one, the
class is wrong.

### `sampler`

```json
"sampler": {
  "command": "npm run --silent contract:sample -- quote-total",
  "produces": "one JSON object per line: {\"field\": \"quote.totalCents\", \"value\": 184500}"
}
```

**`contracts.sh` does not run this, by design.** A validator that executes arbitrary repo
code is a different trust decision from one that reads JSON and greps, and conflating them
means the gate cannot be run anywhere cheap. The validator checks that a sampler is declared
where `bounded` fields exist, and says so when it is missing. Your CI runs it. If you have
no sampler, you have a declared band and nothing measuring it — which is still better than
nothing, because the band documents the intent and the drift check still protects the name,
but do not call the field verified.

### `guardrails[]`

The contract asserting that an in-code protection still exists.

| key | required | notes |
|---|---|---|
| `name` | yes | referenced by `tolerance.bandSource` |
| `symbol` | when `mustExist` | the identifier to look for |
| `file` | recommended | where it should be |
| `mustExist` | no | defaults to true |
| `asserts` | yes | what this code guarantees, in plain language |

This is how a band defined in code stays the single source of truth. A clamp helper that
pins a generated number into a deterministic range per scope and logs every time it has to
clamp *is* the contract, expressed executably. The JSON asserts that it is still there,
because the way a band stops protecting is that someone deletes the clamp in a cleanup, and
nothing else notices.

When the guardrail disappears, `validate` fails with `protection removed?` and the project
goes no-auto-apply. That is the intended outcome. It is also why `asserts` is mandatory: the
person who finds the failure needs to know what they just lost.

### `externalBoundary[]`

For fields whose real logic is behind a network call or inside another service. Nothing
local can verify across that boundary, and a contract that cannot be verified must say so
rather than imply coverage.

| key | required | notes |
|---|---|---|
| `field` | yes | which protected field crosses the boundary |
| `kind` | yes | `network`, `service`, `vendorSdk`, `database`, `queue` |
| `verifiable` | no | defaults to false. `true` only if a local check genuinely proves the value |
| `describes` | yes | what lives on the other side, and what a local check can and cannot show |
| `compensating` | no | the out-of-band check that does cover it, and how stale it is allowed to get |

`validate` prints a standing notice for every boundary where `verifiable` is not `true`.
That notice is the feature. The worst outcome for an unverifiable field is a green check
beside it.

### `policy`

| key | values | effect |
|---|---|---|
| `autoApply` | `never` | a change touching this contract is never applied unattended, whatever class it is. Raise a pull request |
| | `withApproval` | may be applied after a recorded human approval |
| | `allowed` | the class decides |
| `onDriftUnresolved` | `blockProject` (default) | an unresolved field blocks the whole project |
| | `blockContract` | blocks only changes touching this contract. Use sparingly; drift means the contracts no longer describe the code, and that blast radius is unknown |

`autoApply: "never"` is the right default for anything monetary. It does not block the work;
it blocks the work happening silently.

## `project.json`

```json
{
  "schemaVersion": 1,
  "project": "quote-service",
  "default": "C3",
  "internal": ["**/*.test.*", "**/__tests__/**", "docs/**", "scripts/**"],
  "presentation": ["src/**/*.css", "templates/**"],
  "security": ["src/auth/**"]
}
```

| key | effect |
|---|---|
| `internal` | paths that reach no observable output → C0 |
| `presentation` | paths that reach only human-readable text → C2 |
| `security` | paths where a change is expected to alter behaviour → C4 |
| `default` | the class for everything else. Keep it `C3` |

These zones exist so C0 is reachable without weakening the default. Without them every path
is undeclared, every change is C3, and nothing auto-applies — correct, but useless. A human
declares a zone; the tool does not infer one. Lowering `default` below `C3` is possible and
the validator warns about it, because it inverts the asymmetry the whole design rests on.

## What `validate` checks

| check | kind | effect on failure |
|---|---|---|
| JSON parses and is an object | parse | fail |
| `schemaVersion`, `name`, `status`, `policy.autoApply` present and in range | schema | fail |
| `why` present, long enough, not a placeholder | why | fail |
| `governs.paths` non-empty | schema | fail |
| class/tolerance coherence per protected field | schema | fail |
| `assertOn`/`shape` coherence | schema | fail |
| at least one `protected` or `externalBoundary` | schema | fail |
| `proposed` status paired with `autoApply: "never"` | policy | fail |
| **every protected field resolves in the code** | drift | fail + project block |
| **every asserted guardrail still present by symbol** | drift | fail + project block |
| `externalBoundary` kinds and text | schema | fail |
| unknown top-level keys | — | warning |
| `bounded` fields with no sampler | — | notice |
| unverifiable external boundaries | — | notice |

Drafts under `proposed/` are checked the same way, but their problems are reported as work
for a human rather than failures, because a draft grants no permission and so cannot fail
open.

The drift check is deliberately crude: it greps for the leaf name of the field path. It
cannot tell a declaration from a comment. It is not trying to prove the field is correct —
it is trying to prove the contract is still talking about something that exists. That weaker
claim is what closes the fail-open hole, and it closes it cheaply enough to run on every
commit.

## Exit codes

| code | meaning |
|---|---|
| 0 | ok |
| 1 | usage or environment error, including a missing utility |
| 2 | a contract failed validation, or a protected field no longer resolves |
| 3 | `classify` only: the change may not be applied automatically |

Exit 3 does not mean the change is wrong. It means it does not get to happen unattended —
raise a pull request. Treat 2 as a blocked merge.

If a required utility is missing, the script exits 1 rather than finding zero contracts and
reporting success. A checker that cannot run must say so loudly; the alternative is the
fail-open bug wearing a different hat.

## Environment

| variable | effect |
|---|---|
| `CONTRACTS_JSON_ENGINE` | force `jq` or `python3`. Default: `jq` if present, else `python3` |

## CI wiring

```yaml
# every pull request
- run: ~/.claude/skills/system-contracts/scripts/contracts.sh validate
- run: ~/.claude/skills/system-contracts/scripts/contracts.sh classify --since origin/main
```

`validate` failing should block the merge. `classify` exiting 3 should block an *automated*
merge and post its output on the pull request, so the reviewer reads the class and the
contracts touched before the diff.

For an automated change pipeline, the order matters:

1. `validate` — if this fails, stop. The contracts do not describe the code, so no statement
   about safety can be made yet.
2. `classify --since <base> --json` — read `class` and `blocked`.
3. `blocked: true` → raise a pull request, never apply. Include the `reason` verbatim; it
   names the contract.
4. C1 → run the repo's own equivalence check over exactly the protected fields the JSON
   lists, at their declared classes. Not whole-output equality.
5. No contract covers the surface → file a contract-amendment proposal instead of a change.

## Contract-amendment proposal

The backward direction of amendment. When automation meets an undeclared output surface it
files this and stops. Keep it in the repo, next to the contracts, as
`.contracts/proposed/<name>.draft.json` plus a pull request body:

```
Surface found:     quote.discountCents, returned from src/quote/estimate.ts
Reached by:        the change I was about to make to src/quote/pricing.ts
Covered by:        nothing
Evidence:          src/quote/types.ts:14 declares it; src/render/email.ts:9 prints it
Class I would need: C3 — it is a monetary field on a customer-facing document
Proposed contract:  .contracts/proposed/quote-discount.draft.json
What I did instead: nothing. This is not a permission request for the change; it is a
                    request for someone to say what this number must not do.
```

The value is in the last line. An automated system that proposes amendments is maintaining
the contracts; one that proceeds because nothing forbade it is laundering an unreviewed
change through an empty rule.

## Schema file

`assets/contract.schema.json` is a JSON Schema for `.contracts/*.json`, for editor
completion and for CI that already has a schema validator. It is a convenience: the
authority is `contracts.sh validate`, which checks things a schema cannot — whether the
fields still exist in the code.
