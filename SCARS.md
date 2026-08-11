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

- **S — Symptom:** Under a 500-VU same-hospital admit surge, p95 reached 56.65s, failures reached 45.83%, and successful admits were only about 1.95/sec.
- **C — Cause:** InnoDB exclusive record-lock contention on the hot `hospitals.PRIMARY` row for `id=1`. The app held the row lock while waiting 500ms inside `notifyBedRegistry()`, so concurrency serialized behind one row and produced `ER_LOCK_WAIT_TIMEOUT`.
- **A — Action:** Replaced the long transaction with one atomic guarded update, `available_beds = available_beds - 1 WHERE id = ? AND available_beds > 0`, and moved the registry notify after the database statement commits.
- **R — Result:** p95 improved from 56.65s to 833.23ms, request throughput improved from 3.60 req/s to 779.05 req/s, and failures dropped from 45.83% to 0.00%.
- **Evidence:** `LAB_JOURNAL.md` OPS-2203 section, `evidence/ops-2203-before-k6.txt`, `evidence/ops-2203-locks-before.txt`, `evidence/ops-2203-innodb-status-before.txt`, `evidence/ops-2203-metrics-before.txt`, `evidence/ops-2203-after-k6.txt`, `evidence/ops-2203-innodb-status-after.txt`.
- **Scar / lesson:** More callers cannot beat a serialized critical section. If a transaction holds a hot-row lock for 500ms, that row can do only about 2 writes/sec before queues and lock timeouts dominate. Shrinking the lock window improved throughput, but moving the registry notify after commit introduces a dual-write consistency risk that should be handled with an outbox or idempotent request key.

## OPS-2204 — Export OOM

- **S — Symptom:** The nightly export caused repeated API restarts. During the before run, Docker showed API memory at 159.8MiB / 160MiB, and Docker events showed 14 `oom`, 14 `die exitCode=137`, and 14 `start` events.
- **C — Cause:** `/api/patients/export` used O(N) memory per request by loading every patient row with `SELECT *`, storing the full result set in Node, and serializing one huge JSON response. With concurrent exports, API memory exceeded the 160MB container limit.
- **A — Action:** Reworked `/api/patients/export` to stream the JSON response in 500-row batches using keyset pagination instead of materializing the full export at once.
- **R — Result:** After the fix, 150/150 k6 checks passed with 0.00% failures. API memory stayed around 71.5MiB / 160MiB during the sampled run, and the after-events window had 0 OOM/die/start events.
- **Evidence:** `LAB_JOURNAL.md` OPS-2204 section, `evidence/ops-2204-before-k6.txt`, `evidence/ops-2204-docker-stats-before.txt`, `evidence/ops-2204-docker-events-before.txt`, `evidence/ops-2204-logs-before.txt`, `evidence/ops-2204-after-k6.txt`, `evidence/ops-2204-docker-stats-after.txt`, `evidence/ops-2204-docker-events-after.txt`, `evidence/ops-2204-restart-count-after.txt`.
- **Scar / lesson:** Full-table exports are availability risks when they materialize the whole result in application memory. Streaming makes memory bounded, but it does not make the export cheap: the fixed endpoint still sends about 36.7MB per export and has p95 around 51.49s under 50 VUs.
