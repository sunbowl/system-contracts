#!/usr/bin/env bash
# contracts.sh — declare, verify and classify changes against system contracts.
#
#   contracts.sh init [--root DIR]
#   contracts.sh validate [--root DIR] [--json]
#   contracts.sh classify [--since REF | --diff FILE | FILE...] [--intent K] [--json]
#   contracts.sh discover [--root DIR] [--limit N] [--out DIR]
#   contracts.sh status [--root DIR] [--json]
#
# Contracts live in the repo they protect, at .contracts/<name>.json, so they are
# versioned with the code and reviewed in the same PR as the change that created them.
#
# Exit codes: 0 ok · 1 usage/environment error · 2 contract or drift failure
#             3 change is blocked from auto-apply (classify only)
#
# Requires: bash, the standard POSIX text utilities (grep sed awk find sort cut tr), and
# one of jq or python3 to read JSON. No language toolchain, so it runs in any repo.
# If anything it needs is missing it exits 1 rather than reporting a clean run.
# MIT licensed. https://github.com/sunbowl/system-contracts

set -eu
# pipefail where available (bash 3.2 has it; POSIX sh may not)
( set -o pipefail ) 2>/dev/null && set -o pipefail

VERSION="1.0.0"
SCHEMA_VERSION=1
US=$(printf '\037')   # field separator for the normalized record stream
EXIT_CODE=0

# ----------------------------------------------------------------------------
# small helpers
# ----------------------------------------------------------------------------
die()  { printf 'contracts: %s\n' "$*" >&2; exit 1; }
warn() { printf '  warn   %s\n' "$*" >&2; }
err()  { printf '  FAIL   %s\n' "$*" >&2; EXIT_CODE=2; }
ok()   { printf '  ok     %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

unesc() { printf '%s' "${1:-}" | sed -e 's/\\n/ /g' -e 's/\\t/ /g' -e 's/\\r/ /g' -e 's/\\\\/\\/g'; }

jesc() { printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'; }

lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }

# leaf name of a dotted field path: quote.totals.totalCents -> totalCents
leaf() { printf '%s' "${1:-}" | sed -e 's/\[\]//g' -e 's/.*\.//'; }

slug() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//'; }

# ----------------------------------------------------------------------------
# JSON engine. One normalized record stream, two interchangeable readers.
#
# Records, US-separated, one per line:
#   K <key> <value>                 scalar metadata
#   P <glob>                        governs.paths entry
#   E <entrypoint>                  governs.entrypoints entry
#   R <field> <class> <locator> <type> <samples> <min> <max> <bandSource> <driftPct>
#     <assertOn> <shape>
#   T <field> <class> <note>        tolerant field
#   G <name> <symbol> <file> <mustExist> <asserts>
#   X <field> <kind> <verifiable> <describes>
#   V <source> <signal>             evidence entry
#   U <key>                         unrecognised top-level key
# ----------------------------------------------------------------------------
JSON_ENGINE="${CONTRACTS_JSON_ENGINE:-}"
detect_engine() {
  case "$JSON_ENGINE" in
    jq|python3) return 0 ;;
    "") ;;
    *) die "CONTRACTS_JSON_ENGINE must be jq or python3 (got '$JSON_ENGINE')" ;;
  esac
  if command -v jq >/dev/null 2>&1; then JSON_ENGINE=jq
  elif command -v python3 >/dev/null 2>&1; then JSON_ENGINE=python3
  else die "needs jq or python3 to read JSON. Install either one."
  fi
}

# A checker that cannot run must say so loudly. Silently finding no contracts because
# a utility is missing is the exact failure mode this tool exists to prevent.
require_tools() {
  missing=""
  for t in grep sed awk find sort uniq cut tr head wc mktemp basename dirname date; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  [ -z "$missing" ] || die "missing required utilities:$missing — refusing to report a clean run"
}

