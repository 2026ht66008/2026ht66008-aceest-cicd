# ACEest Fitness & Gym - DevOps Assignment 2

Course: Introduction to DevOps (CSIZG514/SEZG514)

Name: Himanshu Pandey

BITS ID: 2026ht66008

## About

This repo continues Assignment 1. The same ACEest Flask app now goes through a full CI/CD pipeline:

- Jenkins polls this repo, runs the tests, checks the code with SonarQube, builds a Docker image, tests it again inside the container and pushes it to Docker Hub.
- The app is deployed to Kubernetes (Minikube on my Prayogshala VM) with five deployment strategies running side by side: rolling update, blue-green, canary, A/B testing and shadow.
- Every strategy has a way back to the last stable version, and the rolling update rolls back by itself if a release fails.

## Links

- GitHub repo: https://github.com/2026ht66008/2026ht66008-aceest-cicd
- Docker Hub images: https://hub.docker.com/r/2026ht66008/aceest-fitness/tags

Endpoints from the Prayogshala session on 23 November 2026 (VM 10.3.17.60):

| Strategy | URL |
|---|---|
| Rolling update | http://10.3.17.60:30081 |
| Blue-green (live) | http://10.3.17.60:30082 |
| Blue-green (idle/preview) | http://10.3.17.60:30086 |
| Canary | http://10.3.17.60:30083 |
| A/B testing | http://10.3.17.60:30084 |
| Shadow | http://10.3.17.60:30085 |
| Jenkins (job ACEest-Fitness) | http://10.3.17.60:8080 |
| SonarQube (project aceest-fitness) | http://10.3.17.60:9000 |

These addresses only open inside the Prayogshala network. The VM is reset after every session and can get a different IP, so the cluster only runs while I'm in a lab session. The screenshots below are from that run.

## Versions

The same 10 versions as Assignment 1, with the main file named ACEest_Fitness.py. Each version went in on its own feature branch through a pull request and was tagged after merging. Each tag has a matching image on Docker Hub (2026ht66008/aceest-fitness:v1.0 to v3.2.4, plus latest).

| Tag | What it added | Tests |
|---|---|---|
| v1.0 | Program viewer with workout and diet plans for Fat Loss, Muscle Gain and Beginner | 20 |
| v1.1 | Client profile and calorie estimate | 42 |
| v1.1.2 | Client list, coach notes, CSV export and a progress chart | 32 |
| v2.0.1 | SQLite database: save and load clients, weekly progress | 41 |
| v2.1.2 | No changes (same code as 2.0.1 in the original) | 41 |
| v2.2.1 | Weekly adherence chart | 48 |
| v2.2.4 | Goals, workouts, body metrics, BMI, weight chart, workout history | 76 |
| v3.0.1 | No changes (same code as 2.2.4 in the original) | 76 |
| v3.1.2 | Login, membership expiry, AI workout generator, PDF report | 56 |
| v3.2.4 | New dashboard with program templates, membership check and a workouts tab | 43 |

Every version has web pages, a few JSON API routes under /api/ and a /health route that returns the version. All the deployment checks use /health. From v3.1.2 there is a login page (admin / admin).

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
docs/screenshots/          screenshots used in this README
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

The Dockerfile uses python:3.12-slim, installs the requirements before copying the code so that layer is cached, runs as a non-root user (uid 10001) and serves the app with gunicorn. The .dockerignore keeps .git, the venv, the k8s files, reports and screenshots out of the image.

## Jenkins pipeline

The job ACEest-Fitness reads the Jenkinsfile from main and polls GitHub every 2 minutes. The stages are:

1. Checkout - clean workspace, fresh clone, and the version is read from ACEest_Fitness.py
2. Build - virtualenv and requirements
3. Unit Tests - pytest, with JUnit results and a coverage report
4. SonarQube Quality Gate - the scanner sends the code and the coverage to SonarQube and waits for the gate. If the gate fails, the build stops here. The results are also saved to reports/.
5. Docker Build - image tagged with the version (for example v3.2.4) and latest
6. Test in Container - pytest again, inside the new image
7. Push to Docker Hub
8. Build All Versions (optional) - for every git tag, builds an image from that tag's code, runs its tests inside it and pushes it
9. Archive Artifacts - a source archive of each version, test results, coverage, the SonarQube report and the image list
10. Deploy: Rolling Update - with automatic rollback if the new pods don't become healthy
11. Deploy: Blue-Green, Canary, A/B Testing, Shadow (optional, when DEPLOY is all-strategies)
12. Rollback Demo (optional) - deploys a version that doesn't exist, to show the automatic rollback

A normal commit to main runs stages 1-7, 9 and 10. The optional stages are chosen with Build with Parameters.

## Deployment strategies

All five run in the aceest namespace on Minikube, and every image comes from Docker Hub. For the comparison strategies I kept v3.1.2 as the stable version and v3.2.4 as the new one.

