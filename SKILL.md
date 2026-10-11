---
name: system-contracts
description: Field-level contracts declaring what must not change in a codebase, plus a validator that enforces them, so automated changes can be classified instead of blanket-forbidden. Use when deciding whether a change is safe to apply, merge or auto-commit, and when the answer has to be defensible. Activates on "is this safe to change", "will this break anything", "is this a breaking change", "can we auto-apply this", "behaviour change", "equivalence test", "what must not change", "protected field", "contract", ".contracts/", "classify this change", "C3", "drift", "fail open", "blast radius", "output surface", "onboard a legacy codebase", "what is an agent allowed to change here", "why did the pipeline block this". Also use before letting any automated system commit to a repo, when a protected value is produced non-deterministically (an LLM call, randomness, time, a network read), and when a change touches money, quantities, identifiers, API response shapes or persisted schemas.
---

# System Contracts

A contract is a written, machine-checkable statement that a particular output must not
change, and what it costs if it does. This skill defines the format, the classification that
decides how much proof a change needs, and the enforcement that makes both real.

## The axis

The common safety rule for automated change is "never change behaviour", usually enforced by
asking a model to write an equivalence test. It fails in both directions:

- It blocks every worthwhile modernisation. Replacing a slow call with a fast one changes
  behaviour by construction. Under that rule nothing ever ships.
- It passes changes that break what people are actually paid for, because an equivalence
  test written by the same process that wrote the change tests the mechanism it just built.

The useful question is narrower. Not *did behaviour change* but *did a customer-observable
contract change*. Two changes, same shape, opposite verdicts:

| change | mechanism | contract | verdict |
|---|---|---|---|
| swap an LLM call from an older model generation to a newer one — cheaper, faster, terser prose, same computed value | changed | intact | ship it |
| anything that makes a billing estimate inflate or deflate | may be unchanged | broken | catastrophic; it is a dispute with a customer |

The second is not worse because the diff is bigger. It is worse because of **what the output
reaches**. So classification is made against the output surface the change can reach, never
against the change itself.

## Contracts are field-level

Modules are the wrong granularity. A single returned object routinely holds fields with
incompatible tolerances:

| field | kind | tolerance |
|---|---|---|
| `totalCents` | money | zero drift |
| `reasoning` | prose | free; terser is better |
| `confidenceScore` | advisory telemetry | bounded |

One rule for that object is either so strict that nothing ships or so loose that the money
moves. Contracts are therefore declared per field.

## Contracts live in the repo they protect

`.contracts/<name>.json`, committed alongside the code. Not in a central registry, not in a
wiki. Two reasons: the contract is versioned with the thing it describes, and it is reviewed
in the same pull request as the feature that created it, by the person who knows what the
output means.

```
.contracts/
  project.json         internal / presentation / security path zones, and the default class
  quote-total.json     one contract
  proposed/            drafts from `discover` — unconfirmed, grant nothing
  .state/              derived local state, not committed
```

A contract names, at minimum: what it governs, which fields are protected, the determinism
class of each, and **`why`** — the business consequence of breaking it, in plain language.
The `why` is mandatory and the validator rejects a placeholder. A contract without a stated
consequence is a guess, and nobody can review a guess. See `reference.md` for every field.

## Determinism class selects the assertion

The decisive case: the protected monetary field may itself be produced non-deterministically
— by a model call, a clock, a random source, a network read. Two runs of **unmodified** code
return different numbers. "Assert the protected field is identical" is then not merely hard,
it is the wrong assertion, and it fails on untouched code. A check that cries wolf on a
no-op gets switched off within a week, and then nothing is protected at all.

| class | assertion | use when |
|---|---|---|
| `deterministic` | exact equality | the value is computed, not generated |
| `bounded` | N samples; the band holds for every sample; mean drift within tolerance | anything non-deterministic feeds the field |
| `prose` | the diff is reported, never fails | human-readable text |

For `bounded`, the pattern that works is one most codebases already contain somewhere:
**let the mechanism vary, pin the contract to a band, and report the deviation.** A helper
that clamps a generated number into a deterministic band per scope and logs whenever it had
to clamp is not a workaround; it is the contract, expressed in code. When such a helper
exists, the contract should assert it still exists — see `guardrails` in `reference.md`. The
band is the hard assertion; `meanDriftPct` catches the systematic shift that stays inside
the band, which the band alone would miss.

## The five classes

| class | touches | default |
|---|---|---|
| C0 Internal | nothing observable | auto-apply allowed |
| C1 Mechanism | same outputs, different means | auto-PR, selective equivalence required |
| C2 Presentation | human-readable text only | auto-PR, human review |
| C3 Contract | a number, a shape, a response field | blocked; explicit human sign-off |
| C4 Security | deliberately changes behaviour | auto-PR, flagged, never silent |

**The classifier's entire job is catching C3 dressed as C1.** A change that presents itself
as a mechanism swap and quietly moves a protected number is the only failure that costs real
money. Misfiling C0 as C2 wastes a review; missing one C3 ends a relationship. Spend the
effort accordingly.

**The burden of proof is on the change. Anything unclassifiable is C3.** No contract
declared means nothing auto-applies. This default is deliberately asymmetric: the cost of a
bad change is not the cost of the change, it is the customer relationship. The cost of an
unnecessary review is twenty minutes.

"Selective equivalence" in C1 means asserting the contract's protected fields, at their
declared classes, and nothing else. Not whole-output equality — that is the rule this skill
replaces, and it is what makes a terser, cheaper, better implementation look like a failure.

