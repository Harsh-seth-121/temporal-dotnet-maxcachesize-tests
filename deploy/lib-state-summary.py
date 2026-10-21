#!/usr/bin/env python3
"""Print what the run-state file says, in the three lines a human needs on resume.

Its own file rather than a heredoc inside 70-resume.sh: a Python heredoc nested in a shell
heredoc is a quoting trap that has already eaten one edit.

    ./deploy/lib-state-summary.py "$STATE"
"""
import datetime
import json
import os
import sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
flags = {a for a in sys.argv[1:] if a.startswith("--")}
path = args[0] if args else os.environ.get("STATE", "")
if not path:
    sys.exit("no state file given and STATE is not set; source deploy/lib-config.sh first")
s = json.load(open(path))
arms = s.get("arms", [])

if "--inflight" in flags:
    # Name of the arm currently launched, or nothing. 60-run-arm.sh uses it to refuse a second
    # arm on top of a live one.
    for a in arms:
        if a.get("state") == "launched":
            print(a["arm"])
            break
    raise SystemExit(0)

if "--next-gc" in flags:
    # GC mode of the next arm, for callers deciding before it launches. 40-preflight.sh fails
    # a missing DOTNET_GCHeapHardLimit by default: right on a limit arm, wrong on a nolimit one.
    live = [a for a in arms if a.get("state") == "launched"]
    pending = sorted((a for a in arms if a.get("state") == "pending"), key=lambda a: a.get("order", 0))
    nxt = (live or pending or [{}])[0]
    print(nxt.get("gc", "limit"))
    raise SystemExit(0)


def of(state):
    return [a for a in arms if a.get("state") == state]


collected, live, pending, aborted = (of(x) for x in ("collected", "launched", "pending", "aborted"))

print(f"  phase {s.get('phase')}: {len(collected)} collected, {len(pending)} pending, "
      f"{len(aborted)} aborted, {len(live)} in flight")
for a in collected:
    print(f"    done    {a['arm']:<16} {a.get('outcome') or 'outcome not recorded'}")
for a in pending:
    print(f"    pending {a['arm']:<16} cache {a['cache']}, GC {a['gc']}")

if live:
    a = live[0]
    print()
    # An arm in flight is normal: the runner detaches, so it is meant to be out there with no
    # terminal attached. What matters is inside-its-window vs overdue, and the advice is
    # opposite in the two cases. The old text said "park it" either way.
    due = a.get("expect_done_at")
    overdue = False
    if due:
        try:
            overdue = datetime.datetime.now().astimezone() > datetime.datetime.fromisoformat(due)
        except ValueError:
            pass
    print(f"  IN FLIGHT: {a['arm']}, launched {a.get('launched_at')}, due {due}")
    if overdue:
        print("  OVERDUE. Collect it: ./deploy/62-collect-arm.sh " + a["arm"])
        print("  If the driver never reached phase 'drained', the population is still heartbeating")
        print("  and still billing: ./deploy/71-park.sh drains it.")
    else:
        print("  Still inside its window. It needs nothing from this laptop. Do not launch another")
        print("  arm until this one is collected: they share one worker and two at once ruin both.")

for b in s.get("blocking", []):
    print(f"\n  BLOCKED: {b}")

print(f"\n  NEXT: {s.get('next')}")
