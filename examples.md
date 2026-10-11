# Examples

One service, worked end to end. Everything below is real output from the script against a
small fixture, including the two classifications that were initially wrong.

## The service

A quote service. One endpoint takes a scope and returns an estimate. The amount is produced
by a model call, then pinned into a band:

```
src/quote/types.ts      the returned shape
src/quote/estimate.ts   calls the model, clamps the result, returns the quote
src/quote/clamp.ts      clampToBand(raw, scope)
src/quote/bands.ts      bandForScope(scope) -> { min, max }
src/render/email.ts     renders the estimate into an email
src/tax/client.ts       calls a separate tax service for the tax line
tests/quote.test.ts
```

```ts
// src/quote/types.ts
export interface Quote {
  totalCents: number;        // the number the customer sees
  reasoning: string;         // model-written explanation
  confidenceScore: number;   // advisory telemetry
  quoteId: string;
}
```

Four fields, four different tolerances, one object. This is the normal case, not a
pathological one:

| field | tolerance | why |
|---|---|---|
| `totalCents` | zero drift | it is invoiced against |
| `reasoning` | free | model-written prose; terser is an improvement |
| `confidenceScore` | bounded | advisory; nobody is billed on it, but a score of 40 means something broke |
| `quoteId` | shape fixed, value free | regenerated every call; another system parses it |

A single module-level rule over that object is either so strict nothing ships or so loose
the money moves.

## Day one: a legacy codebase with no contracts

Nobody who wrote this is still here. Do not guess — propose from evidence.

```
$ contracts.sh init
init: created .contracts
  project.json    declare internal / presentation / security zones
  _template.json  copy it to <name>.json to write the first contract
  proposed/       contracts.sh discover writes drafts here

Until a contract exists, nothing in this repo may be applied automatically.

$ contracts.sh discover --limit 3
discover: 3 draft(s) and DISCOVERY.md written to .contracts/proposed
          drafts are unconfirmed and grant no auto-apply permission
```

The highest-signal section of the report is not the money. It is the places a previous
author already decided something must not drift:

