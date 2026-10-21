#!/usr/bin/env python3
"""Move one arm to a new state in the run-state file.

    ./deploy/lib-state-set.py <arm> <pending|launched|collected|aborted> [outcome text]

The file is $STATE, which deploy/lib-config.sh exports. Every caller sources it first.

Called by 60-run-arm.sh at launch and finish, and by 71-park.sh. The state file is the only
thing that survives a laptop shutdown carrying the truth, so writing it is part of the work,
not a report afterwards: "launched" is how the park script knows a population is still billing.

An unknown arm name is an error, not a no-op. A typo that updates nothing is how a later
session reads "pending" for an arm that already ran.
"""
import datetime
import json
import os
import pathlib
import sys

VALID = {"pending", "launched", "collected", "aborted"}

_state = os.environ.get("STATE")
if not _state:
    sys.exit("STATE is not set. Source deploy/lib-config.sh first, or run ./deploy/setup.sh.")
STATE_PATH = pathlib.Path(_state)
if not STATE_PATH.is_file():
    sys.exit(f"{STATE_PATH} does not exist. Run ./deploy/setup.sh to write it.")

if sys.argv[1] == "--print-launched-epoch":
    # Collection uses this to tell this run's sampler files from an earlier run's. Arm names
    # repeat across runs, so launch time is the only separator.
    _s = json.loads(STATE_PATH.read_text())
    _a = next((a for a in _s.get("arms", []) if a["arm"] == sys.argv[2]), None)
    _at = (_a or {}).get("launched_at")
    if not _at:
        print(0)
    else:
        print(int(datetime.datetime.fromisoformat(_at).timestamp()))
    sys.exit(0)

arm, state = sys.argv[1], sys.argv[2]
outcome = next((a for a in sys.argv[3:] if not a.startswith("--")), None)
if state not in VALID:
    sys.exit(f"state must be one of {sorted(VALID)}, got {state!r}")

path = STATE_PATH
s = json.loads(path.read_text())
hit = next((a for a in s.get("arms", []) if a["arm"] == arm), None)
if hit is None:
    sys.exit(f"no arm named {arm!r} in {path}. Known: {[a['arm'] for a in s.get('arms', [])]}")

now = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
hit["state"] = state
if state == "pending":
    # Back to pending means this arm never happened. A leftover launched_at would read as
    # "ran, not yet collected".
    hit["launched_at"] = hit["expect_done_at"] = hit["outcome"] = None
if state == "launched":
    hit["launched_at"] = now
    # Minutes until done, not the cap. The cap is a safety bound; the real figure is ramp plus
    # hold, and ramp length depends on the start rate the driver achieves. Arm 1's cap-derived
    # estimate said 15:53 for an arm that finished at 16:45.
    cap = next((int(a.split("=")[1]) for a in sys.argv if a.startswith("--minutes=")),
               s.get("cap_minutes", 90))
    hit["expect_done_at"] = (
        datetime.datetime.now().astimezone() + datetime.timedelta(minutes=cap)
    ).isoformat(timespec="seconds")
if outcome:
    hit["outcome"] = outcome
s["updated"] = now
path.write_text(json.dumps(s, indent=2) + "\n")
print(f"  state: {arm} -> {state}" + (f" ({outcome})" if outcome else ""))
