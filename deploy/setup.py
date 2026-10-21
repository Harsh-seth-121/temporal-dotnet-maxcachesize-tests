#!/usr/bin/env python3
"""Onboarding for the cache-test harness.

Gets a fresh macOS or Linux machine to the point where ./deploy/00-provision.sh can run:
tools installed, both logins working, a Temporal Cloud cert that actually connects, and two
config files written. It prepares and it stops. It creates no App Service plans, no web apps,
no storage, no containers, and starts no workflows. Anything that bills belongs to
00-provision.sh.

The one exception, behind an explicit confirm, is creating the Azure resource group. An empty
group costs nothing and is a prerequisite rather than a test resource.

Seven steps, walked in order, each skipped once complete. Progress lives in harness.json and
is written after every step, so a force quit resumes rather than restarts. --reset N redoes
step N and everything after it.

Standard library only, on purpose: python3 is the one thing the shim guarantees, and every
deploy script already depends on it.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SECRETS = Path.home() / ".config" / "temporal-cache-test"

# The prefix nobody is allowed to keep. It is deliberately the default so the failure is loud:
# Azure web app names are globally unique DNS records, so a shared prefix cannot work twice.
SHARED_PREFIX = "temporal-cache-test"

SETUP_VERSION = 1

STEPS = [
    ("platform",     "Platform"),
    ("deps",         "Dependencies"),
    ("azure-login",  "Azure login"),
    ("azure-naming", "Azure naming"),
    ("temporal",     "Temporal + cert"),
    ("config",       "Secrets + config"),
    ("run-state",    "Run state"),
    ("verify",       "Verify"),
]
STEP_IDS = [s[0] for s in STEPS]

# ---------------------------------------------------------------------------- output

_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def _c(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if _COLOR else text


def say(msg: str) -> None:
    print("\n" + _c("1", f"==> {msg}"))


def note(msg: str) -> None:
    print(f"    {msg}")


class Checks:
    """PASS / WARN / FAIL in the shape deploy/40-preflight.sh already uses, so setup and the
    preflight it precedes read as one tool. WARN is a third state, not a soft fail: it prints
    and leaves the verdict alone."""

    def __init__(self) -> None:
        self.failed = 0
        self.warned = 0

    def ok(self, label: str, detail: str = "") -> None:
        print(f"  {_c('32', 'PASS')} {label:<42} {detail}")

    def warn(self, label: str, detail: str = "") -> None:
        self.warned += 1
        print(f"  {_c('33', 'WARN')} {label:<42} {detail}")

    def no(self, label: str, detail: str = "") -> None:
        self.failed += 1
        print(f"  {_c('31', 'FAIL')} {label:<42} {detail}")


# ---------------------------------------------------------------------------- input

class Aborted(Exception):
    """The user asked to stop. Whatever is already written stays written."""


INTERACTIVE = True


def prompt(label: str, default: str = "", allow_empty: bool = False) -> str:
    if not INTERACTIVE:
        if default or allow_empty:
            return default
        raise Aborted(f"{label} needs a value and this is a non-interactive run")
    suffix = f" [{default}]" if default else ""
    while True:
        try:
            got = input(f"    {label}{suffix}: ").strip()
        except (EOFError, KeyboardInterrupt):
            raise Aborted("interrupted")
        if not got:
            got = default
        if got or allow_empty:
            return got
        note("A value is required.")


def ask(question: str, default: bool = False) -> bool:
    if not INTERACTIVE:
        return default
    hint = "[Y/n]" if default else "[y/N]"
    try:
        got = input(f"    {question} {hint} ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        raise Aborted("interrupted")
    if not got:
        return default
    return got.startswith("y")


def choose(label: str, options: list[tuple[str, str]], default_index: int = 0) -> str:
    """Numbered menu. Returns the key of the chosen option."""
    for i, (_, text) in enumerate(options, 1):
        print(f"    {i}) {text}")
    if not INTERACTIVE:
        return options[default_index][0]
    while True:
        got = prompt(label, str(default_index + 1))
        if got.isdigit() and 1 <= int(got) <= len(options):
            return options[int(got) - 1][0]
        note(f"Pick 1 to {len(options)}.")


# ---------------------------------------------------------------------------- shelling out

def run(cmd: list[str], check: bool = False, stdin: str | None = None,
        timeout: int | None = 120) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, input=stdin,
                              check=check, timeout=timeout)
    except FileNotFoundError:
        return subprocess.CompletedProcess(cmd, 127, "", f"{cmd[0]}: not found")
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", f"{cmd[0]}: timed out")


def run_live(cmd: str) -> int:
    """Interactive commands (az login, package installs) keep the user's terminal."""
    return subprocess.call(cmd, shell=True)


def out(cmd: list[str]) -> str:
    return run(cmd).stdout.strip()


# ---------------------------------------------------------------------------- config store