```markdown
### guardrail (7 hit(s))

Highest signal in any codebase: a previous author already decided this must not drift.

| where | line |
|---|---|
| `src/quote/clamp.ts:2` | `export function clampToBand(raw: number, scope: string): number {` |
| `src/quote/clamp.ts:4` | `const out = Math.min(Math.max(raw, min), max);` |
| `src/quote/clamp.ts:5` | `if (out !== raw) console.warn("clamped", { raw, out, scope });` |
| `src/quote/estimate.ts:5` | `const totalCents = clampToBand(j.amount, scope);` |
| `src/tax/client.ts:1` | `export function assertTaxResponse(r: unknown): asserts r is { taxCents: number } {` |
```

Three lines of someone else's code just told us the whole design: the amount is generated,
it is not trusted, it is pinned into a band per scope, and the clamp is logged. That is a
contract already written in executable form. The JSON only has to point at it.

The candidates, ranked:

```markdown
| draft | from | evidence |
|---|---|---|
| `client.draft.json` | `src/tax/client.ts` | money identifier guardrail nondeterminism |
| `estimate.draft.json` | `src/quote/estimate.ts` | money identifier guardrail schema nondeterminism |
| `types.draft.json` | `src/quote/types.ts` | money identifier |
```

Each draft cites its evidence by file and line, carries `status: "proposed"` and
`autoApply: "never"`, and has a `why` that is an explicit TODO. None of them grant anything.
`validate` reports their gaps as work for a human rather than as failures, because a draft
that grants no permission cannot fail open:

```
$ contracts.sh validate
  warn   draft .contracts/proposed/estimate.draft.json: protected 'totalCents' is bounded but has no tolerance.band and no tolerance.bandSource
  draft  .contracts/proposed/estimate.draft.json has 2 thing(s) left for a human — grants no permission meanwhile
  ok     .contracts/proposed/types.draft.json (draft, unconfirmed — grants no permission)
```

Note that `discover` proposed `bounded` for the fields in `estimate.ts` on its own, because
it found a network call and a random identifier in that file. That is the one guess it is
allowed to make, and it errs toward the class that cannot produce false failures.

## The confirmed contract

`.contracts/quote-total.json`, written by a human from those drafts. The full file is in
`examples/quote-total.json`; the parts that carry the design:

```json
{
  "why": "totalCents is the number printed on the customer's estimate and invoiced against. If it inflates or deflates, the next conversation is a billing dispute, and the customer is right. Nothing else in this repo carries that consequence.",
  "protected": [
    { "field": "quote.totalCents", "locator": "src/quote/types.ts", "type": "money",
      "class": "bounded",
      "tolerance": { "samples": 7, "bandSource": "clamp-to-band", "meanDriftPct": 1.0 } },
    { "field": "quote.quoteId", "locator": "src/quote/types.ts", "type": "identifier",
      "class": "deterministic", "assertOn": "shape",
      "shape": "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" }
  ],
  "tolerant": [
    { "field": "quote.reasoning", "class": "prose",
      "note": "Wording, length and tone may change freely; terser is an improvement." }
  ],
  "guardrails": [
    { "name": "clamp-to-band", "symbol": "clampToBand", "file": "src/quote/clamp.ts",
      "mustExist": true, "asserts": "The model-produced amount is pinned into the band for the requested scope before it becomes totalCents, and a clamp event is logged whenever it had to move." },
    { "name": "scope-bands", "symbol": "bandForScope", "file": "src/quote/bands.ts",
      "mustExist": true, "asserts": "The per-scope minimum and maximum the total may take." }
  ],
  "policy": { "autoApply": "never", "onDriftUnresolved": "blockProject" }
}
```

Three decisions worth stating:

- **`totalCents` is the protected money field and its class is `bounded`, not
  `deterministic`.** It is produced by a model call. Two runs of untouched code return
  different numbers. `deterministic` here would fail on a no-op, and a check that fails on a
  no-op gets switched off, and then nothing is protected. The band is the contract; the
  mechanism is free to change.
- **`bandSource` points at the clamp instead of restating the numbers.** One definition. A
  band written in both the code and the JSON is two definitions that will disagree.
- **`reasoning` is listed in `tolerant`.** Not omitted — listed. Explicitly saying "this may
  change" is what lets a reviewer approve a terser model without wondering whether they just
  missed something.

## Change A — the model swap

Swap the model call for a newer generation. Cheaper, faster, terser prose, same computed
value.

```
$ contracts.sh classify --since HEAD
files      1 changed
contracts  touched:
  quote-total            protected: quote.totalCents quote.quoteId quote.confidenceScore
class      C1
auto-apply BLOCKED — contract 'quote-total' sets autoApply=never — raise a PR, never apply this unattended
```

C1: the change is inside a governed path but the diff names no protected field and no
guardrail. The verdict is a pull request with a selective equivalence check over
`quote.totalCents` at `bounded` (7 samples, band from `clamp-to-band`, mean drift ≤ 1%), the
shape check on `quote.quoteId`, and a reported-only diff of `quote.reasoning`.

This is the change the old "never change behaviour" rule blocked forever. Under a whole-output
equivalence test it fails by construction: the prose is different, on purpose, and that is an
improvement. Under the contract it ships, because the field that matters is checked at the
class it actually has.

Note `BLOCKED` with class C1. That is the `autoApply: "never"` policy, not the class. It does
not block the work; it blocks the work happening unattended. Exit code 3 means "raise a PR",
not "wrong".

## Change B — widening a band, and the classifier bug it exposed

One line in `src/quote/bands.ts`: `max: 250000` → `max: 400000`.

The first version of this classifier called that **C1**. The diff names no protected field.
It does not touch `types.ts`. Every test passes — the tests assert `bandForScope("small").min`,
and `min` did not change. It is a one-line change in a file of constants.

It also silently raises the maximum a customer can be charged by 60%.

This is exactly C3 wearing a C1 costume, and catching it is the classifier's entire job.
The fix is in the contract as much as the tool: **the file that defines a band is a
guardrail**, so it is declared as one, and a change to a guardrail is C3 on those grounds
alone — whether or not a protected field appears in the diff, and whether or not the file
sits under `governs.paths`.

```
$ contracts.sh classify --since HEAD
files      1 changed
contracts  touched:
  quote-total            protected: quote.totalCents quote.quoteId quote.confidenceScore
reached     quote-total: guardrail scope-bands changed — it defines what the protected field may be
class      C3
auto-apply BLOCKED — C3: the change reaches a declared contract field; needs explicit human sign-off
```

```json
{"class":"C3","blocked":true,
 "reason":"C3: the change reaches a declared contract field; needs explicit human sign-off",
 "files":["src/quote/bands.ts"],
 "contracts":[{"contract":"quote-total","files":"src/quote/bands.ts",
   "protected":"quote.totalCents quote.quoteId quote.confidenceScore",
   "guardrailsChanged":"scope-bands"}],
 "undeclared":[]}
```

The lesson generalises: **list every file where a protected value's permitted range is
decided, not only the file where the value is declared.** Constants files, config defaults,
feature flags, rate tables, rounding helpers. They are where a contract gets moved without
being mentioned.

## Change C — the rename that makes everything pass

A tidy-up renames `totalCents` to `amountCents` across the code. The contract still says
`totalCents`.

Without a drift check this is the worst outcome available: nothing in the code matches the
protected field, so there is nothing to compare, so every check passes. Green dashboard, no
protection, and nobody will look again because it is green.

```
$ contracts.sh validate
  FAIL   .contracts/quote-total.json: protected 'quote.totalCents' does not resolve in 'src/quote/types.ts' — renamed or removed? amend the contract
validate: FAILED — project is no-auto-apply until the contracts are amended
$ echo $?
2
```

The block is project-wide, not contract-wide, and it applies to changes that have nothing to
do with the quote:

```
$ contracts.sh classify tests/quote.test.ts
class      C0
auto-apply BLOCKED — project is under a no-auto-apply block: validate found 1 problem(s); see 'contracts.sh validate'
```

A C0 test-file edit is blocked because an unresolved field means the contracts no longer
describe the code, and the blast radius of that is unknown. Fix the contract, run `validate`,
and the block clears itself.

The same applies to a deleted guardrail. Someone removes the clamp in a cleanup, on the
reasonable-looking grounds that the model's output is already in range:

```
$ contracts.sh validate
  FAIL   .contracts/quote-total.json: guardrail 'clamp-to-band' symbol 'clampToBand' is no longer in 'src/quote/clamp.ts' — protection removed?
```

This is why `asserts` is a required field. The person who hits this failure at 6pm needs to
read what they just removed, not go and find out.

## Change D — a surface nothing covers

A change adds `discountCents` to the returned quote.

```
$ contracts.sh classify src/billing/new.ts
files      1 changed
contracts  none touched
undeclared 1 path(s) no contract and no project zone covers:
  src/billing/new.ts
           burden of proof is on the change: unclassifiable is C3
class      C3
auto-apply BLOCKED — C3: output surface no contract covers; file a contract-amendment proposal, do not proceed
```

"No contract covers this" is the trigger, not the permission. The correct output of an
automated system here is a proposal, not a change:

```
Surface found:      quote.discountCents, returned from src/quote/estimate.ts
Reached by:         the change I was about to make to src/quote/pricing.ts
Covered by:         nothing
Evidence:           src/quote/types.ts:14 declares it; src/render/email.ts:9 prints it
Class I would need: C3 — a monetary field on a customer-facing document
Proposed contract:  .contracts/proposed/quote-discount.draft.json
What I did instead: nothing. This is not a permission request for the change; it is a
                    request for someone to say what this number must not do.
```

## Forward amendment: the contract ships with the feature

A new endpoint returns a renewal estimate. The pull request contains the endpoint, its
tests, **and** `.contracts/renewal-estimate.json`. Not a follow-up ticket.

The reason is narrow and practical: the only person who knows what the number means is the
one typing right now. In six months the contract gets written by someone reading the code
and guessing, which produces a confident `why` that is wrong — the worst artefact this format
can hold, because it reads exactly like a right one.

Reviewing the contract is also the cheapest review available. `why` in plain language, the
class of each protected field, and whether anything non-deterministic feeds them. Thirty
seconds, before the diff.

## What the validator cannot tell you

Worth stating plainly, because a tool that overstates its coverage is the problem it claims
to solve:

| it does not | consequence |
|---|---|
| run your code or sample any `bounded` field | the band is declared; your CI must measure it. `validate` only reports when a sampler is missing |
| know whether a `why` is true | only that it exists and is not a placeholder. Reviewers do the rest |
| verify anything across an `externalBoundary` | the tax line is computed elsewhere. The contract says so, and `validate` prints a standing notice instead of a tick |
| distinguish a declaration from a comment in the drift check | it greps for the leaf name. It proves the contract still refers to something that exists, nothing more — which is the weaker claim that actually closes the fail-open hole |
| infer a contract | `discover` proposes with citations. Confirmation is a human act, and an unconfirmed contract grants nothing |

```json
"externalBoundary": [
  { "field": "quote.taxCents", "kind": "service", "verifiable": false,
    "describes": "The figure is computed by a separate tax service and this repo only forwards it. No local check can verify the value; a change here can only be shown not to alter the request we send or the response we accept.",
    "compensating": "A contract test runs against the tax service's sandbox on a schedule, outside this repo's CI. If that test has not passed in 7 days, treat this field as unverified." }
]
```

```
$ contracts.sh validate
  .contracts/tax-line.json: 'quote.taxCents' crosses a service boundary and is NOT locally verifiable
  ok     .contracts/tax-line.json (1 protected · autoApply=never)
```

A notice, every run, forever. A green tick next to an unverifiable field is worse than no
check, for the same reason the renamed field was: it stops people looking.
