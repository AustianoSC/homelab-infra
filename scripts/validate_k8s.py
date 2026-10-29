#!/usr/bin/env python3
"""Check the Kubernetes manifests that Argo CD would deploy, without a cluster.

Run it as `make validate`. The same script runs in the pre-commit hook and in
CI, so a mistake is caught before it reaches `main`, where Argo CD would apply
it within minutes.

What it does:
  1. Reads every Application in kubernetes/argocd/applications. For each Helm
     chart source it runs `helm template` with the pinned chart version and the
     values file from this repo, which is what Argo CD renders. Argo CD itself
     (installed by `make argocd`, not by an Application) is rendered the same
     way, with its version read from the Makefile.
  2. For each plain-manifest source (a `path` in this repo) it picks the files
     Argo CD would pick, honouring `directory.include`.
  3. Runs `kubeconform` over all of that, plus the Application files.

There is no second copy of any chart version or path: it all comes from the
files Argo CD reads. Needs `helm`, `kubeconform` and network access (chart
repositories and schemas are downloaded). PyYAML is installed by `make validate`
from scripts/requirements.txt.
"""

import fnmatch
import os
import re
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    sys.exit("Missing Python package: PyYAML. Run this with `make validate`, "
             "which installs it from scripts/requirements.txt")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APPS_DIR = os.path.join(ROOT, "kubernetes", "argocd", "applications")

# Schemas for custom resources (Argo CD, External Secrets, MetalLB...). Kinds
# with no schema in the catalog are skipped, not failed.
CRD_CATALOG = (
    "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/"
    "{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
)


def need(tool, hint):
    if shutil.which(tool) is None:
        sys.exit(f"Missing tool: {tool} ({hint})")


def rel(path):
    return os.path.relpath(path, ROOT)


def application_sources():
    """Yield (app name, destination namespace, source) for every Application."""
    for path in sorted(
        f for f in os.listdir(APPS_DIR) if f.endswith((".yaml", ".yml"))
    ):
        with open(os.path.join(APPS_DIR, path)) as fh:
            doc = yaml.safe_load(fh)
        if not doc or doc.get("kind") != "Application":
            continue
        spec = doc["spec"]
        sources = spec.get("sources") or [spec["source"]]
        namespace = spec["destination"]["namespace"]
        for source in sources:
            yield doc["metadata"]["name"], namespace, source


def argocd_chart():
    """Argo CD isn't an Application; its chart version lives in the Makefile."""
    with open(os.path.join(ROOT, "Makefile")) as fh:
        match = re.search(r"^ARGOCD_CHART_VERSION\s*:=\s*(\S+)", fh.read(), re.M)
    if not match:
        sys.exit("ARGOCD_CHART_VERSION not found in the Makefile")
    return {
        "name": "argocd",
        "repo": "https://argoproj.github.io/argo-helm",
        "chart": "argo-cd",
        "version": match.group(1),
        "release": "argocd",
        "namespace": "argocd",
        "values": [os.path.join(ROOT, "kubernetes", "argocd", "values.yaml")],
    }


def plain_manifests(source):
    """The files Argo CD would read from a `path` source."""
    directory = os.path.join(ROOT, source["path"])
    include = source.get("directory", {}).get("include")
    patterns = re.split(r",", include.strip("{}")) if include else None
    files = []
    for name in sorted(os.listdir(directory)):
        full = os.path.join(directory, name)
        if not os.path.isfile(full):
            continue
        if patterns:
            if not any(fnmatch.fnmatch(name, p) for p in patterns):
                continue
        elif not name.endswith((".yaml", ".yml", ".json")):
            continue
        files.append(full)
    return files


def render(chart, outdir):
    out = os.path.join(outdir, chart["name"] + ".yaml")
    cmd = [
        "helm", "template", chart["release"], chart["chart"],
        "--repo", chart["repo"], "--version", chart["version"],
        "-n", chart["namespace"], "--include-crds",
    ]
    for values in chart["values"]:
        cmd += ["-f", values]
    print(f"helm template {chart['chart']} {chart['version']} ({chart['name']})", flush=True)
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        sys.exit(f"helm template failed for {chart['name']}")
    with open(out, "w") as fh:
        fh.write(result.stdout)
    return out


def main():
    need("helm", "https://helm.sh/docs/intro/install/")
    need("kubeconform", "brew install kubeconform, or see the README")

    charts = [argocd_chart()]
    manifests = [os.path.join(ROOT, "kubernetes", "argocd", "root-app.yaml")]
    for app, namespace, source in application_sources():
        if "chart" in source:
            helm = source.get("helm", {})
            charts.append({
                "name": app,
                "repo": source["repoURL"],
                "chart": source["chart"],
                "version": source["targetRevision"],
                "release": helm.get("releaseName", app),
                "namespace": namespace,
                "values": [
                    v.replace("$values/", ROOT + os.sep)
                    for v in helm.get("valueFiles", [])
                ],
            })
        elif "path" in source:
            manifests += plain_manifests(source)

    manifests += [
        os.path.join(APPS_DIR, f)
        for f in sorted(os.listdir(APPS_DIR))
        if f.endswith((".yaml", ".yml"))
    ]
    manifests = list(dict.fromkeys(manifests))  # no duplicates, order kept

    with tempfile.TemporaryDirectory() as tmp:
        rendered = [render(chart, tmp) for chart in charts]
        cache = os.path.join(
            os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
            "kubeconform",
        )
        os.makedirs(cache, exist_ok=True)
        print(f"kubeconform: {len(rendered)} rendered charts, {len(manifests)} manifests", flush=True)
        for path in manifests:
            print("  " + rel(path), flush=True)
        result = subprocess.run([
            "kubeconform", "-strict", "-summary", "-ignore-missing-schemas",
            "-cache", cache,
            "-schema-location", "default",
            "-schema-location", CRD_CATALOG,
            *rendered, *manifests,
        ])
    sys.exit(result.returncode)


if __name__ == "__main__":
    main()
