# Multi-cluster and gateway (planning notes)

Internal planning context for stakeholder asks and product direction. This repo remains focused on **build and deploy** of the ODH operator; this file tracks **what we owe** on architecture and UX around MaaS-style deployments.

## Drivers

- **Multi-cluster:** Multiple requests for a concrete plan, including from **Bryon Baker** and **Robert**.
- **Gateway and KServe:** Ongoing customer friction (see below).

---

## Multi-cluster

### Working theory with the current setup

A **minimal mental model** that should be compatible with how we run today:

- Run **two (or more) instances of MaaS** (one per cluster or per failure domain, as appropriate).
- **Replicate the database that stores keys** (and any other shared authoritative state) so that clusters participating in the model stay consistent for identity and policy.

This pattern is attractive because it **does not assume a greenfield redesign** of the existing stack.

### What we still owe

That approach is largely **bespoke** (operational replication, split-brain edge cases, upgrade ordering, etc.). We should **evaluate a more supported solution** in parallel:

- Align with **vendor-documented** multi-cluster or multi-site patterns where they exist.
- Prefer **reference architectures** or **first-class product guidance** over ad hoc replication-only designs.
- Make explicit **trade-offs** (complexity, RPO/RTO, blast radius) when comparing “two MaaS + replicated DB” to alternatives.

Deliverable: a short **decision record** or architecture note that names the **recommended** path and what we **do not** recommend for production without extra controls.

---

## Gateway creation and KServe integration

### Customer-facing Gateway

We **require customers to create the Gateway** themselves. We have received **multiple complaints** that setup is **too difficult**.

**Direction:**

- **Documentation:** Clear prerequisites, order of operations, and validation steps (what “good” looks like).
- **Automation (where safe):** Scripts, defaults, or operator-assisted paths that reduce copy-paste and misconfiguration—without hiding security or tenancy decisions that must stay explicit.

### Coherence with KServe

Today we rely on **custom annotations** so that our components **interoperate correctly with KServe**. That works but feels like **glue** rather than a **single product**.

**Direction:**

- Pursue **tighter integration** (APIs, defaults, or shared configuration contracts) so that MaaS + KServe reads as **one coherent platform story**, not two products that customers must wire with tribal knowledge.

---

## Relationship to this repository

Changes to **build pipelines** ([`scripts/build-and-push-odh-operator.sh`](../scripts/build-and-push-odh-operator.sh), [`.github/workflows/build-odh-operator-catalog.yml`](../.github/workflows/build-odh-operator-catalog.yml)) stay separate from the **runtime multi-cluster and Gateway** work above; link implementation tickets here when they exist.