def _atomic_write(path: Path, text: str, mode: int = 0o600) -> None:
    """Write through a temp file in the same directory, then rename. A kill -9 mid-write
    leaves either the old file or the new one, never a half-written one. That is what makes
    the resume safe."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


DEFAULT_AZURE = {
    "subscriptionId": "",
    "resourceGroup": "",
    "location": "eastus2",
    "prefix": SHARED_PREFIX,
    "workerSku": "P1V3",
    "driverSku": "P1V3",
    "runtime": "DOTNETCORE:10.0",
    "workers": 6,
    "storageAccount": "",
    "deployStorage": "",
}


class Store:
    """harness.json is machine and deployment state, owned by setup and never deployed.
    testconfig.json is the experiment, staged into the Azure zip by the deploy scripts. The
    split is the deploy-zip boundary: a subscription id has no business on an App Service
    filesystem."""

    def __init__(self, secrets: Path) -> None:
        self.secrets = secrets
        self.harness_path = secrets / "harness.json"
        self.config_path = secrets / "testconfig.json"
        # Which arm is pending, launched or collected, and which worker app runs it. Beside
        # the config and not in docs/, because it is per-run state rather than source: docs/
        # holds results, which are disposable, and a fresh clone has no state to inherit.
        self.state_path = secrets / "run-state.json"
        self.harness = self._load_harness()
        self.config = self._load_config()

    def _load_harness(self) -> dict:
        if self.harness_path.exists():
            try:
                d = json.loads(self.harness_path.read_text())
            except json.JSONDecodeError:
                note(f"{self.harness_path} is unreadable; starting from defaults.")
                d = {}
        else:
            d = {}
        d.setdefault("setup", {"version": SETUP_VERSION, "completed": [], "updated": ""})
        azure = dict(DEFAULT_AZURE)
        azure.update(d.get("azure") or {})
        d["azure"] = azure
        return d

    def _load_config(self) -> dict:
        for candidate in (self.config_path, ROOT / "config" / "testconfig.sample.json"):
            if candidate.exists():
                return json.loads(candidate.read_text())
        raise Aborted("config/testconfig.sample.json is missing from the repo")

    # -- setup progress
    @property
    def completed(self) -> list[str]:
        return self.harness["setup"].setdefault("completed", [])

    def done(self, step_id: str) -> bool:
        return step_id in self.completed

    def mark(self, step_id: str) -> None:
        if step_id not in self.completed:
            self.completed.append(step_id)
        self.save_harness()

    def reset_from(self, step_id: str) -> None:
        """Resetting a step resets everything after it too. The later steps derive from the
        earlier ones: change the prefix and the task queue names and Prometheus targets are
        both stale."""
        idx = STEP_IDS.index(step_id)
        drop = set(STEP_IDS[idx:])
        self.harness["setup"]["completed"] = [c for c in self.completed if c not in drop]
        self.save_harness()

    # -- persistence
    def save_harness(self) -> None:
        self.harness["setup"]["version"] = SETUP_VERSION
        self.harness["setup"]["updated"] = datetime.now(timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ")
        _atomic_write(self.harness_path, json.dumps(self.harness, indent=2) + "\n")

    def save_config(self) -> None:
        _atomic_write(self.config_path, json.dumps(self.config, indent=2) + "\n")

    @property
    def azure(self) -> dict:
        return self.harness["azure"]

    @property
    def temporal(self) -> dict:
        return self.config.setdefault("temporal", {})

    def secret(self, name: str) -> Path | None:
        """Prefer the out-of-tree copy, fall back to the repo's certs/, same rule as
        deploy/40-preflight.sh."""
        for p in (self.secrets / name, ROOT / "certs" / name):
            if p.is_file():
                return p
        return None


# ---------------------------------------------------------------------------- platform

class Platform:
    def __init__(self) -> None:
        self.system = platform.system()
        self.macos = self.system == "Darwin"
        self.linux = self.system == "Linux"
        self.arch = platform.machine()
        self.pkg = next((p for p in ("brew", "apt-get", "dnf", "pacman", "zypper")
                         if shutil.which(p)), None)
        # Already root (a container, an image build) means sudo is both unnecessary and
        # usually absent, so the commands below have to drop it rather than fail with
        # "sudo: not found".
        self.root = hasattr(os, "geteuid") and os.geteuid() == 0
        self.sudo = self.root or shutil.which("sudo") is not None

    def label(self) -> str:
        return f"{self.system} {self.arch}, package manager: {self.pkg or 'none'}"


PLAT = Platform()


def install_cmd(spec: dict) -> str | None:
    """spec maps package manager -> command string. 'zypper' falls back to the dnf package
    name because both are rpm-based."""
    if PLAT.pkg is None:
        return None
    if PLAT.pkg == "zypper" and "zypper" not in spec and "dnf" in spec:
        cmd = spec["dnf"].replace("dnf install -y", "zypper install -y")
    else:
        cmd = spec.get(PLAT.pkg)
    if not cmd:
        return None
    if PLAT.root:
        cmd = cmd.replace("sudo ", "")
    elif "sudo " in cmd and not PLAT.sudo:
        return None
    return cmd


def offer_install(name: str, spec: dict) -> bool:
    cmd = install_cmd(spec)
    if not cmd:
        note(f"No install command known for {name} on {PLAT.pkg or 'this platform'}.")
        return False
    note(f"will run: {cmd}")
    if not ask(f"install {name}?", default=True):
        return False
    rc = run_live(cmd)
    if rc != 0:
        note(f"{name} install exited {rc}.")
    return rc == 0


# ---------------------------------------------------------------------------- step 1

def step_platform(store: Store, ck: Checks) -> bool:
    ck.ok("platform", PLAT.label())
    bash = shutil.which("bash")
    major = 0
    if bash:
        v = out([bash, "-c", "echo ${BASH_VERSINFO[0]}"])
        major = int(v) if v.isdigit() else 0
    if major >= 4:
        ck.ok("bash 4+", f"{out([bash, '-c', 'echo $BASH_VERSION'])} at {bash}")
    else:
        # deploy/62,63,66,68 use mapfile. Without bash 4 they produce an empty array and
        # silently collect nothing, which is worse than failing.
        ck.no("bash 4+", f"found {major}.x; deploy/62,63,66,68 use mapfile")
    if PLAT.pkg is None:
        ck.warn("package manager", "none found; installs must be done by hand")
    if PLAT.linux and not PLAT.sudo:
        ck.warn("root", "not root and sudo is missing; package installs will need root")
    return ck.failed == 0


# ---------------------------------------------------------------------------- step 2

def dotnet10() -> str | None:
    r = run(["dotnet", "--list-sdks"])
    if r.returncode != 0:
        return None
    for line in r.stdout.splitlines():
        if re.match(r"^10\.", line.strip()):
            return line.strip().split()[0]
    return None


def az_version() -> str | None:
    r = run(["az", "version", "--output", "json"])
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout).get("azure-cli")
    except json.JSONDecodeError:
        return None


def temporal_version() -> str | None:
    r = run(["temporal", "--version"])
    if r.returncode != 0:
        return None
    m = re.search(r"(\d+\.\d+\.\d+)", r.stdout)
    return m.group(1) if m else r.stdout.strip()


# .NET 10 is not in the distro archives yet, so Linux goes through Microsoft's installer
# script rather than apt/dnf. It drops into ~/.dotnet and needs a PATH line.
DOTNET_SCRIPT = (
    "curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh "
    "&& bash /tmp/dotnet-install.sh --channel 10.0 "
    "&& echo 'export PATH=\"$HOME/.dotnet:$PATH\"' >> ~/.profile"
)

TOOLS = [
    {
        "name": "dotnet10", "label": ".NET SDK 10.x", "required": True,
        "why": "every project targets net10.0",
        "detect": dotnet10,
        "install": {"brew": "brew install --cask dotnet-sdk",
                    "apt-get": DOTNET_SCRIPT,
                    "dnf": "sudo dnf install -y dotnet-sdk-10.0",
                    "pacman": "sudo pacman -S --noconfirm dotnet-sdk"},
    },
    {
        "name": "az", "label": "Azure CLI", "required": True,
        "why": "every deploy script",
        "detect": az_version,
        "install": {"brew": "brew install azure-cli",
                    "apt-get": "curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash",
                    "dnf": "sudo dnf install -y azure-cli",
                    "pacman": "sudo pacman -S --noconfirm azure-cli"},
    },
    {
        "name": "temporal", "label": "Temporal CLI", "required": True,
        "why": "the drain loops in 60/64/66/71",
        "detect": temporal_version,
        "install": {"brew": "brew install temporal",
                    "apt-get": "curl -sSf https://temporal.download/cli.sh | sh",
                    "dnf": "curl -sSf https://temporal.download/cli.sh | sh",
                    "pacman": "curl -sSf https://temporal.download/cli.sh | sh"},
    },
    {
        "name": "openssl", "label": "openssl", "required": True,
        "why": "certificate handling",
        "detect": lambda: shutil.which("openssl"),
        "install": {"brew": "brew install openssl", "apt-get": "sudo apt-get install -y openssl",
                    "dnf": "sudo dnf install -y openssl", "pacman": "sudo pacman -S --noconfirm openssl"},
    },
    {
        "name": "curl", "label": "curl", "required": True,
        "why": "health checks and metrics scrapes",
        "detect": lambda: shutil.which("curl"),
        "install": {"brew": "brew install curl", "apt-get": "sudo apt-get install -y curl",
                    "dnf": "sudo dnf install -y curl", "pacman": "sudo pacman -S --noconfirm curl"},
    },
    {
        "name": "zip", "label": "zip and unzip", "required": True,
        "why": "building the deploy package and reading log bundles",
        "detect": lambda: "present" if (shutil.which("zip") and shutil.which("unzip")) else None,
        "install": {"brew": "brew install zip unzip", "apt-get": "sudo apt-get install -y zip unzip",
                    "dnf": "sudo dnf install -y zip unzip", "pacman": "sudo pacman -S --noconfirm zip unzip"},
    },
    {
        # Azure-only runs never touch Docker. Local Prometheus and Grafana do, and that is the
        # path the recorded runs actually used.
        "name": "docker", "label": "Docker daemon", "required": False,
        "why": "local Prometheus and Grafana",
        "detect": lambda: "running" if run(["docker", "info"], timeout=30).returncode == 0 else None,
        "install": {"brew": "brew install --cask docker",
                    "apt-get": "curl -fsSL https://get.docker.com | sudo sh",
                    "dnf": "sudo dnf install -y docker", "pacman": "sudo pacman -S --noconfirm docker"},
    },
]


def step_deps(store: Store, ck: Checks) -> bool:
    missing = []
    for tool in TOOLS:
        got = tool["detect"]()
        if got:
            ck.ok(tool["label"], str(got) if got is not True else "")
        elif tool["required"]:
            ck.no(tool["label"], f"not found ({tool['why']})")
            missing.append(tool)
        else:
            ck.warn(tool["label"], f"not available ({tool['why']})")
            missing.append(tool)

    # The containerapp extension only matters for 30-deploy-observability.sh, which the
    # recorded runs abandoned in favour of local Docker. Never a hard failure.
    if az_version():
        if run(["az", "extension", "show", "-n", "containerapp"]).returncode == 0:
            ck.ok("az containerapp extension")
        else:
            ck.warn("az containerapp extension",
                    "needed only by 30-deploy-observability.sh: az extension add -n containerapp")

    if missing and INTERACTIVE:
        say("Missing tools")
        for tool in missing:
            if offer_install(tool["name"], tool["install"]):
                if tool["detect"]():
                    ck.ok(tool["label"], "installed")
                    if tool["required"]:
                        ck.failed -= 1
                else:
                    note(f"{tool['label']} still not detected; a new shell may be needed.")
    return ck.failed == 0


# ---------------------------------------------------------------------------- step 3

def az_account() -> dict | None:
    r = run(["az", "account", "show", "--output", "json"])
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None


def step_azure_login(store: Store, ck: Checks) -> bool:
    acct = az_account()
    if acct is None:
        ck.no("az login", "no active session")
        if not INTERACTIVE:
            return False
        say("Azure sign-in")
        # The device-code path is the one that matters on a remote Linux box with no browser,
        # and it is the easy one to forget.
        how = choose("sign-in method", [
            ("browser", "az login (opens a browser)"),
            ("device", "az login --use-device-code (no browser, paste a code)"),
            ("skip", "skip for now"),
        ])
        if how == "skip":
            return False
        run_live("az login --use-device-code" if how == "device" else "az login")
        acct = az_account()
        if acct is None:
            ck.no("az login", "still no active session")
            return False
        ck.failed -= 1

    ck.ok("az login", f"{acct.get('user', {}).get('name', '?')}")

    # -- subscription
    subs = []
    r = run(["az", "account", "list", "--output", "json"])
    if r.returncode == 0:
        try:
            subs = json.loads(r.stdout)
        except json.JSONDecodeError:
            subs = []

    want = store.azure.get("subscriptionId") or acct.get("id", "")
    if INTERACTIVE and len(subs) > 1:
        say("Subscription")
        opts = [(s["id"], f"{s['name']}  ({s['id']})") for s in subs]
        default_index = next((i for i, (sid, _) in enumerate(opts) if sid == want), 0)
        want = choose("subscription", opts, default_index)
    if want and want != acct.get("id"):
        if run(["az", "account", "set", "-s", want]).returncode != 0:
            ck.no("subscription", f"could not switch to {want}")
            return False
        acct = az_account() or acct
    store.azure["subscriptionId"] = acct.get("id", "")
    ck.ok("subscription", f"{acct.get('name')} ({acct.get('id')})")

    # -- resource group. The only Azure write this script performs, and only on a yes.
    rg = store.azure.get("resourceGroup") or ""
    if INTERACTIVE:
        rg = prompt("resource group", rg)
    if not rg:
        ck.no("resource group", "not set")
        return False
    store.azure["resourceGroup"] = rg

    if run(["az", "group", "show", "-n", rg, "--output", "none"]).returncode == 0:
        loc = out(["az", "group", "show", "-n", rg, "--query", "location", "-o", "tsv"])
        ck.ok("resource group", f"{rg} in {loc}")
        # A resource group's location is only where its metadata lives. Plans and apps can sit
        # in a different region, and this experiment's do. Overwriting the configured location
        # with the group's would silently move the next provision.
        want = store.azure.get("location")
        if loc and want and loc != want:
            ck.warn("location", f"group is in {loc}, resources go to {want}")
    else:
        ck.warn("resource group", f"{rg} does not exist")
        loc = store.azure.get("location", "eastus2")
        if INTERACTIVE and ask(f"create resource group {rg} in {loc}?", default=False):
            note("will run: az group create -n %s -l %s" % (rg, loc))
            if run(["az", "group", "create", "-n", rg, "-l", loc, "--output", "none"]).returncode == 0:
                ck.ok("resource group", f"{rg} created in {loc}")
                ck.warned -= 1
            else:
                ck.no("resource group", "create failed")
                return False
        else:
            ck.no("resource group", "missing; 00-provision.sh will fail")
            return False

    # -- providers
    for ns, need in (("Microsoft.Web", True), ("Microsoft.App", False)):
        state = out(["az", "provider", "show", "-n", ns, "--query", "registrationState", "-o", "tsv"])
        if state == "Registered":
            ck.ok(f"{ns} registered")
        elif need:
            ck.no(f"{ns} registered", f"state={state or 'unknown'}; az provider register -n {ns}")
        else:
            ck.warn(f"{ns} registered",
                    f"state={state or 'unknown'}; only 30-deploy-observability.sh needs it")

    return ck.failed == 0


# ---------------------------------------------------------------------------- step 4

PREFIX_RE = re.compile(r"^[a-z][a-z0-9-]{1,38}[a-z0-9]$")


def app_names(prefix: str, workers: int) -> list[str]:
    """Every globally-unique name the deploy scripts will later claim."""
    names = [f"{prefix}-worker", f"{prefix}-driver", f"{prefix}-prom", f"{prefix}-grafana"]
    names += [f"{prefix}-worker-{n}" for n in range(2, workers + 1)]
    return names


def owns_site(name: str) -> str | None:
    """The resource group holding this web app, if the signed-in subscription owns it."""
    r = run(["az", "resource", "list", "--name", name,
             "--resource-type", "Microsoft.Web/sites",
             "--query", "[0].resourceGroup", "-o", "tsv"])
    return r.stdout.strip() or None if r.returncode == 0 else None


def check_site_name(sub: str, name: str) -> tuple[str, str]:
    """-> (verdict, detail) where verdict is 'free', 'mine' or 'taken'.

    A name that already exists is only a problem when somebody else has it. Re-running setup
    on a machine that has already provisioned must not report its own apps as conflicts.
    """
    url = (f"https://management.azure.com/subscriptions/{sub}"
           f"/providers/Microsoft.Web/checknameavailability?api-version=2022-03-01")
    body = json.dumps({"name": name, "type": "Microsoft.Web/sites"})
    r = run(["az", "rest", "--method", "post", "--url", url, "--body", body])
    if r.returncode != 0:
        return "free", "could not check"
    try:
        d = json.loads(r.stdout)
    except json.JSONDecodeError:
        return "free", "could not parse the response"
    if d.get("nameAvailable"):
        return "free", ""
    rg = owns_site(name)
    if rg:
        return "mine", f"already yours in {rg}"
    return "taken", d.get("message") or d.get("reason") or "taken by another subscription"


def storage_name(prefix: str, suffix: str) -> str:
    """Storage accounts: 3-24 chars, lowercase alphanumeric, no hyphens, globally unique."""
    base = re.sub(r"[^a-z0-9]", "", prefix.lower())
    return (base[: 24 - len(suffix)] + suffix)[:24]


def check_storage_name(name: str) -> tuple[str, str]:
    """Same three verdicts as check_site_name. 11-deploy-fleet.sh expects its staging account
    to pre-exist, so 'mine' is the normal answer there, not an exception."""
    r = run(["az", "storage", "account", "check-name", "-n", name, "--output", "json"])
    if r.returncode != 0:
        return "free", "could not check"
    try:
        d = json.loads(r.stdout)
    except json.JSONDecodeError:
        return "free", "could not parse the response"
    if d.get("nameAvailable"):
        return "free", ""
    rg = out(["az", "storage", "account", "show", "-n", name,
              "--query", "resourceGroup", "-o", "tsv"])
    if rg:
        return "mine", f"already yours in {rg}"
    return "taken", d.get("message") or "taken by another subscription"


def step_azure_naming(store: Store, ck: Checks) -> bool:
    az = store.azure
    if INTERACTIVE:
        say("Names and sizes")
        note("The prefix becomes <prefix>-worker.azurewebsites.net and the task queue names.")
        note("Azure web app names are globally unique, so it has to be yours alone.")
        while True:
            p = prompt("resource prefix", az.get("prefix", SHARED_PREFIX))
            if p == SHARED_PREFIX:
                note(f"'{SHARED_PREFIX}' is the shared default. Add a suffix that is yours.")
                continue
            if not PREFIX_RE.match(p):
                note("Lowercase letters, digits and hyphens; start with a letter, 3-40 chars.")
                continue
            # -worker-6 is the longest suffix the fleet adds; App Service caps names at 60.
            if len(p) + len("-worker-6") > 60:
                note("Too long: <prefix>-worker-6 must stay under 60 characters.")
                continue
            az["prefix"] = p
            break

        az["location"] = prompt("location", az.get("location", "eastus2"))
        note("P1v3 is 2 vCPU / 8 GiB. 8 and not 16 on purpose: on P1mv3 nothing reaches OOM.")
        az["workerSku"] = prompt("worker SKU", az.get("workerSku", "P1V3"))
        az["driverSku"] = prompt("driver SKU", az.get("driverSku", "P1V3"))
        az["runtime"] = prompt("App Service runtime", az.get("runtime", "DOTNETCORE:10.0"))
        while True:
            w = prompt("worker apps (one per arm)", str(az.get("workers", 6)))
            if w.isdigit() and 1 <= int(w) <= 20:
                az["workers"] = int(w)
                break
            note("A number from 1 to 20.")
        az["storageAccount"] = prompt("observability storage account",
                                      az.get("storageAccount") or storage_name(az["prefix"], "obs"))
        az["deployStorage"] = prompt("deploy staging storage account",
                                     az.get("deployStorage") or storage_name(az["prefix"], "dep"))
    store.save_harness()

    prefix = az["prefix"]
    if prefix == SHARED_PREFIX:
        ck.no("resource prefix", "still the shared default; add a suffix")
        return False
    if not PREFIX_RE.match(prefix):
        ck.no("resource prefix", f"{prefix!r} is not a valid Azure name")
        return False
    ck.ok("resource prefix", prefix)

    sub = az.get("subscriptionId", "")
    if not sub:
        ck.warn("name availability", "no subscription recorded; skipped")
    else:
        for name in app_names(prefix, int(az["workers"])):
            verdict, msg = check_site_name(sub, name)
            if verdict == "free":
                ck.ok(f"{name}", "available")
            elif verdict == "mine":
                ck.ok(f"{name}", msg)
            else:
                ck.no(f"{name}", msg)

    for key, label in (("storageAccount", "observability storage"),
                       ("deployStorage", "deploy staging storage")):
        name = az.get(key, "")
        if not re.fullmatch(r"[a-z0-9]{3,24}", name or ""):
            ck.no(label, f"{name!r} must be 3-24 lowercase alphanumeric characters")
            continue
        verdict, msg = check_storage_name(name)
        if verdict == "free":
            ck.ok(label, f"{name}: available")
        elif verdict == "mine":
            ck.ok(label, f"{name}: {msg}")
        else:
            ck.no(label, f"{name}: {msg}")

    plans = int(az["workers"]) + 1
    note("")
    note(f"Provisioning later creates {plans} App Service plans at {az['workerSku']}.")
    note(f"That bills roughly ${plans * 3.70:.2f}/day until ./deploy/99-teardown.sh runs.")
    return ck.failed == 0


# ---------------------------------------------------------------------------- step 5

def pubkey_of_cert(path: Path) -> str | None:
    r = run(["openssl", "x509", "-noout", "-pubkey", "-in", str(path)])
    return r.stdout.strip() if r.returncode == 0 else None


def pubkey_of_key(path: Path) -> str | None:
    # -pubout on a private key, not the modulus trick: this works for EC keys too.
    r = run(["openssl", "pkey", "-pubout", "-in", str(path)])
    return r.stdout.strip() if r.returncode == 0 else None


def cert_not_after(path: Path) -> datetime | None:
    r = run(["openssl", "x509", "-noout", "-enddate", "-in", str(path)])
    if r.returncode != 0 or "=" not in r.stdout:
        return None
    raw = r.stdout.strip().split("=", 1)[1]
    for fmt in ("%b %d %H:%M:%S %Y %Z", "%b %d %H:%M:%S %Y"):
        try:
            return datetime.strptime(raw, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def check_pair(ck: Checks, cert: Path, key: Path) -> bool:
    cp, kp = pubkey_of_cert(cert), pubkey_of_key(key)
    if not cp or not kp:
        ck.no("cert and key readable", "openssl could not parse one of them")
        return False
    if cp != kp:
        ck.no("cert and key match", "the key does not belong to this certificate")
        return False
    ck.ok("cert and key match")

    end = cert_not_after(cert)
    if end is None:
        ck.warn("cert validity", "could not read notAfter")
        return True
    days = (end - datetime.now(timezone.utc)).days
    if days < 0:
        ck.no("cert validity", f"expired {-days} days ago ({end:%Y-%m-%d})")
        return False
    if days < 30:
        ck.warn("cert validity", f"expires in {days} days ({end:%Y-%m-%d})")
    else:
        ck.ok("cert validity", f"{days} days left ({end:%Y-%m-%d})")
    return True


def generate_ca_and_client(store: Store, prefix: str) -> bool:
    """A self-signed CA plus a leaf signed by it. Temporal Cloud accepts a CA you upload, so
    this removes the 'get a cert from somewhere' step. Uploading it is still a human action:
    temporal CLI 1.8.1 has no `cloud` subcommand and tcld is not a dependency here."""
    d = store.secrets
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    ca_pem, ca_key = d / "ca.pem", d / "ca.key"
    cert, key, csr = d / "client.pem", d / "client.key", d / "client.csr"

    if ca_pem.exists() and not ask(f"{ca_pem} exists. Regenerate the CA?", default=False):
        note("Keeping the existing CA.")
    else:
        r = run(["openssl", "req", "-x509", "-newkey", "rsa:4096", "-sha256", "-days", "365",
                 "-nodes", "-keyout", str(ca_key), "-out", str(ca_pem),
                 "-subj", f"/CN={prefix}-ca",
                 "-addext", "basicConstraints=critical,CA:TRUE",
                 "-addext", "keyUsage=critical,keyCertSign,cRLSign"], timeout=300)
        if r.returncode != 0:
            note(r.stderr.strip())
            return False
        note(f"CA written to {ca_pem}")

    r = run(["openssl", "req", "-new", "-newkey", "rsa:4096", "-nodes",
             "-keyout", str(key), "-out", str(csr),
             "-subj", f"/CN={prefix}-client"], timeout=300)
    if r.returncode != 0:
        note(r.stderr.strip())
        return False

    ext = d / "client.ext"
    ext.write_text("keyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n")
    r = run(["openssl", "x509", "-req", "-in", str(csr), "-CA", str(ca_pem), "-CAkey", str(ca_key),
             "-CAcreateserial", "-out", str(cert), "-days", "365", "-sha256",
             "-extfile", str(ext)], timeout=300)
    ext.unlink(missing_ok=True)
    csr.unlink(missing_ok=True)
    if r.returncode != 0:
        note(r.stderr.strip())
        return False

    for f in (ca_key, key, cert, ca_pem):
        if f.exists():
            os.chmod(f, 0o600)

    say("Upload the CA to your Temporal Cloud namespace")
    note("Paste the block below into the namespace's accepted client CA list, then come back.")
    print()
    print(ca_pem.read_text())
    if INTERACTIVE:
        ask("CA uploaded and the namespace saved?", default=False)
    return True


def temporal_connect(store: Store, ck: Checks) -> bool:
    """One read-only call. A clean answer is the only proof the certificate works, and it
    starts nothing."""
    t = store.temporal
    addr, ns = t.get("address", ""), t.get("namespace", "")
    cert, key = store.secret("client.pem"), store.secret("client.key")
    if not (addr and ns):
        ck.no("temporal reachable", "address or namespace not set")
        return False
    if not (cert and key):
        ck.no("temporal reachable", "client.pem or client.key missing")
        return False
    r = run(["temporal", "workflow", "count", "--query", 'ExecutionStatus="Running"',
             "--address", addr, "--namespace", ns,
             "--tls-cert-path", str(cert), "--tls-key-path", str(key)], timeout=60)
    if r.returncode == 0:
        ck.ok("temporal reachable", f"{ns} answered")
        return True
    msg = (r.stderr or r.stdout).strip().splitlines()
    ck.no("temporal reachable", msg[-1] if msg else f"exit {r.returncode}")
    return False


def step_temporal(store: Store, ck: Checks) -> bool:
    t = store.temporal
    if INTERACTIVE:
        say("Temporal Cloud")
        handle = prompt("namespace handle (<namespace>.<account>)",
                        t.get("namespace", "") if "<" not in t.get("namespace", "") else "")
        t["namespace"] = handle
        default_addr = t.get("address", "")
        if not default_addr or "<" in default_addr:
            default_addr = f"{handle}.tmprl.cloud:7233"
        t["address"] = prompt("address", default_addr)
        aps = prompt("namespace Actions-per-second limit", str(t.get("apsLimit", 500)))
        t["apsLimit"] = int(aps) if aps.isdigit() else 500
        # These two are what a local dry run uses; the Azure path ships base64 instead.
        t.setdefault("clientCertPath", "certs/client.pem")
        t.setdefault("clientKeyPath", "certs/client.key")
        store.save_config()

    if "<" in t.get("namespace", "") or not t.get("namespace"):
        ck.no("namespace", "still a placeholder")
        return False
    ck.ok("namespace", t["namespace"])
    ck.ok("address", t["address"])

    have = store.secret("client.pem") and store.secret("client.key")
    if INTERACTIVE:
        say("Client certificate")
        options = [("existing", "point at an existing client.pem and client.key"),
                   ("generate", "generate a self-signed CA and client certificate")]
        if have:
            options.insert(0, ("keep", f"keep the certificate already in {store.secrets}"))
        how = choose("certificate", options)

        if how == "existing":
            store.secrets.mkdir(parents=True, exist_ok=True)
            os.chmod(store.secrets, 0o700)
            src_cert = Path(prompt("path to client.pem")).expanduser()
            src_key = Path(prompt("path to client.key")).expanduser()
            if not src_cert.is_file() or not src_key.is_file():
                ck.no("certificate files", "one of those paths does not exist")
                return False
            if not check_pair(ck, src_cert, src_key):
                return False
            dst_cert, dst_key = store.secrets / "client.pem", store.secrets / "client.key"
            if dst_cert.exists() and not ask(f"overwrite {dst_cert}?", default=False):
                note("Keeping the existing certificate.")
            else:
                shutil.copyfile(src_cert, dst_cert)
                shutil.copyfile(src_key, dst_key)
                os.chmod(dst_cert, 0o600)
                os.chmod(dst_key, 0o600)
                note(f"copied into {store.secrets}")
        elif how == "generate":
            if not generate_ca_and_client(store, store.azure["prefix"]):
                ck.no("certificate", "openssl failed")
                return False

    cert, key = store.secret("client.pem"), store.secret("client.key")
    if not (cert and key):
        ck.no("certificate present", f"client.pem and client.key not in {store.secrets}")
        return False
    ck.ok("certificate present", str(cert.parent))
    if not check_pair(ck, cert, key):
        return False

    temporal_connect(store, ck)
    return ck.failed == 0


# ---------------------------------------------------------------------------- step 6

import secrets as _secrets  # noqa: E402  (only needed from here down)


def ensure_token(store: Store, name: str, ck: Checks) -> None:
    """Same 64 hex characters `openssl rand -hex 32` produces in 10-deploy-workers.sh. Never
    regenerated: the deployed apps hold a copy, and a new token locks you out of /metrics."""
    path = store.secrets / name
    if path.exists():
        ck.ok(name, "kept")
        return
    _atomic_write(path, _secrets.token_hex(32) + "\n")
    ck.ok(name, "generated")


def render_templates(store: Store, ck: Checks) -> None:
    prefix = store.azure["prefix"]
    workers = int(store.azure["workers"])
    targets = [f"{prefix}-worker"] + [f"{prefix}-worker-{n}" for n in range(2, workers + 1)]
    block = "\n".join(f"      - targets: ['{t}.azurewebsites.net:443']" for t in targets)
    subs = {
        "__PREFIX__": prefix,
        "__WORKER_TARGETS__": block,
    }
    for tmpl_name, out_name in (("prometheus.yml.template", "prometheus.yml"),
                                ("docker-compose.yml.template", "docker-compose.yml")):
        tmpl = ROOT / "observability" / tmpl_name
        if not tmpl.exists():
            ck.warn(out_name, f"{tmpl_name} missing; left as is")
            continue
        text = tmpl.read_text()
        for k, v in subs.items():
            text = text.replace(k, v)
        _atomic_write(ROOT / "observability" / out_name, text, mode=0o644)
        ck.ok(out_name, f"rendered for {prefix}")


def step_config(store: Store, ck: Checks) -> bool:
    store.secrets.mkdir(parents=True, exist_ok=True)
    os.chmod(store.secrets, 0o700)
    ck.ok("secrets directory", f"{store.secrets} (700)")

    ensure_token(store, "metrics_token", ck)
    ensure_token(store, "control_token", ck)

    prefix = store.azure["prefix"]
    for arm in store.config.get("arms", []):
        arm["taskQueue"] = f"{prefix}-{arm['name']}"
    store.save_config()
    ck.ok("task queues", f"{prefix}-<arm> for {len(store.config.get('arms', []))} arms")

    store.save_harness()
    ck.ok("harness.json", str(store.harness_path))
    ck.ok("testconfig.json", str(store.config_path))

    render_templates(store, ck)

    # A live token inside the working tree is the thing docs/RUNBOOK.md argues against:
    # gitignore stops a commit, not a shell command or an agent.
    stray = ROOT / "observability" / "secrets" / "metrics_token"
    if stray.exists():
        ck.warn("token in the working tree", str(stray))
        if INTERACTIVE and ask("move it into the secrets directory?", default=True):
            dest = store.secrets / "metrics_token"
            if dest.exists():
                stray.unlink()
                note(f"removed {stray}; {dest} already held one")
            else:
                shutil.move(str(stray), str(dest))
                os.chmod(dest, 0o600)
                note(f"moved to {dest}")
            ck.warned -= 1
    return ck.failed == 0


# ---------------------------------------------------------------------------- step 7

# Fields the run scripts read: 66-run-all.sh wants arm/cache/gc/worker_app/task_queue/order,
# 64-run-remaining.sh wants the pending ones, 68-collect-all.sh maps arm to worker app,
# 67-watch-all.sh draws its table from it, and lib-state-set.py writes launched_at and
# outcome back. All of it is derivable from testconfig.json and harness.json, which is why
# setup can write it and nothing else ever had to.
DEFAULT_CAP_MINUTES = 90


def build_arms(store: Store) -> list[dict]:
    prefix = store.azure["prefix"]
    workers = int(store.azure["workers"])
    arms = []
    for i, arm in enumerate(store.config.get("arms", []), 1):
        name = arm["name"]
        # One arm per worker app so no two arms share a heap or an 8 GiB budget. Past the
        # fleet size the mapping wraps, which 66-run-all.sh would run concurrently on one
        # box: caught below rather than discovered as two arms invalidating each other.
        n = i if i <= workers else workers
        arms.append({
            "arm": name,
            "cache": arm["maxCachedWorkflows"],
            # The GC hard limit is part of the arm identity, not an ambient env var: two arms
            # share a cache size and only the mode tells them apart.
            "gc": "nolimit" if name.endswith("-nolimit") else "limit",
            "worker_app": f"{prefix}-worker" if n == 1 else f"{prefix}-worker-{n}",
            "task_queue": arm["taskQueue"],
            "order": i,
            "state": "pending",
            "launched_at": None,
            "expect_done_at": None,
            "outcome": None,
        })
    return arms


def step_runstate(store: Store, ck: Checks) -> bool:
    arms = build_arms(store)
    if not arms:
        ck.no("arms", "testconfig.json lists none")
        return False

    workers = int(store.azure["workers"])
    if len(arms) > workers:
        ck.warn("arms vs worker apps",
                f"{len(arms)} arms, {workers} worker apps: the last ones share a box")

    # A legacy state file is run state, not history, so moving it keeps a half-finished run
    # alive instead of restarting it.
    legacy = ROOT / "docs" / "PHASE2-STATE.json"
    if legacy.exists() and not store.state_path.exists():
        if INTERACTIVE and ask(f"move {legacy} to {store.state_path}?", default=True):
            shutil.move(str(legacy), str(store.state_path))
            ck.ok("migrated run state", f"from {legacy}")

    if store.state_path.exists():
        try:
            prev = json.loads(store.state_path.read_text())
        except json.JSONDecodeError:
            prev = {}
        by_name = {a.get("arm"): a for a in prev.get("arms", [])}
        live = [n for n, a in by_name.items() if a.get("state") == "launched"]
        for a in arms:
            old = by_name.get(a["arm"])
            if old:
                # Keep what happened; refresh only what is derived from the config, so a
                # prefix change rewrites the queue and app names without forgetting a run.
                for k in ("state", "launched_at", "expect_done_at", "outcome"):
                    if k in old:
                        a[k] = old[k]
        kept = sum(1 for a in arms if a["state"] != "pending")
        if live:
            # An arm left launched is a population still heartbeating, roughly $25/hour.
            ck.warn("arm still launched", f"{', '.join(live)}: run ./deploy/71-park.sh")
        ck.ok("existing run state", f"{kept} of {len(arms)} arms carried over")

    state = {
        "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "cap_minutes": DEFAULT_CAP_MINUTES,
        "arms": arms,
    }
    _atomic_write(store.state_path, json.dumps(state, indent=2) + "\n")
    ck.ok("run-state.json", f"{len(arms)} arms, {sum(1 for a in arms if a['state'] == 'pending')} pending")
    for a in arms:
        note(f"  {a['order']}. {a['arm']:<18} cache={a['cache']:<6} gc={a['gc']:<8} "
             f"{a['worker_app']}")
    return ck.failed == 0


# ---------------------------------------------------------------------------- step 8

def step_verify(store: Store, ck: Checks) -> bool:
    step_platform(store, ck)
    for tool in TOOLS:
        got = tool["detect"]()
        if got:
            ck.ok(tool["label"], str(got) if got is not True else "")
        elif tool["required"]:
            ck.no(tool["label"], "not found")
        else:
            ck.warn(tool["label"], "not available")

    acct = az_account()
    if acct:
        ck.ok("az login", f"{acct.get('name')} ({acct.get('id')})")
        rg = store.azure.get("resourceGroup", "")
        if rg and run(["az", "group", "show", "-n", rg, "--output", "none"]).returncode == 0:
            ck.ok("resource group", rg)
        else:
            ck.no("resource group", f"{rg or 'unset'} not found")
    else:
        ck.no("az login", "no active session")

    prefix = store.azure.get("prefix", "")
    if prefix and prefix != SHARED_PREFIX:
        ck.ok("resource prefix", prefix)
    else:
        ck.no("resource prefix", "unset or still the shared default")

    for name in ("client.pem", "client.key", "metrics_token", "control_token"):
        p = store.secret(name)
        (ck.ok if p else ck.no)(name, str(p.parent) if p else "missing")

    if not store.config_path.exists():
        ck.no("testconfig.json", "not written")
    elif "<" in json.dumps(store.config.get("temporal", {})):
        ck.no("testconfig.json", "still contains placeholders")
    else:
        ck.ok("testconfig.json", str(store.config_path))

    if not store.state_path.exists():
        ck.no("run-state.json", "not written; 64/66/67/68 cannot run without it")
    else:
        try:
            st = json.loads(store.state_path.read_text())
            pending = sum(1 for a in st.get("arms", []) if a.get("state") == "pending")
            live = [a["arm"] for a in st.get("arms", []) if a.get("state") == "launched"]
            if live:
                ck.warn("run-state.json", f"{', '.join(live)} still launched: ./deploy/71-park.sh")
            else:
                ck.ok("run-state.json", f"{len(st.get('arms', []))} arms, {pending} pending")
        except json.JSONDecodeError:
            ck.no("run-state.json", "unreadable")

    temporal_connect(store, ck)

    # Gitignoring a secret is pointless if one is already in the index.
    tracked = run(["git", "-C", str(ROOT), "ls-files", "--error-unmatch", "certs/client.pem"])
    if tracked.returncode == 0:
        ck.no("cert NOT tracked by git", "certs/client.pem IS TRACKED; remove it from the index")
    else:
        ck.ok("cert NOT tracked by git")
    return ck.failed == 0


def print_next_steps(store: Store) -> None:
    az = store.azure
    plans = int(az["workers"]) + 1
    say("Ready. Nothing has been provisioned yet.")
    print(f"""
    ./deploy/00-provision.sh            # plans first: a quota refusal costs nothing
    ./deploy/10-deploy-workers.sh       # one binary, one arm per app setting
    ./deploy/30-deploy-observability.sh # or: docker compose -f observability/docker-compose.yml up -d
    PROFILE=smoke ./deploy/20-deploy-driver.sh

    Then the smoke gates in docs/RUNBOOK.md. Only once they pass:

    PROFILE=ramp ./deploy/20-deploy-driver.sh
