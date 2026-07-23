# Architecture notes

The web tier is active/standby. Both routes remain available, but only the frontend whose pod-template label is `demo.redhat.com/frontend-role=active` accepts writes.

The database tier remains single-primary:

```text
Site A ledger-web ─┐
                   ├─ Service Interconnect ─ Site A ledger-db primary
Site B ledger-web ─┘

Site A ledger-db primary ─ PostgreSQL WAL over Service Interconnect ─ Site B ledger-db-replica
```

The Site B local database is read-only. Switching the web frontend to Site B does not promote PostgreSQL. The active Site B web application writes through Service Interconnect to the Site A primary and reads replicated records from its local Site B replica.

Sensitive values are written to the existing Vault instances by `bootstrap.sh`. External Secrets creates the Kubernetes Secrets consumed by CloudNativePG and the web frontend. No passwords or private keys are committed to Git.
