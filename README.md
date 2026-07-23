# OpenShift Multi-Site Ledger Demo

A small active/standby web application across two OpenShift clusters.

- **Site A web:** ACTIVE
- **Site B web:** STANDBY
- **PostgreSQL primary:** Site A
- **PostgreSQL replica:** Site B over Red Hat Service Interconnect
- **Secrets:** existing Vault and `ClusterSecretStore/demo-vault`
- **Deployment:** existing OpenShift GitOps / Argo CD

This repository does **not** install CloudNativePG, Service Interconnect, Network Observer, External Secrets, Vault, or OpenShift GitOps.

## 1. Push this folder to a new GitHub repository

```bash
git init
git add .
git commit -m "Initial multi-site ledger demo"
git branch -M main
git remote add origin https://github.com/YOUR-USER/openshift-multisite-ledger-demo.git
git push -u origin main
```

## 2. Copy the two managed-cluster kubeconfigs

```bash
mkdir -p .work/kubeconfigs
cp /path/to/cluster-pwv6d.kubeconfig .work/kubeconfigs/
cp /path/to/cluster-7b6lh.kubeconfig .work/kubeconfigs/
```

Your current `oc` context must point to the RHACM hub where OpenShift GitOps is running. The managed clusters also need outbound access to the Red Hat UBI registry and PyPI for the small demo web container.

## 3. Deploy

```bash
./bootstrap.sh \
  --repo-url https://github.com/YOUR-USER/openshift-multisite-ledger-demo.git
```

The script prints the Site A and Site B web URLs.

## 4. Switch the frontend to Site B

```bash
./scripts/switch-frontend.sh site-b
```

Switch it back to Site A:

```bash
./scripts/switch-frontend.sh site-a
```

The switch changes only the web frontend role. PostgreSQL remains primary on Site A, so an active Site B frontend writes to Site A through Service Interconnect.

## 5. Test

```bash
./verify.sh
```

## 6. Remove only this demo

```bash
./cleanup.sh
```

The cleanup does not uninstall any operators or remove the existing Vault deployment.