| Strategy | Port | How it works | Rollback |
|---|---|---|---|
| Rolling update | 30081 | 2 replicas, one pod replaced at a time (maxSurge 1, maxUnavailable 0), readiness probe on /health. After the rollout, the tests run inside the running pod. | Automatic if the rollout or the checks fail; otherwise kubectl rollout undo |
| Blue-green | 30082, 30086 | Two copies of the app. The new version goes to the idle colour, is checked on the preview port, then the live Service is switched to it. | Switch the Service back. The old colour is still running, so it is instant. |
| Canary | 30083 | A small NGINX router sends 4 of every 5 requests to the stable version and 1 to the new one. | Scale the canary to 0, all traffic goes to stable |
| A/B testing | 30084 | NGINX puts each user in group A or B (50/50, by client address and browser, so a user stays in the same group). A tester can pick a group with the header X-AB-Group or the cookie ab_group. The response header says which group answered. | Scale B to 0, everyone gets A |
| Shadow | 30085 | Users get the live version. NGINX copies every request to the new version and throws its answers away. | Scale the shadow to 0. Users never saw it. |

k8s/deploy.sh does each of these, and ./k8s/deploy.sh rollback followed by the strategy name undoes them. I used small NGINX routers for canary, A/B and shadow because they need request-level routing, and installing Istio or an ingress controller would have been too heavy for the lab VM.

## Prayogshala setup

The VM is Rocky Linux 9.5 with 7.4 GB of RAM and 2 CPUs. Jenkins is already installed, but everything else is lost when the VM resets, so I wrote scripts/setup-prayogshala.sh to rebuild it in one go (about 15-20 minutes):

- SonarQube Community in Docker on port 9000, after raising vm.max_map_count
- SonarScanner CLI in /opt/sonar-scanner
- kubectl and Minikube
- the jenkins user added to the docker group
- Minikube started as the jenkins user (so the pipeline can run kubectl), with ports 30081-30086 published on the VM's own IP

After that I only add two Jenkins credentials (sonar-token and dockerhub) and the job.

Versions on the VM: Jenkins 2.568.1, Minikube 1.39.0 with Kubernetes 1.37.0, SonarQube Community Build 26.11, SonarScanner 8.1.

## Results from the run on 23 November 2026

| Build | Started by | What it did | Result |
|---|---|---|---|
| #1 | me | Normal pipeline, first push of v3.2.4, first rolling update | Success |
| #2 | me | Build All Versions + all five strategies | Success, 9 min 27 s |
| #3 | me | Rollback demo | Failed at Rollback Demo, as intended |
| #4 | me | All strategies again, after the manual rollbacks | Success |
| #5 | SCM change | Normal pipeline for two merged pull requests | Success, 3 min 45 s |

- All 10 images are on Docker Hub. Each one was tested inside the container before it was pushed (20 to 76 tests depending on the version).
- 43 tests pass for v3.2.4 in every build.
- Canary: 20 requests gave 16 answers from v3.1.2 and 4 from v3.2.4.
- Rollback demo: the bad version never became ready. After the 2 minute timeout the deployment was rolled back to v3.2.4. A loop calling /health once a second got 200 on every request during the whole build.
- Build #5 was started by Jenkins itself and picked up both of my merged pull requests in one build.

## SonarQube

