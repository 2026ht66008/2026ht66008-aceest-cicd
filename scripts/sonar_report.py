"""Save this project's SonarQube results to reports/ as Markdown and JSON.

Jenkins runs it at the end of the SonarQube stage, so every build keeps a copy
of the quality gate result, the main metrics and the list of open issues.

Needs SONAR_TOKEN in the environment. SONAR_HOST_URL and SONAR_PROJECT_KEY are optional.
"""
import base64
import json
import os
import pathlib
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

HOST = os.environ.get("SONAR_HOST_URL", "http://localhost:9000").rstrip("/")
PROJECT = os.environ.get("SONAR_PROJECT_KEY", "aceest-fitness")
OUT_DIR = pathlib.Path("reports")

METRICS = {
    "ncloc": "Lines of code",
    "coverage": "Coverage (%)",
    "duplicated_lines_density": "Duplicated lines (%)",
    "bugs": "Bugs",
    "vulnerabilities": "Vulnerabilities",
    "code_smells": "Code smells",
    "security_hotspots": "Security hotspots",
    "reliability_rating": "Reliability rating",
    "security_rating": "Security rating",
    "sqale_rating": "Maintainability rating",
}
RATINGS = {"1.0": "A", "2.0": "B", "3.0": "C", "4.0": "D", "5.0": "E"}


def get(path, **params):
    """GET a SonarQube Web API endpoint and return the JSON body."""
    url = f"{HOST}{path}?{urllib.parse.urlencode(params)}"
    token = os.environ["SONAR_TOKEN"]
    request = urllib.request.Request(url)
    request.add_header("Authorization",
                       "Basic " + base64.b64encode(f"{token}:".encode()).decode())
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def fetch_issues():
    """Open issues for the project (newer servers use 'components', older 'componentKeys')."""
    for key in ("components", "componentKeys"):
        try:
            return get("/api/issues/search", **{key: PROJECT}, resolved="false", ps=200)
        except urllib.error.HTTPError:
            continue
    return {"issues": [], "total": 0}


def issue_kind(issue):
    """Software quality + severity, from 'impacts' on newer servers or type/severity on older."""
    impacts = issue.get("impacts") or []
    if impacts:
        return ", ".join(f"{i['softwareQuality'].title()} ({i['severity'].title()})"
                         for i in impacts)
    kind = issue.get("type", "?").replace("_", " ").title()
    return f"{kind} ({issue.get('severity', '?').title()})"


def build_markdown(gate, measures, issues):
    status = gate["projectStatus"]["status"]
    lines = [
        "# SonarQube report: ACEest Fitness and Gym",
        "",
        f"Generated {datetime.now(timezone.utc):%Y-%m-%d %H:%M} UTC from {HOST} "
        f"(project `{PROJECT}`).",
        "",
        f"Quality gate: **{'PASSED' if status == 'OK' else status}**",
        "",
        "| Metric | Value |",
        "|---|---|",
    ]
    values = {m["metric"]: m.get("value", "-") for m in measures["component"]["measures"]}
    for key, label in METRICS.items():
        value = values.get(key, "-")
        if key.endswith("_rating"):
            value = RATINGS.get(value, value)
        lines.append(f"| {label} | {value} |")

    lines += ["", f"## Open issues ({issues.get('total', len(issues['issues']))})", ""]
    if issues["issues"]:
        lines += ["| Type (severity) | File | Line | Message |", "|---|---|---|---|"]
        for issue in issues["issues"]:
            path = issue["component"].split(":", 1)[-1]
            message = issue["message"].replace("|", "\\|")
            lines.append(f"| {issue_kind(issue)} | {path} | {issue.get('line', '-')} | {message} |")
    else:
        lines.append("No open issues.")
    return "\n".join(lines) + "\n"


def main():
    OUT_DIR.mkdir(exist_ok=True)
    try:
        gate = get("/api/qualitygates/project_status", projectKey=PROJECT)
        measures = get("/api/measures/component", component=PROJECT,
                       metricKeys=",".join(METRICS))
        issues = fetch_issues()
    except (urllib.error.URLError, KeyError) as err:
        # The quality gate itself was already checked by the scanner, so don't fail the build
        message = f"Could not read the SonarQube report from {HOST}: {err}"
        print("WARNING:", message)
        (OUT_DIR / "sonarqube-report.md").write_text(f"# SonarQube report\n\n{message}\n")
        return 0

    (OUT_DIR / "sonarqube-report.json").write_text(
        json.dumps({"quality_gate": gate, "measures": measures, "issues": issues}, indent=2))
    markdown = build_markdown(gate, measures, issues)
    (OUT_DIR / "sonarqube-report.md").write_text(markdown)
    print(markdown)
    return 0


if __name__ == "__main__":
    sys.exit(main())
