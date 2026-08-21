# GitOps config repo layout

This `Application` points at a **separate** repo (`RealTime-Project-06-gitops`),
not the application source repo. Keeping them separate is deliberate:

- The **app repo** (this one) owns code + Dockerfile + CI + the Helm chart
  *template*. Its CI never touches the cluster.
- The **gitops repo** owns only rendered config: `values-{env}.yaml` per
  environment. CI's last job (`update-gitops` in ci-cd.yml) is the ONLY thing
  that writes to it, by bumping `image.tag`.
- ArgoCD watches the gitops repo and is the ONLY thing with write access to
  the cluster.

Expected layout of the gitops repo:

```
RealTime-Project-06-gitops/
└── apps/
    └── sample-app/
        ├── Chart.yaml            # or a `dependency` on the app repo's chart via a Helm repo
        ├── values.yaml
        ├── values-staging.yaml
        └── values-prod.yaml
```

Simplest bootstrap (imperative, one-time):

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl apply -f gitops/argocd/application.yaml
argocd app sync sample-app-prod   # or just wait for automated sync
```

Promotion between environments = opening a PR in the gitops repo that copies
the image tag from `values-staging.yaml` into `values-prod.yaml`. That PR
*is* your deployment approval record.
