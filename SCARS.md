# SCARS

## OPS-2201 — Patient Search Timeout

- **S — Symptom:** Search for common last names missed the latency target under load. Before evidence: p95=10.58s and 19.83 req/s.
- **C — Cause:** The dominant mechanism was unbounded response size: the endpoint returned 10,000 full patient records, forcing Node to materialize, JSON-serialize, and send multi-MB responses. The missing `last_name` index was real, but the index-only isolation test showed it was not the main bottleneck.
- **A — Action:** Added `idx_patients_last_name` and changed `/api/patients/search` to return 50 summary rows plus `hasMore`.
- **R — Result:** p95 improved from 10.58s to 173.26ms, and throughput improved from 19.83 req/s to 1798.85 req/s.
- **Evidence:** `LAB_JOURNAL.md` OPS-2201 section, `evidence/ops-2201-before-k6.txt`, `evidence/ops-2201-index-only-k6.txt`, `evidence/ops-2201-after-k6.txt`, `evidence/ops-2201-explain-analyze-after.txt`, `evidence/ops-2201-grafana-before.png`, `evidence/ops-2201-grafana-after.png`.
- **Scar / lesson:** Prove the mechanism before celebrating the obvious fix. Here, indexing alone did not help because payload size dominated.

## OPS-2202 — Registration Surge Freezes App

- **S — Symptom:** During the 2000-VU surge, `/api/patients/recent` reached only 1537.71 req/s with p95=1.8s while MySQL looked idle.
- **C — Cause:** The suspected pool bottleneck was mostly disproved. Raising MySQL connections from 2 to 20 changed throughput by only 2.8% and p95 by 8.9%. The dominant mechanism was API-side response handling: Node CPU, JSON serialization, socket output, and connection-level failures under 2000 concurrent clients.
- **A — Action:** Increased the MySQL pool from 2 to 20 connections, kept the wait queue unbounded, and reduced `/api/patients/recent` from `SELECT *` to summary columns.
- **R — Result:** Final rerun improved p95 from 1.8s to 1.17s and throughput from 1537.71 req/s to 1896.60 req/s. Data received dropped from 875MB to 460MB. The endpoint improved but did not fully meet a 300ms p95 target.
- **Evidence:** `LAB_JOURNAL.md` OPS-2202 section, `evidence/ops-2202-before-k6-clean.txt`, `evidence/ops-2202-after-k6.txt`, `evidence/ops-2202-after-k6-payload-rerun.txt`, `evidence/ops-2202-mysql-midrun-after-payload.txt`, `evidence/ops-2202-docker-stats-after-payload.txt`, `evidence/ops-2202-failure-check-after.txt`, `evidence/ops-2202-grafana-after.png`.
- **Scar / lesson:** Do not confuse "the pool config changed" with "the pool was the cause." DB idle plus app slow can mean the Node process is the limiter. Here, non-200 k6 checks did not appear as DB errors or Express 500s, so the remaining failures happened above MySQL and outside completed application responses.

## OPS-2203 — Bed Admission Contention

- **S — Symptom:** Pending investigation.
- **C — Cause:** Pending investigation.
- **A — Action:** Pending investigation.
- **R — Result:** Pending investigation.
- **Scar / lesson:** Pending investigation.

## OPS-2204 — Export OOM

- **S — Symptom:** Pending investigation.
- **C — Cause:** Pending investigation.
- **A — Action:** Pending investigation.
- **R — Result:** Pending investigation.
- **Scar / lesson:** Pending investigation.