""")
    note(f"Worker app:  https://{az['prefix']}-worker.azurewebsites.net")
    note(f"Config:      {store.config_path}")
    note(f"Harness:     {store.harness_path}")
    note(f"Run state:   {store.state_path}")
    note(f"Provisioning bills about ${plans * 3.70:.2f}/day until ./deploy/99-teardown.sh runs.")


# ---------------------------------------------------------------------------- driver

HANDLERS = {
    "platform": step_platform,
    "deps": step_deps,
    "azure-login": step_azure_login,
    "azure-naming": step_azure_naming,
    "temporal": step_temporal,
    "config": step_config,
    "run-state": step_runstate,
    "verify": step_verify,
}

# --check never writes. step_verify already re-runs the platform and dependency probes, so
# running it alone covers everything without printing each check twice.
CHECK_ONLY = ["verify"]


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        prog="deploy/setup.sh",
        description="Prepare this machine to run the cache-test harness. Provisions nothing.")
    ap.add_argument("--check", action="store_true",
                    help="verify only: write nothing, exit non-zero on any failure")
    ap.add_argument("--reset", metavar="N",
                    help=f"redo step N (1-{len(STEP_IDS)}, a step name, or 'all') "
                         "and everything after it")
    ap.add_argument("--secrets-dir", default=os.environ.get("SECRETS_DIR", str(DEFAULT_SECRETS)),
                    help=f"where secrets and config live (default {DEFAULT_SECRETS})")
    ap.add_argument("--non-interactive", action="store_true",
                    help="never prompt; use saved values and defaults")
    return ap.parse_args(argv)


def resolve_reset(value: str) -> list[str]:
    if value == "all":
        return list(STEP_IDS)
    if value.isdigit() and 1 <= int(value) <= len(STEP_IDS):
        return [STEP_IDS[int(value) - 1]]
    if value in STEP_IDS:
        return [value]
    raise Aborted(f"--reset wants 1-{len(STEP_IDS)}, a step name, or 'all'; got {value!r}")


def already_configured(store: Store) -> int | None:
    """Every step complete. Re-walking them would rewrite config files and re-probe Azure for
    no reason, so ask instead of assuming. Returns an exit code to stop on, or None to carry
    on into the normal walk."""
    az = store.azure
    say("Already set up")
    note(f"prefix       {az.get('prefix')}")
    note(f"group        {az.get('resourceGroup')} in {az.get('location')}")
    note(f"namespace    {store.temporal.get('namespace')}")
    note(f"secrets      {store.secrets}")
    print()

    if not INTERACTIVE:
        note("Nothing to do. Use --check to verify, or --reset N to change a step.")
        return 0

    what = choose("what now", [
        ("quit", "quit, everything is already configured"),
        ("verify", "re-verify: check the tools, logins and certificate again"),
        ("reconfigure", "reconfigure: pick a step to redo"),
    ])
    if what == "quit":
        print_next_steps(store)
        return 0
    if what == "verify":
        say("Verifying")
        ck = Checks()
        ok = step_verify(store, ck)
        print()
        if ok:
            print("All checks passed." + (f" {ck.warned} warning(s)." if ck.warned else ""))
            print_next_steps(store)
            return 0
        print(f"{ck.failed} failure(s). Re-run and pick 'reconfigure' to fix them.")
        return 1

    say("Which step?")
    opts = [(sid, f"{i}. {title}") for i, (sid, title) in enumerate(STEPS, 1)]
    # Redoing a step redoes everything after it: the later steps derive from the earlier ones,
    # so changing the prefix at step 4 leaves step 6's task queues and Prometheus targets stale.
    pick = choose("step", opts, len(opts) - 1)
    store.reset_from(pick)
    note(f"Redoing step {STEP_IDS.index(pick) + 1} ({pick}) and everything after it.")
    return None


def main(argv: list[str]) -> int:
    global INTERACTIVE
    args = parse_args(argv)
    INTERACTIVE = not (args.check or args.non_interactive) and sys.stdin.isatty()

    store = Store(Path(args.secrets_dir).expanduser())

    if args.reset:
        first = resolve_reset(args.reset)[0]
        store.reset_from(first)
        note(f"Reset from step {STEP_IDS.index(first) + 1} ({first}) onwards.")

    if args.check:
        say("Checking (nothing will be written)")
        ck = Checks()
        for step_id in CHECK_ONLY:
            HANDLERS[step_id](store, ck)
        print()
        if ck.failed:
            print(f"{ck.failed} failure(s). Run ./deploy/setup.sh to fix them.")
            return 1
        print("All checks passed." + (f" {ck.warned} warning(s)." if ck.warned else ""))
        return 0

    if all(store.done(s) for s in STEP_IDS) and not args.reset:
        rc = already_configured(store)
        if rc is not None:
            return rc

    done = [s for s in STEP_IDS if store.done(s)]
    if done:
        last = max(STEP_IDS.index(s) for s in done) + 1
        print(f"\n  Resuming. {len(done)} of {len(STEP_IDS)} steps already complete "
              f"(through step {last}).")

    failures = 0
    for n, (step_id, title) in enumerate(STEPS, 1):
        if store.done(step_id):
            print(f"\n  Step {n} of {len(STEPS)}: {title} "
                  + _c("32", "done") + f"   (redo with --reset {n})")
            continue
        say(f"Step {n} of {len(STEPS)}: {title}")
        ck = Checks()
        try:
            ok = HANDLERS[step_id](store, ck)
        except Aborted as exc:
            print()
            note(f"Stopped: {exc}")
            note("Progress is saved. Re-run ./deploy/setup.sh to pick up here.")
            return 130
        store.save_harness()
        if ok:
            store.mark(step_id)
        else:
            failures += 1
            print()
            note(f"Step {n} did not pass. Fix the FAIL lines above and re-run.")
            note(f"Everything up to step {n - 1} is saved.")
            return 1

    print_next_steps(store)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Aborted as exc:
        print(f"\n    Stopped: {exc}")
        sys.exit(130)
    except KeyboardInterrupt:
        print("\n    Interrupted. Progress is saved; re-run to resume.")
        sys.exit(130)