JQ_PROG='
def s: if . == null then "" else tostring end;
def rows:
  ["K","schemaVersion",(.schemaVersion|s)],
  ["K","name",(.name|s)],
  ["K","status",(.status|s)],
  ["K","why",(.why|s)],
  ["K","owner",(.owner|s)],
  ["K","policy.autoApply",(.policy.autoApply|s)],
  ["K","policy.onDriftUnresolved",(.policy.onDriftUnresolved|s)],
  ["K","sampler.command",(.sampler.command|s)],
  ["K","confirmedBy",(.confirmedBy|s)],
  ["K","confirmedAt",(.confirmedAt|s)],
  (.governs.paths // [] | .[] | ["P",(.|s)]),
  (.governs.entrypoints // [] | .[] | ["E",(.|s)]),
  (.protected // [] | .[] | ["R",(.field|s),(.class|s),(.locator|s),(.type|s),
      (.tolerance.samples|s),(.tolerance.band.min|s),(.tolerance.band.max|s),
      (.tolerance.bandSource|s),(.tolerance.meanDriftPct|s),
      (.assertOn|s),(.shape|s)]),
  (.tolerant // [] | .[] | ["T",(.field|s),(.class|s),(.note|s)]),
  (.guardrails // [] | .[] | ["G",(.name|s),(.symbol|s),(.file|s),(.mustExist|s),(.asserts|s)]),
  (.externalBoundary // [] | .[] | ["X",(.field|s),(.kind|s),(.verifiable|s),(.describes|s)]),
  (.evidence // [] | .[] | ["V",(.source|s),(.signal|s)]),
  (keys_unsorted - ["schemaVersion","name","status","why","owner","policy","governs",
      "protected","tolerant","guardrails","externalBoundary","evidence","sampler",
      "confirmedBy","confirmedAt","$schema"] | .[] | ["U",.]);
rows | @tsv
'

PY_PROG='
import json,sys
KNOWN={"schemaVersion","name","status","why","owner","policy","governs","protected",
 "tolerant","guardrails","externalBoundary","evidence","sampler","confirmedBy",
 "confirmedAt","$schema"}
def s(v):
    if v is None: return ""
    if v is True: return "true"
    if v is False: return "false"
    return str(v)
def esc(v):
    return s(v).replace("\\\\","\\\\\\\\").replace("\t","\\\\t").replace("\n","\\\\n").replace("\r","\\\\r")
def emit(*f): sys.stdout.write("\t".join(esc(x) for x in f)+"\n")
def g(d,*path):
    cur=d
    for p in path:
        if not isinstance(cur,dict): return None
        cur=cur.get(p)
    return cur
try:
    d=json.load(open(sys.argv[1]))
except Exception as e:
    sys.stderr.write("parse error: %s\n"%e); sys.exit(1)
if not isinstance(d,dict):
    sys.stderr.write("parse error: top level is not an object\n"); sys.exit(1)
for k in ["schemaVersion","name","status","why","owner"]: emit("K",k,d.get(k))
emit("K","policy.autoApply",g(d,"policy","autoApply"))
emit("K","policy.onDriftUnresolved",g(d,"policy","onDriftUnresolved"))
emit("K","sampler.command",g(d,"sampler","command"))
for k in ["confirmedBy","confirmedAt"]: emit("K",k,d.get(k))
for p in (g(d,"governs","paths") or []): emit("P",p)
for p in (g(d,"governs","entrypoints") or []): emit("E",p)
for r in (d.get("protected") or []):
    r = r if isinstance(r,dict) else {}
    emit("R",r.get("field"),r.get("class"),r.get("locator"),r.get("type"),
         g(r,"tolerance","samples"),g(r,"tolerance","band","min"),g(r,"tolerance","band","max"),
         g(r,"tolerance","bandSource"),g(r,"tolerance","meanDriftPct"),
         r.get("assertOn"),r.get("shape"))
for r in (d.get("tolerant") or []):
    r = r if isinstance(r,dict) else {}
    emit("T",r.get("field"),r.get("class"),r.get("note"))
for r in (d.get("guardrails") or []):
    r = r if isinstance(r,dict) else {}
    emit("G",r.get("name"),r.get("symbol"),r.get("file"),r.get("mustExist"),r.get("asserts"))
for r in (d.get("externalBoundary") or []):
    r = r if isinstance(r,dict) else {}
    emit("X",r.get("field"),r.get("kind"),r.get("verifiable"),r.get("describes"))
for r in (d.get("evidence") or []):
    r = r if isinstance(r,dict) else {}
    emit("V",r.get("source"),r.get("signal"))
for k in d.keys():
    if k not in KNOWN: emit("U",k)
'

# flatten <file> -> normalized record stream on stdout (US-separated)
flatten() {
  detect_engine
  if [ "$JSON_ENGINE" = "jq" ]; then
    jq -r "$JQ_PROG" "$1" 2>/dev/null | tr '\t' "$US"
  else
    python3 -I -c "$PY_PROG" "$1" 2>/dev/null | tr '\t' "$US"
  fi
}

# rec <stream-file> <kind> -> matching lines with the kind column removed
rec() { sed -n "s/^$2$US//p" "$1"; }

# kv <stream-file> <key> -> scalar value for K <key>
kv() {
  awk -v k="$2" -v FS="$US" '$1=="K" && $2==k {print $3; exit}' "$1"
}

# ----------------------------------------------------------------------------
# repo layout
# ----------------------------------------------------------------------------
ROOT=""
resolve_root() {
  require_tools
  if [ -n "$ROOT" ]; then
    [ -d "$ROOT" ] || die "no such directory: $ROOT"
    ROOT=$(cd "$ROOT" && pwd)
  elif ROOT=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$ROOT" ]; then
    :
  else
    ROOT=$(pwd)
  fi
  CDIR="$ROOT/.contracts"
  PROJ="$CDIR/project.json"
  STATE="$CDIR/.state"
  BLOCK="$STATE/no-auto-apply"
  PROPOSED="$CDIR/proposed"
}

require_contracts_dir() {
  [ -d "$CDIR" ] || die "no .contracts/ in $ROOT — run 'contracts.sh init' first"
}

# live contract files: .contracts/*.json except project.json and _*.json
live_contracts() {
  find "$CDIR" -maxdepth 1 -name '*.json' 2>/dev/null \
    | grep -v '/project\.json$' | grep -v '/_' | sort || true
}
proposed_contracts() {
  [ -d "$PROPOSED" ] || return 0
  find "$PROPOSED" -maxdepth 1 -name '*.json' 2>/dev/null | sort || true
}

block_set() {
  mkdir -p "$STATE"
  printf 'no-auto-apply\nset: %s\nreason: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" > "$BLOCK"
}
block_clear() { [ -f "$BLOCK" ] && rm -f "$BLOCK" || true; }
block_reason() { [ -f "$BLOCK" ] && sed -n 's/^reason: //p' "$BLOCK" || true; }

# ----------------------------------------------------------------------------
# glob matching: convert a path glob to an anchored ERE
# ----------------------------------------------------------------------------
glob_to_re() {
  g="$1"; out=""; i=0; n=${#g}
  while [ "$i" -lt "$n" ]; do
    c=$(printf '%s' "$g" | cut -c $((i+1)))
    two=$(printf '%s' "$g" | cut -c $((i+1))-$((i+2)))
    three=$(printf '%s' "$g" | cut -c $((i+1))-$((i+3)))
    case "$c" in
      '*')
        if [ "$three" = '**/' ]; then out="$out(.*/)?"; i=$((i+3)); continue
        elif [ "$two" = '**' ]; then out="$out.*"; i=$((i+2)); continue
        else out="$out[^/]*"; fi ;;
      '?') out="$out[^/]" ;;
      '.'|'+'|'('|')'|'['|']'|'{'|'}'|'^'|'$'|'|'|'\\') out="$out\\$c" ;;
      *) out="$out$c" ;;
    esac
    i=$((i+1))
  done
  printf '^%s$' "$out"
}

path_matches() {  # path_matches <path> <glob>
  printf '%s\n' "$1" | grep -Eq "$(glob_to_re "$2")"
}

norm_path() { printf '%s' "$1" | sed -e 's|^\./||' -e "s|^$ROOT/||"; }

# source files worth searching
SRC_FIND_PRUNE='-name node_modules -o -name .git -o -name dist -o -name build -o -name vendor -o -name target -o -name .next -o -name coverage -o -name __pycache__ -o -name .venv -o -name venv -o -name deprecated -o -name .contracts'
source_files() {
  find "$ROOT" \( $SRC_FIND_PRUNE \) -prune -o -type f -print 2>/dev/null \
    | grep -Ei '\.(ts|tsx|js|jsx|mjs|cjs|py|rb|go|java|kt|cs|php|rs|swift|sql|graphql|gql|prisma|liquid|json|ya?ml)$' \
    | sed -e "s|^$ROOT/||" | sort || true
}

# ----------------------------------------------------------------------------
# validate
# ----------------------------------------------------------------------------
VAL_JSON=0
VAL_REPORT=""

validate_one() {  # validate_one <file> <mode: live|proposed>
  f="$1"; mode="$2"; rel=$(norm_path "$f")
  st=$(mktemp); flatten "$f" > "$st" || true
  if [ ! -s "$st" ]; then
    err "$rel: unreadable or not a JSON object"
    rm -f "$st"; VAL_REPORT="$VAL_REPORT$rel|parse|unreadable or not a JSON object
"
    return
  fi

  name=$(kv "$st" name)
  status=$(kv "$st" status)
  why=$(kv "$st" why)
  sv=$(kv "$st" schemaVersion)
  aa=$(kv "$st" policy.autoApply)
  odu=$(kv "$st" policy.onDriftUnresolved)
  fails=0

  # A draft in proposed/ grants no permission, so its problems cannot fail open:
  # they are reported as work for the human, not as a project-wide failure.
  if [ "$mode" = proposed ]; then
    vfail() { warn "draft $rel: $1"; VAL_REPORT="$VAL_REPORT$rel|$2|$1
"; fails=$((fails+1)); }
  else
    vfail() { err "$rel: $1"; VAL_REPORT="$VAL_REPORT$rel|$2|$1
"; fails=$((fails+1)); }
  fi

  # --- schema ---------------------------------------------------------------
  [ "$sv" = "$SCHEMA_VERSION" ] || vfail "schemaVersion must be $SCHEMA_VERSION (got '${sv:-missing}')" schema
  [ -n "$name" ] || vfail "name is required" schema
  base=$(basename "$f" .json); base=${base%.draft}
  if [ -n "$name" ] && [ "$(slug "$name")" != "$base" ]; then
    warn "$rel: name '$name' does not match filename '$base' — harmless, but harder to grep"
  fi
  case "$status" in
    confirmed|proposed) ;;
    "") vfail "status is required (confirmed | proposed)" schema ;;
    *)  vfail "status '$status' is not confirmed or proposed" schema ;;
  esac
  case "$aa" in
    never|withApproval|allowed) ;;
    "") vfail "policy.autoApply is required (never | withApproval | allowed)" schema ;;
    *)  vfail "policy.autoApply '$aa' is not never, withApproval or allowed" schema ;;
  esac
  case "${odu:-blockProject}" in
    blockProject|blockContract) ;;
    *) vfail "policy.onDriftUnresolved '$odu' is not blockProject or blockContract" schema ;;
  esac

  # why is mandatory: a contract without a stated consequence is a guess
  wplain=$(unesc "$why")
  wlen=$(printf '%s' "$wplain" | wc -c | tr -d ' ')
  if [ -z "$why" ]; then
    vfail "why is required — state the business consequence of breaking this" why
  elif [ "$status" = confirmed ] && printf '%s' "$wplain" | grep -Eqi '^(todo|tbd|fixme|xxx|n/?a)'; then
    vfail "why is still a placeholder; a confirmed contract needs a real consequence" why
  elif [ "$wlen" -lt 25 ]; then
    vfail "why is $wlen characters — too short to name a consequence" why
  fi

  sampler=$(kv "$st" sampler.command)
  nbounded=$(rec "$st" R | awk -v FS="$US" '$2=="bounded"' | grep -c . || true)
  if [ "${nbounded:-0}" -gt 0 ] && [ -z "$sampler" ]; then
    note "$rel: ${nbounded} bounded field(s) and no sampler.command — the band is declared but nothing samples it"
  fi

  npaths=$(rec "$st" P | grep -c . || true)
  [ "${npaths:-0}" -gt 0 ] || vfail "governs.paths must list at least one path glob" schema

  for u in $(rec "$st" U); do warn "$rel: unrecognised top-level key '$u' (ignored)"; done

  # --- protected fields -----------------------------------------------------
  nprot=0
  while IFS="$US" read -r fld cls loc typ samples bmin bmax bsrc drift aon shape; do
    [ -n "${fld:-}" ] || continue
    nprot=$((nprot+1))
    case "${aon:-value}" in
      value|shape|presence) ;;
      *) vfail "protected '$fld' assertOn '$aon' is not value, shape or presence" schema ;;
    esac
    if [ "${aon:-value}" = shape ] && [ -z "${shape:-}" ]; then
      vfail "protected '$fld' asserts on shape but declares no 'shape'" schema
    fi
    if [ "${aon:-value}" = presence ] && [ "$cls" != deterministic ]; then
      vfail "protected '$fld' asserts presence, which is always deterministic (got class '$cls')" schema
    fi
    case "$cls" in
      deterministic)
        if [ -n "${samples:-}${bmin:-}${bmax:-}${bsrc:-}${drift:-}" ]; then
          vfail "protected '$fld' is deterministic but carries a tolerance — drop one" schema
        fi ;;
      bounded)
        if [ -z "${bsrc:-}" ] && { [ -z "${bmin:-}" ] || [ -z "${bmax:-}" ]; }; then
          vfail "protected '$fld' is bounded but has no tolerance.band and no tolerance.bandSource" schema
        fi
        [ -n "${samples:-}" ] || vfail "protected '$fld' is bounded but has no tolerance.samples" schema
        [ -n "${drift:-}" ]   || vfail "protected '$fld' is bounded but has no tolerance.meanDriftPct" schema ;;
      prose) ;;
      "") vfail "protected '$fld' has no class (deterministic | bounded | prose)" schema ;;
      *)  vfail "protected '$fld' class '$cls' is not deterministic, bounded or prose" schema ;;
    esac

    # --- drift / field resolution: the fail-open check ----------------------
    lf=$(leaf "$fld")
    if [ -z "$lf" ]; then
      vfail "protected '$fld' has no resolvable field name" drift
    elif [ -n "${loc:-}" ]; then
      if [ ! -f "$ROOT/$loc" ]; then
        vfail "protected '$fld' locator '$loc' does not exist — field cannot resolve" drift
      elif ! grep -q -- "$lf" "$ROOT/$loc" 2>/dev/null; then
        vfail "protected '$fld' does not resolve in '$loc' — renamed or removed? amend the contract" drift
      fi
    else
      found=0
      for g in $(rec "$st" P); do
        re=$(glob_to_re "$g")
        for cand in $(source_files | grep -E "$re" || true); do
          if grep -q -- "$lf" "$ROOT/$cand" 2>/dev/null; then found=1; break; fi
        done
        [ "$found" = 1 ] && break
      done
      [ "$found" = 1 ] || vfail "protected '$fld' does not resolve anywhere under governs.paths — amend the contract" drift
    fi
  done < <(rec "$st" R)

  # a contract that protects nothing and declares no external boundary protects nothing
  nx=$(rec "$st" X | grep -c . || true)
  if [ "$nprot" -eq 0 ] && [ "${nx:-0}" -eq 0 ]; then
    vfail "no protected fields and no externalBoundary — this contract asserts nothing" schema
  fi

  # --- guardrails -----------------------------------------------------------
  while IFS="$US" read -r gname gsym gfile gmust gassert; do
    [ -n "${gname:-}" ] || continue
    [ -n "${gassert:-}" ] || vfail "guardrail '$gname' has no 'asserts' text" schema
    if [ "${gmust:-true}" != "false" ]; then
      if [ -z "${gsym:-}" ]; then
        vfail "guardrail '$gname' must exist but names no symbol to look for" schema
      elif [ -n "${gfile:-}" ]; then
        if [ ! -f "$ROOT/$gfile" ]; then
          vfail "guardrail '$gname' file '$gfile' is gone — the in-code protection may be too" drift
        elif ! grep -q -- "$gsym" "$ROOT/$gfile" 2>/dev/null; then
          vfail "guardrail '$gname' symbol '$gsym' is no longer in '$gfile' — protection removed?" drift
        fi
      else
        hits=$(source_files | while read -r cand; do grep -lq -- "$gsym" "$ROOT/$cand" 2>/dev/null && echo x; done | grep -c x || true)
        [ "${hits:-0}" -gt 0 ] || vfail "guardrail '$gname' symbol '$gsym' is nowhere in the tree" drift
      fi
    fi
  done < <(rec "$st" G)

  # --- external boundaries --------------------------------------------------
  while IFS="$US" read -r xfld xkind xver xdesc; do
    [ -n "${xfld:-}" ] || continue
    case "$xkind" in
      network|service|vendorSdk|database|queue) ;;
      "") vfail "externalBoundary '$xfld' has no kind (network | service | vendorSdk | database | queue)" schema ;;
      *)  vfail "externalBoundary '$xfld' kind '$xkind' is not a known kind" schema ;;
    esac
    [ -n "${xdesc:-}" ] || vfail "externalBoundary '$xfld' has no 'describes' text" schema
    if [ "${xver:-false}" != "true" ]; then
      note "$rel: '$xfld' crosses a $xkind boundary and is NOT locally verifiable"
    fi
  done < <(rec "$st" X)

  # --- permission ----------------------------------------------------------
  if [ "$status" = proposed ] && [ "$aa" != never ]; then
    vfail "status is proposed but policy.autoApply is '$aa' — an unconfirmed contract grants nothing" policy
  fi

  if [ "$mode" = proposed ] && [ "$fails" -gt 0 ]; then
    printf '  draft  %s has %s thing(s) left for a human — grants no permission meanwhile\n' "$rel" "$fails"
  fi
  if [ "$fails" -eq 0 ]; then
    if [ "$mode" = proposed ]; then ok "$rel (draft, unconfirmed — grants no permission)"
    elif [ "$status" = proposed ]; then ok "$rel ($nprot protected · unconfirmed, grants no permission)"
    else ok "$rel ($nprot protected · autoApply=$aa)"
    fi
  fi
  rm -f "$st"
}

