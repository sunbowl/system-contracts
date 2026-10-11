# system-contracts — what must not change, in a form a machine can check

A Claude Code skill for codebases that accept automated changes, whether those changes come
from an agent, a dependency bot, or a colleague in a hurry. The usual safety rule is "do not
change behaviour". That rule is on the wrong axis: it forbids the modernisation you want and
permits the drift you fear. What matters is not whether behaviour changed, but whether a
**customer-observable contract** changed.

Swapping a dependency for a faster one that returns the same number is fine. Making a
billing figure move by 2% is a dispute with a customer, and no amount of green tests makes
it fine. The same diff can be either, so the question has to be asked about the **output
surface the change can reach**, never about the change on its own.

Contracts are declared per field, in the repo they protect, at `.contracts/<name>.json`:

| class | touches | default treatment |
|---|---|---|
| C0 Internal | nothing observable | auto-apply allowed |
| C1 Mechanism | same outputs, different means | auto-PR, selective equivalence required |
| C2 Presentation | human-readable text only | auto-PR, human review |
| C3 Contract | a number, a shape, a response field | blocked; explicit human sign-off |
| C4 Security | deliberately changes behaviour | auto-PR, flagged, never silent |

Two rules carry the whole thing. **The classifier's entire job is catching C3 dressed as
C1** — everything else is secondary. And **the burden of proof is on the change: anything
unclassifiable is C3**. No contract declared means nothing auto-applies, because the cost of
a bad change is not the cost of the change, it is the customer relationship.

## Install

Clone into your Claude Code skills directory:

```bash
git clone https://github.com/sunbowl/system-contracts ~/.claude/skills/system-contracts
```

Then, in the repo you want to protect:

```bash
~/.claude/skills/system-contracts/scripts/contracts.sh init
~/.claude/skills/system-contracts/scripts/contracts.sh discover   # legacy codebase? start here
```

The script needs bash and either `jq` or `python3`. Nothing else, so it works in a repo of
any language.

## Layout

```
SKILL.md                     the skill Claude reads
reference.md                 the full schema, class semantics, CI wiring, exit codes
examples.md                  one service worked end to end, including the changes that failed
scripts/contracts.sh         init / validate / classify / discover / status
assets/contract.schema.json  JSON Schema for .contracts/*.json, for editors and CI
examples/quote-total.json    a contract over a non-deterministic monetary field
examples/tax-line.json       a contract that admits it cannot verify itself
```

## The script

```bash
contracts.sh init                      # create .contracts/ with project.json and a template
contracts.sh validate                  # schema + every protected field still resolves; exits 2 on failure
contracts.sh classify --since main     # class, contracts touched, whether it may auto-apply
contracts.sh classify src/a.ts src/b.ts
contracts.sh discover                  # propose contracts from evidence in the code
contracts.sh status                    # what is declared, and whether auto-apply is permitted
```

`validate` is the part that makes this an enforcer rather than another document. It exits
non-zero, and it fails for a reason most contract systems miss: if a protected field has
been renamed, the contract now protects a field that does not exist and every check passes.
A protection that silently stops protecting is worse than none, because people stop looking.
So every protected field must resolve in the code on every run, and the project goes
no-auto-apply until an unresolved one is fixed.

## Companion skill

[Necro](https://github.com/sunbowl/necro) is the descriptive half of the same problem. It
maintains `ARCHITECTURE.md`, a `deprecated/` folder and a deprecation log so that AI tools
stop referencing zombie code. Necro tells an agent what the project *is*; system-contracts
tells it what must not *change*. Necro produces prose for humans and agents to read; this
produces JSON and a validator that exits non-zero. Run both: knowing the architecture does
not stop anyone breaking a billing figure, and a contract does not tell anyone which file is
dead.

## License

MIT — see LICENSE.

## Credits

Developed by [Sunbowl Systems](https://github.com/sunbowl).

---

**Remember:** a rule you cannot check is a hope, and a check that cannot fail is decoration.