The quality gate passed with the default gate: 706 lines of code, 100% coverage, 0% duplication. (In Assignment 1 coverage showed 0% because the coverage report wasn't sent; this time pytest-cov writes coverage.xml and the scanner reads it.) The full report is in reports/sonarqube-report.md.

SonarQube lists 4 open issues:

| Issue | Where | What I think |
|---|---|---|
| CSRF protection not enabled (Security, High) | ACEest_Fitness.py | Correct. The forms have no CSRF tokens. The fix would be Flask-WTF's CSRFProtect. |
| COPY . . might add sensitive data (Security, High) | Dockerfile | Reviewed. The .dockerignore keeps .git, the venv, reports and k8s files out of the image. |
| autofocus on the login field (Reliability, Medium) | templates/login.html | Small accessibility point |
| Same expression on both sides of an assert (Reliability, Medium) | tests | Intentional. The test checks that the same random seed gives the same program. |

## Issues I faced

- The Prayogshala VM is reset between sessions, so nothing I install stays. I put the whole setup in one script and kept everything else on GitHub and Docker Hub, so each session starts from a clone and that script.
- Reaching the NodePorts from a browser. Minikube runs inside a Docker container, so its NodePorts aren't on the VM's IP by default. I start it with --listen-address=0.0.0.0 and --ports for 30081-30086, so they are.
- Build with Parameters only appears after the job has run once, because Jenkins reads the parameters from the Jenkinsfile. The first build ran with the defaults.
- My GitHub token from Assignment 1 had expired, so the first push was rejected. I created a new token and cleared the old saved login.
- After rolling back to v3.1.2 and forward to v3.2.4, the rollout history skipped revision 2. Kubernetes reused the old ReplicaSet for v3.2.4 and renumbered it to revision 4, instead of creating a new one.
- With 7.4 GB for Jenkins, SonarQube and the cluster, I kept one replica per side for the comparison strategies (two for the rolling update) and set memory limits on every pod.

## Things to improve

- add CSRF protection to the forms
- use a Docker volume for the SQLite database, because right now the data is lost on every deploy
- set the admin password through a Kubernetes secret instead of the default
- trigger builds with a GitHub webhook instead of polling, if GitHub could reach Jenkins on the lab network

## Screenshots

### Setup on Prayogshala

The setup script, the cluster Ready and ports 30081-30086 published:

![Setup script and cluster](docs/screenshots/01-setup.png)

### Jenkins

All five builds. #2 built every version and deployed all strategies, #3 is the rollback demo, #5 was started by a commit:

![Jenkins stage view, builds 1 to 5](docs/screenshots/02-jenkins-stages.png)

Parameters of build #2:

![Build parameters](docs/screenshots/03-build-parameters.png)

Test results:

![43 tests passing](docs/screenshots/04-test-results.png)

Build artifacts: a source archive for every version, test results, coverage and the SonarQube report:

![Build artifacts](docs/screenshots/05-artifacts.png)

Build All Versions: each version is tested inside its image and pushed:

![Console output of Build All Versions](docs/screenshots/06-console-build-all-versions.png)

The status table at the end of build #2:

![Status table with the six URLs](docs/screenshots/07-console-status-table.png)

### Docker Hub

![Docker Hub tags v1.0 to v3.2.4 and latest](docs/screenshots/08-dockerhub-tags.png)

### SonarQube

![SonarQube overview](docs/screenshots/09-sonarqube-overview.png)

![SonarQube issues](docs/screenshots/10-sonarqube-issues.png)

### Kubernetes

![Pods and services](docs/screenshots/11-pods-services.png)

![deploy.sh status](docs/screenshots/12-deploy-status.png)

### Rolling update

Rollout history:

![Rollout history](docs/screenshots/13-rolling-history.png)

Rolling update from v3.2.4 to v3.1.2 and back. Left: pods replaced one at a time. Right: the update, with the tests run inside the running pod:

![Rolling update in progress](docs/screenshots/14-rolling-watch.png)

![Tests inside the running pod](docs/screenshots/15-rolling-tests-in-pod.png)

### Blue-green

Live points at green (v3.2.4), preview at blue (v3.1.2):

![Blue-green services](docs/screenshots/16-blue-green.png)

### Canary

20 requests, 16 to v3.1.2 and 4 to v3.2.4:

![Canary split](docs/screenshots/17-canary.png)

### A/B testing

The header picks the group, and the response says which group answered:

![A/B testing](docs/screenshots/18-ab-testing.png)

### Shadow

The user gets v3.1.2, and the v3.2.4 pod logs a copy of the same request (last line; the others are Kubernetes health probes):

![Shadow deployment](docs/screenshots/19-shadow.png)

### The strategies in the browser

![Rolling update, port 30081](docs/screenshots/20-browser-rolling.png)

![Blue-green live, port 30082](docs/screenshots/21-browser-blue-green-live.png)

![Blue-green preview, port 30086](docs/screenshots/22-browser-blue-green-preview.png)

![Canary, port 30083](docs/screenshots/23-browser-canary.png)

![A/B testing, port 30084](docs/screenshots/24-browser-ab.png)

![Shadow, port 30085](docs/screenshots/25-browser-shadow.png)

### Rollback

Build #3 deploys a version that doesn't exist. The rollout times out and is rolled back to v3.2.4 (the red Rollback Demo stage is in the Jenkins screenshot above):

![Rollback console output](docs/screenshots/26-rollback-console.png)

A request every second during the whole build, all answered 200:

![No downtime during the rollback](docs/screenshots/27-rollback-no-downtime.png)

Manual rollback of blue-green, canary, A/B and shadow:

![Manual rollbacks](docs/screenshots/28-manual-rollbacks.png)

Everything back after build #4:

![Status after restore](docs/screenshots/29-status-after-restore.png)

### Automatic build from a commit

Build #5, started by Jenkins after polling GitHub:

![Started by an SCM change](docs/screenshots/30-scm-triggered-build.png)

It picked up both merged pull requests:

![Changes in build 5](docs/screenshots/31-scm-changes.png)

### GitHub

![Commit history](docs/screenshots/32-github-commits.png)

![Merged pull requests](docs/screenshots/33-github-pull-requests.png)

![Tags v1.0 to v3.2.4](docs/screenshots/34-github-tags.png)

![Network graph](docs/screenshots/35-github-network.png)