cmd_validate() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) ROOT="${2:-}"; shift 2 ;;
      --json) VAL_JSON=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "validate: unknown option '$1'" ;;
    esac
  done
  resolve_root; require_contracts_dir

  n=0
  if [ -f "$PROJ" ]; then
    if ! validate_project; then :; fi
  else
    warn "no .contracts/project.json — every path outside a contract will classify as C3"
  fi

  for f in $(live_contracts); do n=$((n+1)); validate_one "$f" live; done
  for f in $(proposed_contracts); do validate_one "$f" proposed; done

  if [ "$n" -eq 0 ]; then
    printf '  %s\n' "no contracts declared — nothing auto-applies in this repo"
  fi

  if [ "$EXIT_CODE" -eq 0 ]; then
    block_clear
    printf 'validate: %s contract(s) OK\n' "$n"
  else
    reasons=$(printf '%s' "$VAL_REPORT" | grep -c . || true)
    block_set "validate found ${reasons} problem(s); see 'contracts.sh validate'"
    printf 'validate: FAILED — project is no-auto-apply until the contracts are amended\n' >&2
  fi

  if [ "$VAL_JSON" -eq 1 ]; then
    printf '{"ok":%s,"contracts":%s,"problems":[' "$([ "$EXIT_CODE" -eq 0 ] && echo true || echo false)" "$n"
    first=1
    printf '%s' "$VAL_REPORT" | while IFS='|' read -r pf pk pm; do
      [ -n "${pf:-}" ] || continue
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"file":"%s","kind":"%s","message":"%s"}' "$(jesc "$pf")" "$(jesc "$pk")" "$(jesc "$pm")"
    done
    printf ']}\n'
  fi
  exit "$EXIT_CODE"
}

