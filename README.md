# ACEest Fitness & Gym - DevOps Assignment 2

Course: Introduction to DevOps (CSIZG514/SEZG514)

Name: Himanshu Pandey

BITS ID: 2026ht66008

## About

This repo takes the ACEest Flask app from Assignment 1 and runs it through a complete CI/CD pipeline:

- Jenkins polls GitHub, runs the Pytest suite, checks the code with SonarQube, builds a Docker image, tests it inside the container and pushes it to Docker Hub.
- The app is deployed to Kubernetes (Minikube on the Prayogshala VM) with five deployment strategies running side by side: rolling update, blue-green, canary, A/B testing and shadow.
- Every strategy has a way back to the last stable version.

Links:

- GitHub repo: https://github.com/2026ht66008/2026ht66008-aceest-cicd
- Docker Hub images: https://hub.docker.com/r/2026ht66008/aceest-fitness/tags
- Rolling update: http://<vm-ip>:30081
- Blue-green (live): http://<vm-ip>:30082
- Blue-green (idle/preview): http://<vm-ip>:30086
- Canary: http://<vm-ip>:30083
- A/B testing: http://<vm-ip>:30084
- Shadow: http://<vm-ip>:30085
- Jenkins: http://<vm-ip>:8080 (job ACEest-Fitness), SonarQube: http://<vm-ip>:9000

The <vm-ip> links only open inside the Prayogshala network. The Prayogshala VM is reset between sessions, so the cluster runs during lab sessions only.

## Versions

The same 10 versions as Assignment 1. The main file is ACEest_Fitness.py. Each version went in on its own feature branch through a pull request and was tagged after merging. Each tag has a matching Docker image on Docker Hub (2026ht66008/aceest-fitness:v1.0 ... v3.2.4).

| Tag | What it added |
|---|---|
| v1.0 | Program viewer with workout and diet plans for Fat Loss, Muscle Gain and Beginner |
| v1.1 | Client profile and calorie estimate |
| v1.1.2 | Client list, coach notes, CSV export and a progress chart |
| v2.0.1 | SQLite database: save and load clients, weekly progress |
| v2.1.2 | No changes (same code as 2.0.1 in the original) |
| v2.2.1 | Weekly adherence chart |
| v2.2.4 | Goals, workouts, body metrics, BMI, weight chart, workout history |
| v3.0.1 | No changes (same code as 2.2.4 in the original) |
| v3.1.2 | Login, membership expiry, AI workout generator, PDF report |
| v3.2.4 | New dashboard with program templates, membership check and a workouts tab |

Every version has web pages, a JSON API under /api/ and a /health route that returns the version. The deployment checks use /health. From v3.1.2 there is a login page (admin / admin).

## Repository layout

```
ACEest_Fitness.py          the Flask app
templates/ static/         pages and styling
tests/                     Pytest suite
requirements.txt
Dockerfile                 image used for every version
Jenkinsfile                the pipeline
sonar-project.properties   SonarQube settings
k8s/                       Kubernetes manifests (one file per strategy) and deploy.sh
scripts/                   VM setup, build-all-versions, SonarQube report export
reports/                   SonarQube report saved from the pipeline
```

## Running locally

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python -m flask --app ACEest_Fitness run --debug     # then open http://127.0.0.1:5000
python -m pytest -v
```

With Docker:

```bash
docker build -t aceest-fitness .
docker run --rm aceest-fitness python -m pytest -q   # tests inside the container
docker run -d -p 5000:5000 aceest-fitness
```

## Jenkins pipeline

The job ACEest-Fitness reads the Jenkinsfile from main and polls GitHub every 2 minutes.

1. Checkout - clean workspace, fresh clone, read the version from ACEest_Fitness.py
2. Build - virtualenv and requirements
3. Unit Tests - pytest with JUnit results and a coverage report
4. SonarQube Quality Gate - analysis with coverage; the build stops if the gate fails. The results are also saved to reports/
5. Docker Build - image tagged with the version (e.g. v3.2.4) and latest
6. Test in Container - pytest again inside the image
7. Push to Docker Hub
8. Build All Versions (optional) - builds, tests and pushes an image for every tag
9. Archive Artifacts - source archive of each version, test results, coverage, SonarQube report
10. Deploy: Rolling Update - with automatic rollback if the new pods don't become healthy
11. Deploy: Blue-Green, Canary, A/B Testing, Shadow (optional, "all-strategies")
12. Rollback Demo (optional) - deploys a tag that doesn't exist to show the automatic rollback

## Deployment strategies

All five run in the aceest namespace on Minikube. Images come from Docker Hub.

| Strategy | Port | How it works | Rollback |
|---|---|---|---|
| Rolling update | 30081 | 2 replicas, one pod replaced at a time (maxSurge 1, maxUnavailable 0), readiness probe on /health | automatic if the rollout or health check fails; otherwise `kubectl rollout undo` |
| Blue-green | 30082 / 30086 | two copies; the new version goes to the idle colour, is checked on the preview port, then the live Service selector is switched | switch the Service back (old colour is still running) |
| Canary | 30083 | an NGINX router sends 4 of 5 requests to stable, 1 to the new version | scale the canary to 0, all traffic goes to stable |
| A/B testing | 30084 | NGINX puts users in group A or B (50/50 by client address and browser); the header X-AB-Group or cookie ab_group can pick a group | scale B to 0, everyone gets A |
| Shadow | 30085 | users get the live version; NGINX mirrors every request to the new version, whose answers are thrown away | scale the shadow to 0 (users never saw it) |

k8s/deploy.sh does each of these, and `./k8s/deploy.sh rollback <strategy>` undoes them.

## Running it on Prayogshala

The VM is reset between sessions, so each session starts with:

```bash
git clone https://github.com/2026ht66008/2026ht66008-aceest-cicd
cd <repo>
sudo bash scripts/setup-prayogshala.sh
```

That installs SonarQube, SonarScanner, kubectl and Minikube, and lets Jenkins use Docker and the cluster. Then the two Jenkins credentials (sonar-token, dockerhub) and the job are added in the Jenkins UI.

## SonarQube

See reports/sonarqube-report.md (saved by the pipeline) and the screenshots below.

## Screenshots

(added after the Prayogshala run)