## Classification runs cheapest first

1. **Deterministic intersection** — do the changed paths meet a contract's `governs.paths`,
   and does the diff name a protected field? Free, no model, no network, fully reproducible.
   **This is the layer that catches the costume.** Run it always; it is `contracts.sh
   classify`.
2. **A calibrated classifier** — optional. Only worth adding once you have labelled history
   to calibrate against, and only as a tie-breaker that can raise a class, never lower it.
3. **An adversarial review** — optional. One reviewer, instructed to find the output surface
   the change reaches that the author did not mention. Expensive; reserve it for C3 sign-off.

Layers 2 and 3 are vendor-neutral and optional by design. Layer 1 decides the cases that
matter and requires nothing but the contracts.

## Drift: the fail-open bug

This is the failure mode that makes most protection systems worthless, and it is silent.

A protected field is renamed `totalCents` → `amountCents`. The contract still names
`totalCents`. Nothing in the code matches it, so there is nothing to compare, so **every
check passes**. The dashboard is green. The field is unprotected and has been for months.

A protection that silently stops protecting is worse than no protection, because people stop
looking.

The rule, which is not optional and not configurable:

- Every protected field in every contract must **resolve in the code on every run**.
- Every guardrail the contract asserts must still be present, by symbol, in its file.
- If one does not resolve, the **project** goes no-auto-apply until the contract is amended.
  Not that contract — the project. An unresolved field means the contracts no longer describe
  the code, and the blast radius of that is unknown.
- `contracts.sh validate` exits non-zero and writes the block. It is a required gate, not a
  report. The same applies to the checker itself: if a utility it needs is missing, it
  refuses to report a clean run rather than finding zero contracts and passing.

## Onboarding a legacy codebase

The common case: a shipped codebase arrives with no contracts and nobody who remembers
writing it. Guessing contracts from the outside produces confident fiction. Instead, propose
from evidence and make a human confirm. `contracts.sh discover` does this; the evidence it
weighs, in order of signal:

| evidence | why it is evidence |
|---|---|
| existing clamps, bands, validators, sanity checks, assertions, invariants | **highest signal in any codebase.** A previous author already decided this must not drift. They were there; you were not. |
| monetary, quantity and identifier fields in returned types and API responses | follow the money first — a monetary field that drifts is a billing dispute |
| persisted and externally visible schemas: migrations, webhook and API response shapes | other systems parse these; a changed shape breaks them silently and elsewhere |
| tests asserting exact values | someone cared enough to pin a number |
| non-deterministic sources feeding otherwise-protected outputs | where `bounded` is mandatory and naive equality will produce false failures |

**Discovery proposes, never asserts.** Output is a reviewable draft, clearly marked
unconfirmed, with the file and line for each proposal cited so a human can check it in
seconds. An unconfirmed contract grants no auto-apply permission; if anything, it is proof
that the surface is undeclared and therefore C3.

For each draft a human does four things: read the cited evidence, write the `why` or delete
the draft, fix the class (anything downstream of a non-deterministic source is `bounded`),
then set `status` to `confirmed` and move it into `.contracts/`.

## Amendment, in both directions

Contracts rot as code moves unless amendment is part of normal work.

**Forward — feature work writes the contract.** When a change creates or changes an
observable output, the contract is written or amended in the same pull request. The contract
is a deliverable of the feature, like a test or a migration, not paperwork afterwards. The
person who knows what the number means is the person typing, right now, and will not be
available in six months.

**Backward — automation proposes, never assumes.** When an automated system meets an output
surface no contract covers, it stops and files a contract-amendment proposal: the surface it
found, the evidence, and the class it would have needed. It does not proceed on the grounds
that no contract forbade it. "No contract covers this" is the C3 trigger, not a permission.

## The script

```bash
scripts/contracts.sh init                   # create .contracts/
scripts/contracts.sh validate               # schema + drift; exit 2 on failure; writes the block
scripts/contracts.sh classify --since main  # class, contracts touched, auto-apply verdict; exit 3 if blocked
scripts/contracts.sh classify path/a.ts     # file-level only; cannot reach C1 by design
scripts/contracts.sh discover               # evidence-cited drafts in .contracts/proposed/
scripts/contracts.sh status                 # what is declared, and whether auto-apply is permitted
```

Run `validate` in CI on every pull request, and before every automated commit. Treat a
non-zero exit as a blocked merge. Exit codes and CI wiring are in `reference.md`.

## When asked whether a change is safe

1. Run `contracts.sh validate`. If it fails, stop. The contracts do not describe the code,
   so nothing can be said about safety until they do.
2. Run `contracts.sh classify` with a real diff, not a file list.
3. Name the output surface the change reaches, in one sentence, and say which contract covers
   it. If no contract covers it, say so plainly — that is C3, and the answer is a
   contract-amendment proposal rather than a verdict.
4. For C1, state which protected fields the equivalence check asserts and at which class. For
   `bounded` fields, give the band and where it comes from.
5. Never report a change as safe because the tests passed. The tests were written against
   the mechanism.

## See also

- `reference.md` — the full schema, every field, class semantics, `project.json`, policy,
  external boundaries, exit codes, CI wiring
- `examples.md` — one service worked end to end, including the changes that failed
- [Necro](https://github.com/sunbowl/necro) — the descriptive companion: what the project
  *is*, where this skill covers what must not *change*