validate_project() {
  st=$(mktemp); trap 'rm -f "$st"' RETURN 2>/dev/null || true
  detect_engine
  if [ "$JSON_ENGINE" = "jq" ]; then
    jq -e . "$PROJ" >/dev/null 2>&1 || { err "project.json is not valid JSON"; rm -f "$st"; return 1; }
  else
    python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$PROJ" >/dev/null 2>&1 \
      || { err "project.json is not valid JSON"; rm -f "$st"; return 1; }
  fi
  d=$(proj_default)
  case "$d" in C0|C1|C2|C3|"") ;; *) err "project.json default '$d' is not a class" ;; esac
  if [ "$d" = C0 ] || [ "$d" = C1 ] || [ "$d" = C2 ]; then
    warn "project.json default is '$d' — the asymmetric default is C3 for a reason; undeclared surface is unproven"
  fi
  rm -f "$st"; return 0
}

proj_list() {  # proj_list <key> -> globs, one per line
  [ -f "$PROJ" ] || return 0
  detect_engine
  if [ "$JSON_ENGINE" = "jq" ]; then
    jq -r --arg k "$1" '(.[$k] // [])[]' "$PROJ" 2>/dev/null || true
  else
    python3 -I -c 'import json,sys
d=json.load(open(sys.argv[1]))
for x in (d.get(sys.argv[2]) or []): print(x)' "$PROJ" "$1" 2>/dev/null || true
  fi
}
proj_default() {
  [ -f "$PROJ" ] || { printf 'C3'; return; }
  detect_engine
  if [ "$JSON_ENGINE" = "jq" ]; then jq -r '.default // "C3"' "$PROJ" 2>/dev/null || printf 'C3'
  else python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("default","C3"))' "$PROJ" 2>/dev/null || printf 'C3'
  fi
}

# ----------------------------------------------------------------------------
# classify
# ----------------------------------------------------------------------------
CL_JSON=0; CL_INTENT=""; CL_SINCE=""; CL_DIFF=""

class_rank() { case "$1" in C0) echo 0;; C1) echo 1;; C2) echo 2;; C3) echo 3;; C4) echo 4;; *) echo 3;; esac; }

cmd_classify() {
  files=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --root)   ROOT="${2:-}"; shift 2 ;;
      --since)  CL_SINCE="${2:-}"; shift 2 ;;
      --diff)   CL_DIFF="${2:-}"; shift 2 ;;
      --intent) CL_INTENT=$(lower "${2:-}"); shift 2 ;;
      --json)   CL_JSON=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -)        files="$files $(cat)"; shift ;;
      -*)       die "classify: unknown option '$1'" ;;
      *)        files="$files $1"; shift ;;
    esac
  done
  resolve_root; require_contracts_dir

  DIFFTXT=""
  if [ -n "$CL_SINCE" ]; then
    git -C "$ROOT" rev-parse --verify "$CL_SINCE" >/dev/null 2>&1 || die "classify: '$CL_SINCE' is not a git ref"
    files="$files $(git -C "$ROOT" diff --name-only "$CL_SINCE" 2>/dev/null || true)"
    DIFFTXT=$(mktemp); git -C "$ROOT" diff -U0 "$CL_SINCE" > "$DIFFTXT" 2>/dev/null || true
  elif [ -n "$CL_DIFF" ]; then
    if [ "$CL_DIFF" = "-" ]; then DIFFTXT=$(mktemp); cat > "$DIFFTXT"
    else [ -f "$CL_DIFF" ] || die "classify: no such diff file '$CL_DIFF'"; DIFFTXT="$CL_DIFF"
    fi
    files="$files $(sed -n 's|^+++ b/||p' "$DIFFTXT")"
  fi

  [ -n "$(printf '%s' "$files" | tr -d ' ')" ] || die "classify: give changed files, --since REF, or --diff FILE"

  norm=""
  for p in $files; do norm="$norm
