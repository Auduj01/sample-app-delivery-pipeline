# Production-grade CI/CD, end to end — mentoring walkthrough

**Worked example:** `sample-app-delivery-pipeline` (a Spring Boot / Maven "sample-app").
**Goal:** by the end, you can point this exact sequence at any application —
Node, Go, Python, whatever — and stand up the same pipeline.

This guide is organized as the architecture diagram you gave me, stage by
stage. Each stage says what problem it solves, shows the real config for it,
and ends with the command(s) that prove it worked. All the config files it
references are in the accompanying `production-cicd.zip` bundle, laid out
exactly as they'd sit in your two repos (app repo + GitOps repo).

A note before we start: I read your actual repo. It's a working Jenkins +
JFrog + Terraform/EC2 pipeline, which is a legitimate way to build this — but
it has three problems we'll fix along the way, because they're the most
common mistakes in real production pipelines: secrets committed straight
into `deployment.yaml`, an End-Of-Life base image (`openjdk:8`, unsupported
since 2022), and no image scanning or immutable tagging before the image
reaches a cluster. Fixing those *is* part of the lesson.

---

## Stage 0 — Make the application deployable

Before any pipeline exists, the app itself has to answer three questions a
production platform will ask it: *are you alive*, *are you ready for
traffic*, and *what are your metrics*. Your current `RepositoryDetailsController`
doesn't expose any of that, and `application.properties` only sets a port.

Add Spring Boot Actuator and the Prometheus registry to `pom.xml`:

```xml
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<dependency>
  <groupId>io.micrometer</groupId>
  <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

And expose the endpoints in `application.properties`:

```properties
server.port=8000
management.endpoints.web.exposure.include=health,info,prometheus
management.endpoint.health.probes.enabled=true
management.health.livenessState.enabled=true
management.health.readinessState.enabled=true
```

This single change is what makes every later stage possible: the
Dockerfile's `HEALTHCHECK`, Kubernetes' liveness/readiness probes, and
Prometheus scraping all point at `/actuator/*`. **This is stage zero for any
language** — Node needs `/healthz` via something like `terminus`, Go usually
hand-rolls `/livez`/`/readyz`, Python/FastAPI ships them out of the box. No
health endpoint means Kubernetes cannot safely restart or scale your app.

While you're in the source: delete the hardcoded GitHub password in
`getRepos()` and the Twitter keys baked into `deployment.yaml`. We're
replacing both with real secrets management in Stage 5 — don't carry them
forward.

---

## Stage 1 — Git repository

Two repos, not one, and this split is the backbone of everything after it:

- **App repo** (`sample-app-delivery-pipeline`) — source code, `Dockerfile`, the CI
  workflow, and the Helm chart *definition* (templates). CI runs here. It
  never has cluster credentials.
- **GitOps repo** (`sample-app-delivery-pipeline-gitops`) — only rendered config:
  `values-staging.yaml`, `values-prod.yaml`. ArgoCD watches here. It never
  runs a build.

Why split them: if CI had cluster credentials, any PR to the app repo could
theoretically deploy to prod. Separating "what gets built" from "what's
running" means a deploy is *only ever* a git commit to the GitOps repo, which
you can review, diff, and revert like any other change.

Branch protection on `main` in the app repo (Settings → Branches):

- Require the `test` and `build-scan-push` status checks to pass before merge.
- Require at least one review.
- No direct pushes, no force-push.

Branching model: trunk-based. Short-lived feature branches, PR into `main`,
`main` is always deployable. Cut a `vX.Y.Z` tag for a release build; everyday
merges to `main` deploy by commit SHA. You'll see both tagging schemes in the
CI workflow.

---

## Stage 2 — CI Pipeline (test → build → scan → tag → push)

File: `.github/workflows/ci-cd.yml`. This replaces the Jenkins pipeline with
GitHub Actions, since the repo already lives on GitHub — same five stages
your diagram asks for, in the same order, with one deliberate rule: **each
stage gates the next.** A test failure never reaches a build. A vulnerable
image never reaches the registry.

**Test.** `mvn -B clean verify` runs unit tests and the JaCoCo coverage
plugin already wired into your `pom.xml`. This is the job that runs on
*every* pull request, before merge — that's the whole point of CI: catch
regressions before they're mergeable, not after.

**Build.** `docker/build-push-action` builds the image from the Dockerfile
below with `push: false` first. We build before we scan, and scan before we
push — never push an unscanned image, even for one minute.

**Scan.** Trivy scans the built image for CVEs and the workflow sets
`exit-code: 1` on CRITICAL/HIGH — the job fails the pipeline if it finds
them, and results also land in the GitHub Security tab as SARIF so you get a
persistent audit trail, not just a console log that scrolls away.

**Tag.** `docker/metadata-action` derives tags: `sha-<git sha>` on every
`main` push (immutable, traceable to an exact commit), `X.Y.Z` on version
tags, and `latest` only as a convenience pointer — **never deploy `:latest`**,
because it isn't pinned to anything and you can't tell which code is
actually running. The GitOps repo will only ever reference the sha tag.

**Push.** Only after scan passes, the image is pushed to GHCR and signed
with `cosign` using GitHub's OIDC identity (keyless — no private key to leak
or rotate). Signing proves the image came from this exact pipeline run, which
matters once you add admission control (Kyverno/Gatekeeper) that refuses to
run unsigned images — a natural next step once this pipeline is solid.

**The Dockerfile it builds** (multi-stage — a Maven build stage that never
ships, and a slim JRE runtime stage):

```dockerfile
FROM maven:3.9.6-eclipse-temurin-17 AS build
WORKDIR /workspace
COPY pom.xml .
RUN mvn -B dependency:go-offline
COPY src ./src
RUN mvn -B clean package -DskipTests

FROM eclipse-temurin:17-jre-alpine AS runtime
RUN addgroup -S spring && adduser -S spring -G spring
USER spring:spring
WORKDIR /app
COPY --from=build --chown=spring:spring /workspace/target/*.jar app.jar
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD wget -q -O- http://127.0.0.1:8000/actuator/health || exit 1
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-jar", "app.jar"]
```

Compare this to the original: `FROM openjdk:8` (EOL, unpatched CVEs
accumulating since 2022), `ADD` of a jar that Jenkins built on the host
(non-reproducible — depends on whatever's on that Jenkins box), and running
as root by default. The multi-stage build is reproducible from a clean
checkout, runs unprivileged, and the *build tool version is pinned in the
Dockerfile itself*, not on some agent's local Maven install.

Prove it locally before you ever push to GitHub:

```bash
docker build -t sample-app:local .
docker run --rm -p 8000:8000 sample-app:local
curl localhost:8000/actuator/health
trivy image sample-app:local --severity CRITICAL,HIGH
```

---

## Stage 3 — Container Registry

We use GHCR (`ghcr.io`) because it's zero-setup with a GitHub repo — same
`GITHUB_TOKEN` that checks out your code can push the image, no extra
credential to manage. Docker Hub, ECR, ACR, or your original JFrog
Artifactory all work identically from here; only the login step in the
workflow changes.

Registry hygiene that matters in production:

- **Immutable tags.** Once `sha-<commit>` is pushed, nothing ever overwrites
  it. If you need to roll back, you deploy an *older* tag — you never mutate
  one.
- **Retention policy.** Untagged/orphaned images pile up fast; GHCR and ECR
  both support lifecycle rules — keep the last N tagged images, expire
  untagged ones after a few days.
- **Private by default**, pulled with an `imagePullSecret` — see
  `helm/sample-app/values.yaml`'s `imagePullSecrets`. Create it once per
  cluster:

```bash
kubectl create secret docker-registry ghcr-cred \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<a PAT with read:packages> \
  -n sample-app
```

---

## Stage 4 — CD Pipeline / GitOps

This is the stage most tutorials skip, and it's the one that actually makes
a pipeline "production grade." The naive approach — CI runs `kubectl apply`
or `helm upgrade` directly against the cluster — means your CI system holds
cluster-admin credentials, and the only record of "what's deployed right
now" is Jenkins' build log.

GitOps flips it: the **cluster pulls**, nothing pushes to it.

1. CI's last job (`update-gitops` in the workflow) checks out the separate
   GitOps repo and bumps `image.tag` in `values-prod.yaml` using `yq`, then
   commits and pushes. That's it — CI's job ends there.
2. **ArgoCD**, running inside the cluster, polls that repo (or gets a
   webhook) and notices the diff.
3. ArgoCD runs `helm template` with the new values and reconciles the
   cluster to match — creating/updating/deleting resources as needed.

`gitops/argocd/application.yaml` is the `Application` object that wires this
up, with `syncPolicy.automated.selfHeal: true` — meaning if anyone runs a
manual `kubectl edit` against the live Deployment, ArgoCD reverts it back to
what's in git within minutes. Git is the single source of truth; the API
server is not.

Bootstrap once per cluster:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f gitops/argocd/application.yaml
kubectl port-forward svc/argocd-server -n argocd 8080:443   # UI at localhost:8080
```

From here, every deploy — including your very first one — is a git commit,
never a command you run by hand against the cluster.

---

## Stage 5 — Helm

Helm is the templating layer between "one YAML per environment, hand-edited
and drifting" and "one parameterized chart, environment-specific values."
`helm/sample-app/` is a real chart built from your original four flat
manifests (`namespace.yaml`, `deployment.yaml`, `service.yaml`,
`secret.yaml`), split into:

- `Chart.yaml` — chart identity and version (bump this when templates change).
- `values.yaml` — sane defaults for a local/dev cluster.
- `values-prod.yaml` — only the *overrides* prod needs (replica count,
  resource sizing, hostnames, and the field CI actually touches: `image.tag`).
- `templates/` — `deployment.yaml`, `service.yaml`, `ingress.yaml`, `hpa.yaml`,
  `pdb.yaml`, `configmap.yaml`, `serviceaccount.yaml`, `servicemonitor.yaml`.

The pattern worth internalizing: **templates almost never change between
environments — values do.** If you catch yourself writing `{{ if
.Values.environment == "prod" }}` inside a template, that's usually a sign
the difference belongs in a values file instead.

Validate and render locally before ArgoCD ever sees it:

```bash
helm lint helm/sample-app
helm template sample-app helm/sample-app -f helm/sample-app/values-prod.yaml | less
helm install sample-app helm/sample-app -n sample-app --create-namespace \
  -f helm/sample-app/values-prod.yaml --dry-run
```

---

## Stage 6 — Kubernetes: Deployment → ReplicaSet → Pods

This is the chain your diagram names explicitly, and it's worth being
precise about who owns whom:

- You create/update a **Deployment**. You almost never touch a ReplicaSet or
  Pod directly.
- The Deployment controller creates a **ReplicaSet**, which is just "a
  desired pod template + a replica count." Its only job is making sure that
  many pods matching that template exist.
- The ReplicaSet creates the **Pods** — the actual running containers.
- When you change the pod template (a new image tag, say), the Deployment
  creates a *new* ReplicaSet and shifts pods from the old one to the new one
  according to the rollout strategy. The old ReplicaSet is kept, scaled to
  zero, as your rollback target.

`templates/deployment.yaml` sets `strategy.rollingUpdate.maxUnavailable: 0`
— never take capacity away during a deploy — and `maxSurge: 1` — add one
extra pod, wait for it to pass its readiness probe, *then* retire an old one.
That's what makes a deploy zero-downtime instead of a blip.

Watch it happen:

```bash
kubectl -n sample-app get deploy,rs,pods -o wide
kubectl -n sample-app rollout status deployment/sample-app
kubectl -n sample-app rollout history deployment/sample-app
kubectl -n sample-app rollout undo deployment/sample-app   # instant rollback to prior ReplicaSet
```

Two more objects are doing real work here that aren't in your diagram but
belong in "production grade": the **HorizontalPodAutoscaler**
(`templates/hpa.yaml`) scales replicas 3→10 on CPU, and the
**PodDisruptionBudget** (`templates/pdb.yaml`) tells the cluster "never take
more than 1 pod down at once for *voluntary* disruptions" — node drains,
cluster upgrades — so a routine maintenance operation can't accidentally take
your whole service offline.

---

## Stage 7 — Service

`templates/service.yaml` is a stable virtual IP + DNS name
(`sample-app.sample-app.svc.cluster.local`) in front of whichever pods
currently match `app.kubernetes.io/name: sample-app`. Pods come and go —
every deploy replaces them — but the Service's address never changes,
which is exactly what the Ingress in the next stage needs to route to
reliably.

It's `ClusterIP` (internal-only) rather than the original's `NodePort`,
because the Ingress controller is what should be internet-facing — routing
straight from a `NodePort` skips TLS termination, path-based routing, and
rate limiting that the Ingress layer gives you for free.

---

## Stage 8 — Ingress / Load Balancer

Two pieces, both installed once per cluster (not per app):

**ingress-nginx** — the controller that actually implements `Ingress`
objects. Install it once:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace
```

On a cloud provider this provisions a real cloud Load Balancer (ALB/NLB/GCLB)
pointed at the controller — that's the "Load Balancer" box in your diagram.
On kind/minikube it's a NodePort you port-forward to instead.

**cert-manager** — issues and auto-renews TLS certs. `observability/cluster-issuer.yaml`
defines a Let's Encrypt `ClusterIssuer`; the chart's `ingress.annotations`
reference it, so every `Ingress` this chart creates gets HTTPS for free.

```bash
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set installCRDs=true
kubectl apply -f observability/cluster-issuer.yaml
```

`templates/ingress.yaml` then does host/path routing to the Service from
Stage 7. This is the layer users actually hit — everything before it is
internal.

---

## Stage 9 — Observability (running alongside everything above)

These four run independently of the deploy pipeline — they watch whatever's
currently live, regardless of how it got there.

**Prometheus + Grafana + Alertmanager** ship together as one chart,
`kube-prometheus-stack`. Install once per cluster:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f observability/kube-prometheus-stack-values.yaml
```

Your app is discovered automatically: `templates/servicemonitor.yaml` in the
Helm chart tells the Prometheus Operator to scrape
`/actuator/prometheus` every 15s, and the `release: kube-prometheus-stack`
label is what makes the Operator notice it — that label match is the single
most common thing people get wrong when a ServiceMonitor "isn't working."
`observability/sample-app-alerts.yaml` adds four starter alert rules (target
down, elevated 5xx rate, crash-looping pods, memory near limit) that route
to Slack through Alertmanager. Grafana comes with a JVM/Spring Boot
dashboard pre-provisioned (`grafana.dashboards` in the values file) so you
see heap, GC pauses, and request latency without building a dashboard from
scratch.

**Fluent Bit** is the log path — a DaemonSet, one pod per node, tailing
every container's stdout/stderr from `/var/log/containers`, enriching each
line with pod/namespace metadata, and shipping it to a backend (Loki paired
with Grafana is the path of least resistance since you already have Grafana
open for metrics — same UI for logs and dashboards):

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm install loki grafana/loki-stack -n logging --create-namespace
helm repo add fluent https://fluent.github.io/helm-charts
helm install fluent-bit fluent/fluent-bit -n logging \
  -f observability/fluent-bit-values.yaml
```

The mental model to keep: **Prometheus answers "is it healthy and how
fast,"** pulled from metrics your app exposes; **Fluent Bit answers "what
exactly happened,"** pushed from whatever your app printed. You want both —
a metric tells you error rate spiked at 14:32, the log tells you it was a
downstream timeout to a specific dependency.

---

## Secrets — the one thing to never skip

Your original repo had two secret leaks worth calling out explicitly,
because they're the two most common ways real production incidents start:
a GitHub PAT for JFrog and the full Twitter OAuth quad, both committed in
plaintext (`Jenkinsfile` and `deployment.yaml`). Once something is committed,
rotating it is not optional — assume it's compromised the moment it's pushed,
even to a private repo.

The chart never takes a secret value as a Helm value — `values.yaml` only
holds `existingSecret: sample-app-secrets`, a *name*, and the Deployment
reads it via `envFrom.secretRef`. The Secret itself is created outside Helm
entirely. `gitops/external-secret-example.yaml` shows the production pattern
— External Secrets Operator pulling from AWS Secrets Manager (Vault, GCP
Secret Manager, Azure Key Vault all plug into the same `ExternalSecret`
shape) and materializing a native `Secret` that the Operator keeps in sync
and auto-rotates. For a first pass without adopting a new operator,
`kubectl create secret generic sample-app-secrets --from-literal=...`
imperatively, once, per cluster, is a legitimate stopgap — the one rule that
matters is that no secret value is ever a line in a file that gets `git add`ed.

---

## Replaying this end to end, from zero

1. Fork/clone the app repo; create a sibling `-gitops` repo with
   `apps/sample-app/{values.yaml,values-prod.yaml}`.
2. Add the Actuator dependency and health config (Stage 0); commit.
3. Add `Dockerfile`, `.dockerignore`, `.github/workflows/ci-cd.yml` (Stage 2)
   to the app repo. Add a `GITOPS_PAT` repo secret (a PAT scoped to the
   gitops repo) for the workflow's last job.
4. Push to a feature branch, open a PR — watch the `test` job run.
5. Merge to `main` — watch `build-scan-push` build, Trivy-scan, sign, and
   push to GHCR, then `update-gitops` commit the new tag to the gitops repo.
6. Stand up a cluster (kind/EKS/GKE/AKS — anything). Install ingress-nginx,
   cert-manager, kube-prometheus-stack, Loki, Fluent Bit, and ArgoCD
   (Stages 4, 8, 9).
7. `kubectl create secret docker-registry ghcr-cred ...` and either
   `kubectl create secret generic sample-app-secrets ...` or apply the
   `ExternalSecret` (Secrets section above).
8. Apply `gitops/argocd/application.yaml`. ArgoCD picks up the gitops repo
   and deploys — Deployment → ReplicaSet → Pods → Service → Ingress, live.
9. `kubectl -n sample-app get pods,svc,ingress` and hit the host from step 6's
   DNS. Open Grafana, confirm the JVM dashboard is populated. Trigger a 4xx
   and watch it show up in Loki.
10. Make a trivial code change, push to `main`, and watch the whole chain
    fire again without a single manual `kubectl apply` or `helm upgrade`.

---

## The reusable checklist for *any* application

Swap these five things and this entire playbook — CI workflow, Dockerfile
shape, Helm chart, GitOps flow, observability stack — carries over unchanged:

1. **The Dockerfile's build stage** — `maven` → whatever builds your
   language (`node:20`, `golang:1.22`, a `pip install` layer for Python).
   The runtime stage stays "smallest official base image, non-root user,
   `HEALTHCHECK` hitting a real endpoint."
2. **The test command** in the CI `test` job — `mvn verify` → `npm test`,
   `go test ./...`, `pytest`.
3. **The health/metrics endpoints** the app exposes — Actuator's paths are
   Spring-specific; every framework has an equivalent, and Stage 0's
   principle (liveness, readiness, a Prometheus-format metrics endpoint)
   holds regardless.
4. **Helm values** — `image.repository`, `service.port`, resource sizing,
   and the ingress hostname are the only things that actually differ
   app-to-app; the template shapes barely change.
5. **The registry/cluster names** in the workflow and `Application` manifest.

Everything else — scan-before-push, immutable sha tags, GitOps instead of
`kubectl apply` from CI, ServiceMonitor + PrometheusRule alongside the chart,
Fluent Bit as a cluster-wide DaemonSet rather than a per-app sidecar — is
infrastructure you build once and every future app rides on top of.