$(norm_path "$p")"; done
  norm=$(printf '%s' "$norm" | grep -v '^\.contracts/' | grep . | sort -u || true)

  touched=""      # "contract|file|protectedfields"
  prot_hit=""     # protected fields seen in the diff text
  worst="C0"
  uncovered=""
  blocked_by=""
  policies=""

  for f in $(live_contracts); do
    st=$(mktemp); flatten "$f" > "$st" || true
    [ -s "$st" ] || { rm -f "$st"; continue; }
    cname=$(kv "$st" name); [ -n "$cname" ] || cname=$(basename "$f" .json)
    cstatus=$(kv "$st" status); caa=$(kv "$st" policy.autoApply)
    hit=""
    for p in $norm; do
      for g in $(rec "$st" P); do
        if path_matches "$p" "$g"; then hit="$hit $p"; break; fi
      done
    done
    # A guardrail is where a band or an invariant is DEFINED. Changing it moves the
    # contract without ever naming a protected field — this is C3 in a C1 costume, and
    # catching it is the entire point of the classifier. Guardrail files are checked
    # whether or not they sit under governs.paths.
    ghit=""; gsymhit=""
    while IFS="$US" read -r gn gs gf gm ga; do
      [ -n "${gn:-}" ] || continue
      if [ -n "${gf:-}" ]; then
        for p in $norm; do
          if [ "$p" = "$gf" ] || path_matches "$p" "$gf"; then ghit="$ghit $gn"; break; fi
        done
      fi
      if [ -n "$DIFFTXT" ] && [ -n "${gs:-}" ]; then
        if grep -E '^[+-]' "$DIFFTXT" | grep -v '^[+-][+-]' | grep -q -- "$gs"; then
          gsymhit="$gsymhit $gn"
        fi
      fi
    done < <(rec "$st" G)
    gnames=$(printf '%s%s' "$ghit" "$gsymhit" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]\{1,\}/ /g')

    if [ -n "$hit$gnames" ]; then
      plist=$(rec "$st" R | awk -v FS="$US" '{print $1}' | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')
      touched="$touched
$cname|$(printf '%s' "$hit" | sed 's/^ //')|$plist|$gnames"
      policies="$policies
$cname|$cstatus|$caa"
      # does the diff text name a protected field?
      fieldhit=""
      if [ -n "$DIFFTXT" ]; then
        for fld in $plist; do
          lf=$(leaf "$fld")
          [ -n "$lf" ] || continue
          if grep -E '^[+-]' "$DIFFTXT" | grep -v '^[+-][+-]' | grep -q -- "$lf"; then
            fieldhit="$fieldhit $fld"
          fi
        done
      fi
      if [ -n "$ghit$gsymhit" ]; then
        worst=C3
        prot_hit="$prot_hit$cname: guardrail$(printf '%s' "$ghit$gsymhit" | sed 's/[[:space:]]\{1,\}/ /g') changed — it defines what the protected field may be
"
      fi
      if [ -n "$plist" ] && { [ -z "$DIFFTXT" ] || [ -n "$fieldhit" ]; }; then
        worst=C3
        prot_hit="$prot_hit$cname:$(printf '%s' "${fieldhit:-$plist}" | sed 's/^ //')
"
        blocked_by="$blocked_by$cname "
      else
        [ "$(class_rank "$worst")" -ge 1 ] || worst=C1
      fi
    fi
    rm -f "$st"
  done

  # paths not covered by any contract: project zones decide, default C3
  for p in $norm; do
    covered=0
    for f in $(live_contracts); do
      st=$(mktemp); flatten "$f" > "$st" || true
      for g in $(rec "$st" P); do path_matches "$p" "$g" && covered=1 && break; done
      rm -f "$st"
      [ "$covered" = 1 ] && break
    done
    [ "$covered" = 1 ] && continue
    zone=""
    for g in $(proj_list internal);     do path_matches "$p" "$g" && zone=C0 && break; done
    [ -z "$zone" ] && for g in $(proj_list presentation); do path_matches "$p" "$g" && zone=C2 && break; done
    [ -z "$zone" ] && for g in $(proj_list security);     do path_matches "$p" "$g" && zone=C4 && break; done
    [ -z "$zone" ] && { zone=$(proj_default); [ -n "$zone" ] || zone=C3; uncovered="$uncovered$p
"; }
    [ "$(class_rank "$zone")" -gt "$(class_rank "$worst")" ] && worst="$zone"
  done

  final="$worst"
  if [ "$CL_INTENT" = security ]; then
    if [ "$worst" = C3 ]; then final=C3; else final=C4; fi
  fi

  blocked=no; reason=""
  if [ -f "$BLOCK" ]; then blocked=yes; reason="project is under a no-auto-apply block: $(block_reason)"; fi
  if [ "$blocked" = no ]; then
    case "$final" in
      C3) blocked=yes
          if [ -n "$(printf '%s' "$prot_hit" | tr -d '\n ')" ]; then
            reason="C3: the change reaches a declared contract field; needs explicit human sign-off"
          else
            reason="C3: output surface no contract covers; file a contract-amendment proposal, do not proceed"
          fi ;;
      C4) blocked=no;  reason="C4 deliberately changes behaviour; auto-PR allowed, must be flagged, never silent" ;;
      C2) blocked=no;  reason="C2 presentation; auto-PR with human review" ;;
      C1) blocked=no;  reason="C1 mechanism; auto-PR once selective equivalence passes on the protected fields" ;;
      C0) blocked=no;  reason="C0 internal; auto-apply allowed" ;;
    esac
  fi
  # a contract whose policy forbids auto-apply wins over the class
  while IFS= read -r row; do
    [ -n "${row:-}" ] || continue
    # Already blocked for a stronger reason (C3, or a project-wide drift block)? Keep it.
    [ "$blocked" = no ] || continue
    cn=$(printf '%s' "$row" | cut -d'|' -f1)
    cs=$(printf '%s' "$row" | cut -d'|' -f2)
    ca=$(printf '%s' "$row" | cut -d'|' -f3)
    if [ "$ca" = never ] || [ "$cs" = proposed ]; then
      blocked=yes
      if [ "$cs" = proposed ]; then
        reason="contract '$cn' is unconfirmed — an unconfirmed contract grants no permission; raise a PR"
      else
        reason="contract '$cn' sets autoApply=never — raise a PR, never apply this unattended"
      fi
    fi
  done < <(printf '%s\n' "$policies")

  if [ "$CL_JSON" -eq 1 ]; then
    printf '{"class":"%s","blocked":%s,"reason":"%s","files":[' "$final" \
      "$([ "$blocked" = yes ] && echo true || echo false)" "$(jesc "$reason")"
    i=0; for p in $norm; do [ "$i" -eq 0 ] || printf ','; printf '"%s"' "$(jesc "$p")"; i=1; done
    printf '],"contracts":['
    i=0
    while IFS= read -r row; do
      [ -n "${row:-}" ] || continue
      cn=$(printf '%s' "$row" | cut -d'|' -f1)
      cf=$(printf '%s' "$row" | cut -d'|' -f2)
      cp=$(printf '%s' "$row" | cut -d'|' -f3)
      [ "$i" -eq 0 ] || printf ','
      cg=$(printf '%s' "$row" | cut -d'|' -f4)
      printf '{"contract":"%s","files":"%s","protected":"%s","guardrailsChanged":"%s"}' \
        "$(jesc "$cn")" "$(jesc "$cf")" "$(jesc "$cp")" "$(jesc "$cg")"
      i=1
    done < <(printf '%s\n' "$touched")
    printf '],"undeclared":['
    i=0; for p in $(printf '%s' "$uncovered" | grep . || true); do [ "$i" -eq 0 ] || printf ','; printf '"%s"' "$(jesc "$p")"; i=1; done
    printf ']}\n'
  else
    printf 'files      %s changed\n' "$(printf '%s\n' $norm | grep -c . || true)"
    if [ -n "$(printf '%s' "$touched" | tr -d '\n ')" ]; then
      printf 'contracts  touched:\n'
      while IFS= read -r row; do
        [ -n "${row:-}" ] || continue
        printf '  %-22s protected: %s\n' "$(printf '%s' "$row" | cut -d'|' -f1)" \
          "$(printf '%s' "$row" | cut -d'|' -f3 | sed -e 's/[[:space:]]*$//')"
      done < <(printf '%s\n' "$touched")
    else
      printf 'contracts  none touched\n'
    fi
    if [ -n "$DIFFTXT" ] && [ -n "$(printf '%s' "$prot_hit" | tr -d '\n ')" ]; then
      printf 'reached     %s\n' \
        "$(printf '%s' "$prot_hit" | tr '\n' ';' | sed -e 's/;*$//' -e 's/;/; /g' -e 's/[[:space:]]\{1,\}/ /g')"
    fi
    if [ -n "$(printf '%s' "$uncovered" | tr -d '\n ')" ]; then
      printf 'undeclared %s path(s) no contract and no project zone covers:\n' "$(printf '%s\n' $uncovered | grep -c . || true)"
      for p in $(printf '%s' "$uncovered" | grep . || true); do printf '  %s\n' "$p"; done
      printf '           burden of proof is on the change: unclassifiable is C3\n'
    fi
    [ -z "$DIFFTXT" ] && [ -n "$(printf '%s' "$touched" | tr -d '\n ')" ] && \
      printf 'note       file-level input only — C1 is unreachable without a diff; pass --since or --diff\n'
    printf 'class      %s\n' "$final"
    printf 'auto-apply %s — %s\n' "$([ "$blocked" = yes ] && echo BLOCKED || echo allowed)" "$reason"
  fi

  [ "$blocked" = yes ] && exit 3
  exit 0
}

# ----------------------------------------------------------------------------
# discover
# ----------------------------------------------------------------------------
RE_MONEY='(amount|total|subtotal|price|cost|fee|rate|charge|balance|credit|discount|tax|cents|currency|invoice|payment|payout|refund|estimate|quote)'
RE_QTY='(quantity|qty|count|units|hours|minutes|points|tokens|limit|quota|seats|weight|size)'
RE_IDENT='([A-Za-z]Id|_id|sku|reference|refNo|orderNumber|invoiceNumber|accountNumber|slug)'
RE_CLAMP='(clamp|clampTo|clampToBand|Math\.(min|max)|bound|withinBand|inRange|invariant|assert|sanityCheck|mustBe|guard[A-Z]|validate[A-Z]|precondition)'
RE_SCHEMA='(CREATE TABLE|ALTER TABLE|migration|prisma|res\.json|response\.json|NextResponse\.json|JsonResponse|webhook|openapi|swagger|@Column|serializer|toJSON)'
RE_TEST='(toBe\(|toEqual\(|toStrictEqual\(|assertEquals|assert_equal|assertEqual|expect\(.*\)\.to|assert .*==)'
RE_NONDET='(Math\.random|Date\.now|new Date\(|uuid|randomUUID|messages\.create|chat\.completions|generateText|invokeModel|fetch\(|axios\.|requests\.(get|post)|http\.)'

DISC_LIMIT=12; DISC_OUT=""

disc_hits() { # disc_hits <regex> -> "file:line:text"
  source_files | while read -r f; do
    grep -nEI -- "$1" "$ROOT/$f" 2>/dev/null | head -8 | sed -e "s|^|$f:|"
  done
}

cmd_discover() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --root)  ROOT="${2:-}"; shift 2 ;;
      --limit) DISC_LIMIT="${2:-12}"; shift 2 ;;
      --out)   DISC_OUT="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "discover: unknown option '$1'" ;;
    esac
  done
  resolve_root
  OUT="${DISC_OUT:-$PROPOSED}"
  mkdir -p "$OUT"

  tmp=$(mktemp -d)
  for pair in "money:$RE_MONEY" "quantity:$RE_QTY" "identifier:$RE_IDENT" \
              "guardrail:$RE_CLAMP" "schema:$RE_SCHEMA" "pinned-test:$RE_TEST" \
              "nondeterminism:$RE_NONDET"; do
    sig=${pair%%:*}; re=${pair#*:}
    disc_hits "$re" > "$tmp/$sig" 2>/dev/null || true
  done

  # candidates: files carrying money/quantity/identifier fields or an existing guardrail
  cat "$tmp/money" "$tmp/quantity" "$tmp/identifier" "$tmp/guardrail" 2>/dev/null \
    | cut -d: -f1 | grep -v -Ei '(test|spec|\.min\.|lock)' | sort | uniq -c | sort -rn \
    | awk '{print $2}' | head -"$DISC_LIMIT" > "$tmp/candidates" || true

  md="$OUT/DISCOVERY.md"
  {
    printf '# Contract discovery — UNCONFIRMED\n\n'
    printf 'Generated %s by `contracts.sh discover` over `%s`.\n\n' "$(date '+%Y-%m-%d %H:%M')" "$(basename "$ROOT")"
    printf 'Everything here is a **proposal from evidence**, not a finding. Nothing in this\n'
    printf 'directory grants auto-apply permission. A draft becomes a contract when a human\n'
    printf 'writes the `why`, sets `status` to `confirmed`, and moves it to `.contracts/`.\n\n'
    printf '## Evidence\n\n'
    for sig in money quantity identifier guardrail schema pinned-test nondeterminism; do
      c=$(grep -c . "$tmp/$sig" 2>/dev/null || true)
      printf '### %s (%s hit(s))\n\n' "$sig" "${c:-0}"
      case "$sig" in
        money)          printf 'Follow the money first. A monetary field that drifts is a billing dispute.\n\n' ;;
        quantity)       printf 'Quantities feed invoices and entitlements.\n\n' ;;
        identifier)     printf 'Identifiers are joined on by other systems; a changed shape breaks them silently.\n\n' ;;
        guardrail)      printf 'Highest signal in any codebase: a previous author already decided this must not drift.\n\n' ;;
        schema)         printf 'Persisted or externally visible shapes. Other people parse these.\n\n' ;;
        pinned-test)    printf 'Someone cared enough to pin an exact value.\n\n' ;;
        nondeterminism) printf 'Sources of variance. Any protected field downstream of these is `bounded`, never `deterministic`.\n\n' ;;
      esac
      if [ "${c:-0}" -gt 0 ]; then
        printf '| where | line |\n|---|---|\n'
        head -40 "$tmp/$sig" | while IFS= read -r h; do
          loc=$(printf '%s' "$h" | cut -d: -f1-2)
          txt=$(printf '%s' "$h" | cut -d: -f3- | sed -e 's/|/\\|/g' -e 's/^[[:space:]]*//' | cut -c1-110)
          printf '| `%s` | `%s` |\n' "$loc" "$txt"
        done
        printf '\n'
      fi
    done
    printf '## Candidate contracts\n\n'
    printf 'One draft per file below, in `%s`. Confirm or delete each one.\n\n' "$(norm_path "$OUT")"
    printf '| draft | from | evidence |\n|---|---|---|\n'
  } > "$md"

  ndraft=0
  while read -r cf; do
    [ -n "${cf:-}" ] || continue
    nm=$(slug "$(basename "$cf" | sed -e 's/\.[^.]*$//')")
    [ -n "$nm" ] || continue
    sigs=""
    for sig in money quantity identifier guardrail schema nondeterminism; do
      grep -q "^$cf:" "$tmp/$sig" 2>/dev/null && sigs="$sigs $sig"
    done
    nd=no; printf '%s' "$sigs" | grep -q nondeterminism && nd=yes
    cls=deterministic; [ "$nd" = yes ] && cls=bounded

    # candidate field names from the money/quantity/identifier hits in this file
    flds=$(grep "^$cf:" "$tmp/money" "$tmp/quantity" "$tmp/identifier" 2>/dev/null \
            | cut -d: -f3- \
            | grep -oE "[A-Za-z0-9_]*$RE_MONEY[A-Za-z0-9_]*|[A-Za-z0-9_]*$RE_QTY[A-Za-z0-9_]*|[A-Za-z0-9_]*$RE_IDENT[A-Za-z0-9_]*" \
            | grep -vE '^(quote|total|amount|estimate|credit|rate|size|limit|count)$' \
            | sort -u | head -6 || true)
    [ -n "$flds" ] || flds=$(printf 'TODO_field_name')

    gsym=$(grep "^$cf:" "$tmp/guardrail" 2>/dev/null | cut -d: -f3- \
            | grep -oE "$RE_CLAMP[A-Za-z0-9_]*" | awk '{print length, $0}' | sort -rn \
            | head -1 | cut -d' ' -f2- || true)

    draft="$OUT/$nm.draft.json"
    {
      printf '{\n'
      printf '  "schemaVersion": %s,\n' "$SCHEMA_VERSION"
      printf '  "name": "%s",\n' "$nm"
      printf '  "status": "proposed",\n'
      printf '  "why": "TODO — state the business consequence of this output changing. A contract without a stated consequence is a guess; delete this draft if you cannot name one.",\n'
      printf '  "governs": { "paths": ["%s"] },\n' "$cf"
      printf '  "protected": [\n'
      i=0
      for fl in $flds; do
        [ "$i" -eq 0 ] || printf ',\n'
        printf '    { "field": "%s", "locator": "%s", "class": "%s"' "$fl" "$cf" "$cls"
        if [ "$cls" = bounded ]; then
          printf ',\n      "tolerance": { "samples": 5, "band": { "min": null, "max": null }, "meanDriftPct": 2.0 }'
          printf ',\n      "_note": "class is bounded because this file also contains a non-deterministic source; set a real band"'
        fi
        printf ' }'
        i=$((i+1))
      done
      printf '\n  ],\n'
      printf '  "tolerant": [],\n'
      if [ -n "${gsym:-}" ]; then
        printf '  "guardrails": [\n'
        printf '    { "name": "%s", "symbol": "%s", "file": "%s", "mustExist": true,\n' "$(slug "$gsym")" "$gsym" "$cf"
        printf '      "asserts": "TODO — what does this existing in-code check guarantee? Someone wrote it on purpose." }\n'
        printf '  ],\n'
      else
        printf '  "guardrails": [],\n'
      fi
      printf '  "externalBoundary": [],\n'
      printf '  "policy": { "autoApply": "never", "onDriftUnresolved": "blockProject" },\n'
      printf '  "evidence": [\n'
      i=0
      for sig in money quantity identifier guardrail schema pinned-test nondeterminism; do
        h=$(grep -m2 "^$cf:" "$tmp/$sig" 2>/dev/null || true)
        [ -n "$h" ] || continue
        printf '%s' "$h" | while IFS= read -r one; do
          [ -n "${one:-}" ] || continue
          printf '    { "source": "%s", "signal": "%s" },\n' "$(printf '%s' "$one" | cut -d: -f1-2)" "$sig"
        done
      done
      printf '    { "source": "discover", "signal": "unconfirmed draft" }\n'
      printf '  ]\n}\n'
    } > "$draft"
    printf '| `%s` | `%s` | %s |\n' "$(basename "$draft")" "$cf" "$(printf '%s' "$sigs" | sed 's/^ //')" >> "$md"
    ndraft=$((ndraft+1))
  done < "$tmp/candidates"

  {
    printf '\n## What a human has to do with each draft\n\n'
    printf '1. Read the cited evidence. It is a file and a line; it takes seconds.\n'
    printf '2. Write the `why`, or delete the draft. No consequence, no contract.\n'
    printf '3. Fix the `class`. If any non-deterministic source feeds the field, it is `bounded`\n'
    printf '   and needs a real band — an exact-equality assertion on a non-deterministic field\n'
    printf '   fails on untouched code and teaches everyone to ignore the checker.\n'
    printf '4. Set `status` to `confirmed`, move the file to `.contracts/`, and commit it in the\n'
    printf '   same PR as whatever made you look.\n'
    printf '5. Run `contracts.sh validate`.\n'
  } >> "$md"

  rm -rf "$tmp"
  printf 'discover: %s draft(s) and DISCOVERY.md written to %s\n' "$ndraft" "$(norm_path "$OUT")"
  printf '          drafts are unconfirmed and grant no auto-apply permission\n'
}

# ----------------------------------------------------------------------------
# status
# ----------------------------------------------------------------------------
cmd_status() {
  SJSON=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) ROOT="${2:-}"; shift 2 ;;
      --json) SJSON=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "status: unknown option '$1'" ;;
    esac
  done
  resolve_root
  if [ ! -d "$CDIR" ]; then
    printf 'no .contracts/ in %s — nothing is declared, so nothing auto-applies\n' "$ROOT"
    exit 0
  fi
  nlive=0; nconf=0; nprop=0; nprot=0; next=0; nguard=0
  rows=""
  for f in $(live_contracts); do
    st=$(mktemp); flatten "$f" > "$st" || true
    [ -s "$st" ] || { rm -f "$st"; nlive=$((nlive+1)); rows="$rows
$(basename "$f")|UNREADABLE|-|-|-"; continue; }
    nlive=$((nlive+1))
    nm=$(kv "$st" name); sta=$(kv "$st" status); aa=$(kv "$st" policy.autoApply)
    p=$(rec "$st" R | grep -c . || true); x=$(rec "$st" X | grep -c . || true); g=$(rec "$st" G | grep -c . || true)
    nprot=$((nprot+${p:-0})); next=$((next+${x:-0})); nguard=$((nguard+${g:-0}))
    [ "$sta" = confirmed ] && nconf=$((nconf+1)) || nprop=$((nprop+1))
    rows="$rows
${nm:-$(basename "$f")}|$sta|$aa|${p:-0}|${x:-0}"
    rm -f "$st"
  done
  ndraft=$(proposed_contracts | grep -c . || true)
  blocked=no; [ -f "$BLOCK" ] && blocked=yes

  if [ "$SJSON" -eq 1 ]; then
    printf '{"root":"%s","contracts":%s,"confirmed":%s,"proposed":%s,"drafts":%s,' \
      "$(jesc "$ROOT")" "$nlive" "$nconf" "$nprop" "${ndraft:-0}"
    printf '"protectedFields":%s,"externalBoundaries":%s,"guardrails":%s,"noAutoApply":%s,"reason":"%s"}\n' \
      "$nprot" "$next" "$nguard" "$([ "$blocked" = yes ] && echo true || echo false)" "$(jesc "$(block_reason)")"
    exit 0
  fi

  printf 'root       %s\n' "$ROOT"
  printf 'contracts  %s live (%s confirmed, %s proposed) · %s draft(s) awaiting review\n' \
    "$nlive" "$nconf" "$nprop" "${ndraft:-0}"
  printf 'protected  %s field(s) · %s guardrail(s) asserted · %s external boundary/ies\n' "$nprot" "$nguard" "$next"
  if [ "$nlive" -gt 0 ]; then
    printf '\n%-24s %-10s %-13s %-9s %s\n' CONTRACT STATUS AUTO-APPLY PROTECTED EXTERNAL
    while IFS= read -r row; do
      [ -n "${row:-}" ] || continue
      printf '%-24s %-10s %-13s %-9s %s\n' \
        "$(printf '%s' "$row" | cut -d'|' -f1)" "$(printf '%s' "$row" | cut -d'|' -f2)" \
        "$(printf '%s' "$row" | cut -d'|' -f3)" "$(printf '%s' "$row" | cut -d'|' -f4)" \
        "$(printf '%s' "$row" | cut -d'|' -f5)"
    done < <(printf '%s\n' "$rows")
  fi
  printf '\n'
  if [ "$blocked" = yes ]; then
    printf 'NO-AUTO-APPLY  %s\n' "$(block_reason)"
    printf '               amend the contracts, then run: contracts.sh validate\n'
  elif [ "$nlive" -eq 0 ]; then
    printf 'NO-AUTO-APPLY  nothing is declared, so nothing may be applied automatically\n'
    printf '               run "contracts.sh discover" to propose contracts from the code\n'
  else
    printf 'auto-apply     permitted for the classes project.json allows (run validate to refresh)\n'
  fi
}

# ----------------------------------------------------------------------------
# init
# ----------------------------------------------------------------------------
cmd_init() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) ROOT="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "init: unknown option '$1'" ;;
    esac
  done
  resolve_root
  [ -d "$CDIR" ] && die ".contracts/ already exists in $ROOT"
  mkdir -p "$CDIR" "$STATE" "$PROPOSED"
  printf '*\n!.gitignore\n' > "$STATE/.gitignore"

  cat > "$PROJ" <<'PJ'
{
  "schemaVersion": 1,
  "project": "PROJECT_NAME",
  "default": "C3",
  "internal": [
    "**/*.test.*",
    "**/*.spec.*",
    "**/__tests__/**",
    "docs/**",
    "scripts/**"
  ],
  "presentation": [],
  "security": []
}
PJ
  sed -i.bak "s/PROJECT_NAME/$(basename "$ROOT")/" "$PROJ" && rm -f "$PROJ.bak"

  cat > "$CDIR/README.md" <<'CR'
# .contracts/

Machine-checkable statements of what must not change in this repo, and why.

Each `*.json` here is one contract: the output surface it governs, the fields that are
protected, the determinism class of each protected field, and the business consequence of
breaking it. They live in this repo so they are versioned with the code and reviewed in the
same pull request as the change that created them.

| | |
|---|---|
| `project.json` | which paths are internal, presentational or security-relevant; the default class for everything else |
| `<name>.json` | one contract |
| `proposed/` | drafts from `contracts.sh discover` — unconfirmed, grant nothing |
| `.state/` | derived local state, not committed |

```bash
contracts.sh validate    # schema + every protected field still resolves. Non-zero on failure.
contracts.sh status      # what is declared and whether auto-apply is permitted
contracts.sh classify --since main
```

Rules that matter more than the format:

- The `why` is mandatory. A contract without a stated consequence is a guess.
- If a protected field stops resolving in the code, the whole project goes no-auto-apply
  until the contract is amended. A protection that silently stops protecting is worse than
  no protection, because people stop looking.
- Anything no contract covers is C3: blocked, needs a human. The burden of proof is on the
  change.
CR

  cat > "$CDIR/_template.json" <<'TPL'
{
  "schemaVersion": 1,
  "name": "contract-name",
  "status": "proposed",
  "why": "What breaks for a customer, in one or two plain sentences, if this output changes.",
  "owner": "team-or-person",
  "governs": {
    "paths": ["src/thing/**"],
    "entrypoints": ["theFunctionOrRoute"]
  },
  "protected": [
    { "field": "result.amountCents", "locator": "src/thing/types.ts", "class": "deterministic", "type": "money" },
    { "field": "result.reference", "locator": "src/thing/types.ts", "class": "deterministic",
      "type": "identifier", "assertOn": "shape", "shape": "^[A-Z]{3}-[0-9]{6}$" }
  ],
  "tolerant": [
    { "field": "result.explanation", "class": "prose", "note": "wording may change; shorter is better" }
  ],
  "guardrails": [],
  "externalBoundary": [],
  "sampler": { "command": "" },
  "policy": { "autoApply": "never", "onDriftUnresolved": "blockProject" }
}
TPL

  printf 'init: created %s\n' "$(norm_path "$CDIR")"
  printf '  project.json    declare internal / presentation / security zones\n'
  printf '  _template.json  copy it to <name>.json to write the first contract\n'
  printf '  proposed/       contracts.sh discover writes drafts here\n'
  printf '\nNext: run "contracts.sh discover" on an existing codebase, or copy the template.\n'
  printf 'Until a contract exists, nothing in this repo may be applied automatically.\n'
}

# ----------------------------------------------------------------------------
usage() {
  cat <<'U'
contracts.sh — declare, verify and classify changes against system contracts

  contracts.sh init [--root DIR]
      Create .contracts/ with project.json, a contract template and proposed/.

  contracts.sh validate [--root DIR] [--json]
      Check every contract against its schema AND check that every protected field
      and asserted guardrail still resolves in the code. Exits 2 on failure and puts
      the project under a no-auto-apply block until the contracts are amended.

  contracts.sh classify [FILE...] [--since REF] [--diff FILE|-] [--intent security] [--json]
      Report the change class (C0..C4), the contracts touched and whether the change
      may be applied automatically. Exits 3 when blocked.
      File names alone cannot reach C1 — pass --since or --diff for that.

  contracts.sh discover [--root DIR] [--limit N] [--out DIR]
      Propose candidate contracts from evidence in the code, with that evidence cited.
      Writes unconfirmed drafts; grants no permission.

  contracts.sh status [--root DIR] [--json]
      What is declared, and whether auto-apply is currently permitted.

Classes: C0 internal · C1 mechanism · C2 presentation · C3 contract · C4 security
Anything unclassifiable is C3.
U
}

case "${1:-}" in
  init)     shift; cmd_init "$@" ;;
  validate) shift; cmd_validate "$@" ;;
  classify) shift; cmd_classify "$@" ;;
  discover) shift; cmd_discover "$@" ;;
  status)   shift; cmd_status "$@" ;;
  -v|--version) printf 'contracts.sh %s (schema %s)\n' "$VERSION" "$SCHEMA_VERSION" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown subcommand '$1' (try --help)" ;;
esac
