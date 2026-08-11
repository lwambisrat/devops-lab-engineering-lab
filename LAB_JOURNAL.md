# 🧾 On-Call Lab Journal — Regional Health

**Engineer:** Lwambisrat  **Date:** 2026-08-11

This is your investigation notebook. You are on call for the Regional Health
platform and working the [incident queue](./incidents/README.md). For each
incident you will:

1. **Hypothesis** — from the ticket symptoms alone, predict the cause *before*
   you run anything.
2. **Observation** — record real evidence: k6 output, Grafana/Prometheus
   metrics, `EXPLAIN ANALYZE` plans, lock views, `docker stats`, container logs.
3. **Root cause & mechanism** — explain *why* it happens. Name the database/OS
   mechanic yourself and show the capacity math.
4. **Fix & verify** — make the change, re-run the reproduction, and record the
   before/after.

> There is no answer key. A claim without evidence isn't a diagnosis. "It felt
> slow" is not an observation; `p(95)=1840ms, http_req_failed=32%` is.

---

## How to capture evidence

- **k6:** copy the summary block (`http_req_duration`, `http_req_failed`,
  `iterations`, `vus`).
- **MySQL:** `docker compose exec mysql-db mysql -uroot -plabpassword capacity_lab`
  then run `EXPLAIN ANALYZE ...`, `SHOW CREATE TABLE ...`,
  `SHOW ENGINE INNODB STATUS\G`, or query `performance_schema` / `sys`.
- **Metrics:** Grafana panels or raw Prometheus at http://localhost:9090.
- **Memory / restarts:** `docker stats`, `docker compose logs -f capacity-api`.

Useful Prometheus queries:
```promql
# Throughput (req/s) by route
sum(rate(http_requests_total[1m])) by (route)

# p95 latency by route
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[1m])) by (le, route))

# Application heap in use
nodejs_heap_size_used_bytes

# DB errors by code
sum(rate(db_errors_total[1m])) by (code)
```

---

## Baseline — steady state (do this first)
*Run:* `k6 run load-tests/00-baseline.js` (healthy system, no incident)

Capture the control group you'll compare every incident against.

| Metric              | Value |
|---------------------|-------|
| Requests/sec (RPS)  | 49.42/s |
| p50 latency         | 9.23ms |
| p95 latency         | 19.27ms |
| p99 latency         | 74.03ms |
| Error rate          | 0.00% |
| Peak API heap used  | 24,134,496 bytes (~23.0 MiB) |

> Baseline provenance: this control run was captured after the OPS-2201 search
> fix had landed, but it exercises `/api/patients/recent`, which the OPS-2201
> code path does not change. No incident load test overlapped the Prometheus
> heap query window; the low 23.0 MiB heap reading is treated as steady state.
>
> Baseline result: p95=19.27ms, p99=74.03ms, 0.00% failures, and
> 49.42 requests/sec. I used this as the control group for incident comparisons,
> alongside each incident's ticket threshold.

---

## Investigation — OPS-2201
*Ticket:* [Patient name search unusably slow at shift change](./incidents/OPS-2201.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2201.js`

### Hypothesis
> From the symptoms alone (fast when isolated, collapses under concurrent
> searches, other endpoints unaffected), I think the cause is
> a missing index on `patients.last_name`
> because the search query likely performs a full table scan over about 100,000 patient rows for each request. Under concurrent shift-change traffic, many repeated scans increase database work and push latency above the expected SLO.

### Observation (evidence)
> Investigate how the database executes the search. Paste what you find:
> ```
> k6 before fix (evidence/ops-2201-before-k6.txt):
> http_req_duration avg=8.88s med=9.7s p90=10.45s p95=10.58s max=11.22s
> http_req_failed=0.00% (0/780)
> http_reqs=780, 19.83/s
>
> EXPLAIN before fix (evidence/ops-2201-explain-before.txt):
> type=ALL, possible_keys=NULL, key=NULL, rows=98191, filtered=10.00, Extra=Using where
>
> Row counts (evidence/ops-2201-row-counts-before.txt):
> Smith rows=10000, total patients=100000
>
> Index-only isolation test (evidence/ops-2201-index-only-k6.txt):
> After adding `idx_patients_last_name` but keeping `SELECT *` and returning all
> 10,000 Smith rows, p95 was 16.59s and RPS was 19.64/s. The index alone did
> not meet the 300ms SLO because response payload size was still unbounded. This
> disproved my first "missing index is the main fix" hypothesis.
>
> Final after fix (evidence/ops-2201-after-k6.txt):
> http_req_duration avg=110.93ms med=100.94ms p90=138.19ms p95=173.26ms max=464.38ms
> http_req_failed=0.00% (0/54098)
> http_reqs=54098, 1798.85/s
>
> Final EXPLAIN ANALYZE (evidence/ops-2201-explain-analyze-after.txt):
> Index lookup on `idx_patients_last_name`, actual time=1.19..1.2ms, rows=51.
> ```
| Metric (under load) | Value | vs. baseline |
|---------------------|-------|--------------|
| p95 latency         | 10.58s | 19.27ms -> 10.58s (~549x slower) |
| RPS                 | 19.83/s | baseline was a 50-VU steady-state control, not a capacity ceiling; with 4x the VUs, this incident still produced less than half the baseline RPS |
| Error rate          | 0.00% | same as baseline |
| Rows examined / req | 98,191 estimated by EXPLAIN | baseline not applicable |

### Root cause & mechanism
> What is the database doing per request, and why does cost blow up with data
> size and concurrency? Name the mechanism and the data structure involved.
> Estimate the cost difference between the current behaviour and the ideal one
> for ~100,000 rows. Before the fix, MySQL used a full table scan (`type=ALL`,
> `key=NULL`) on the unindexed `last_name` predicate, examining about 98,191
> rows per request to find 10,000 `Smith` patients. However, the isolation test
> showed the full scan was not the dominant cost for this dataset: 100,000 rows
> fit in memory, and adding the index while still returning every matching row
> left throughput effectively unchanged. Under 200 concurrent VUs, the expensive
> part was materializing 10,000 patient rows in Node, JSON-serializing a multi-MB
> response, and pushing that response through the socket. The shared 2-connection
> MySQL pool amplified that long service time into queue time.
> The pool-width evidence is also visible from the k6 arithmetic: before the
> fix, 2 connections / 19.83 req/s = about 101ms of service time per request,
> and Little's Law gives L = 19.83 req/s * 8.88s = 176 in-flight requests, close
> to the 200 VUs in the test. The mechanism is a missing B-tree index plus
> unbounded result size, amplified by a still-existing 2-connection funnel. An
> ideal lookup should return only the page of results the UI needs. The cost
> changes from serializing 10,000 full records per request to returning 50
> summary records.
>
> The index-only isolation run is the key finding: it still failed with
> p95=16.59s and 19.64 req/s because it still returned 10,000 full patient
> records. Compared with the original broken run, throughput was flat
> (19.83/s -> 19.64/s), p95 got worse (10.58s -> 16.59s), and data received was
> unchanged at 2.8GB. The payload evidence is `2.8GB / 782 responses = about
> 3.58MB/response` for index-only versus `426MB / 54098 responses = about
> 7.9KB/response` for the final bounded response. The result-size reduction,
> not the index by itself, moved the endpoint under SLO.
>
> I did not raise `connectionLimit` for OPS-2201. With the unfixed endpoint,
> each in-flight search holds roughly the result rows, JSON string, and socket
> buffer for a multi-MB response. Raising the pool globally before bounding the
> payload could multiply memory pressure and turn a slow search incident into an
> OOM/restart incident. The pool is the structural ceiling for OPS-2202.

### Fix & verify
> Fix applied: I added `idx_patients_last_name` in `data-seed/seed.sh`, applied
> the same index to the running database, and changed `/api/patients/search` to
> return a bounded lookup page: selected patient summary columns ordered by `id`
> with `LIMIT 51` internally, returning 50 rows plus `hasMore`.
> Verification: `EXPLAIN` uses `idx_patients_last_name` (`type=ref`,
> `key=idx_patients_last_name`), and `EXPLAIN ANALYZE` for the actual shipped
> query returns 51 rows in about 1.2ms. The API returns 50 rows plus `hasMore`
> instead of returning every one of the 10,000 matching patients.
> After fix: p95=173.26ms, RPS=1798.85/s. Improvement was 61.1x lower p95
> latency and 90.7x higher RPS.
> Trade-off: writes to `patients.last_name` now also maintain a secondary B-tree
> index, and callers that need all matches must page through results instead of
> receiving every matching patient in one response.
> Fixed relative to the OPS-2201 SLO; the 2-connection pool remains the
> structural ceiling and is deferred to OPS-2202. Final DB work is about 1.2ms,
> while average end-to-end latency is 110.93ms, so most remaining time is still
> queueing/app/HTTP overhead.

---

## Investigation — OPS-2202
*Ticket:* [Whole app freezes during surges, DB looks idle](./incidents/OPS-2202.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2202.js`

### Hypothesis
> Given the query is trivial and the DB is idle yet requests pile up, I think
> the bottleneck is the application-side MySQL connection pool
> because `connectionLimit` is set to 2, so most requests wait in the API for a free connection before their cheap query can even reach MySQL.

### Observation (evidence)
> Before changing the pool, the surge test reached 1537.71 req/s with
> p95=1.8s and 0.00% request failures. MySQL showed `Threads_connected=3` and
> `Threads_running=2`, which matches the configured two application pool
> connections plus the inspection connection. The database was not reporting
> errors, but requests were spending most of their time waiting above the
> database layer.
>
> The first fix attempt raised the pool to 20 connections. That proved the pool
> configuration changed (`Threads_connected=21` after the change), but it did
> not prove the pool was the dominant bottleneck. Pool-only changed throughput
> by only 2.8% (1537.71/s -> 1581.49/s) and p95 by 8.9% (1.8s -> 1.64s), which
> is small compared with the 32% p95 variance seen between baseline runs. The
> useful discovery was that the original pool hypothesis was mostly wrong.
>
> The final OPS-2202 run used a wider pool and a smaller `/api/patients/recent`
> payload. That run reached 1896.60 req/s with p95=1.17s and 0.57% failures.
> Grafana showed `/api/patients/recent` throughput around 1.0K-1.1K req/s,
> p95 mostly around 1.0s-1.8s with a spike near 2.3s, no DB error series, and
> API memory below the 160MB limit. Grafana's throughput panel uses
> `rate(...[1m])`, so the 30-second k6 run is averaged with idle time on both
> sides of the selected window; that is why Grafana's visual rate is lower than
> k6's 1896.60 req/s summary. Docker stats during the final run showed
> `capacity-api` at 123.33% CPU while MySQL was at 23.00% CPU. The earlier
> `ops-2202-docker-stats-before-clean.txt` capture was taken off-load and is
> kept only as a container-state artifact, not as before-run CPU evidence.
>
> Failure check after the final run: `db_errors_total` existed in metrics, but
> there was no non-zero DB error series, and `docker compose logs --tail=100
> capacity-api` only showed the startup line. `http_requests_total` for
> `/api/patients/recent` had only `status_code="200"`, so Express did not finish
> any 500 responses. Since this middleware records on `res.on('finish')`, the
> failed k6 requests were connection-level failures: either not accepted by the
> app or aborted before Express finished the response. They were not MySQL
> errors and not application 500 responses.

| Metric                    | Baseline | Before | Pool only | Pool + smaller payload |
|---------------------------|----------|--------|-----------|-------------------------|
| Successful RPS            | 49.42/s | 1537.71/s | 1581.49/s | 1896.60/s |
| p95 latency               | 19.27ms | 1.8s | 1.64s | 1.17s |
| p95 vs. baseline          | 1x | 93.4x worse | 85.1x worse | 60.7x worse |
| Error / timeout rate      | 0.00% | 0.00% | 0.89% | 0.57% |
| Data received             | 28MB | 875MB | 894MB | 460MB |
| MySQL threads connected   | n/a | 3 | 21 | 21 |
| MySQL threads running     | n/a | 2 | 3 | 3 |

### Root cause & mechanism
> The original "DB looks idle while the app freezes" report was correct, but my
> first hypothesis about the dominant mechanism was mostly wrong. The
> two-connection MySQL pool looked suspicious, but increasing it to 20 barely
> improved throughput or p95. The dominant mechanism was API-side response
> handling: the single Node process had to build JSON responses and push them
> through sockets for 2000 concurrent clients.
>
> The math disproves the pool as the main constraint. In the before run, Little's
> Law gives `L = lambda * W = 1537.71 req/s * 1.17s avg latency = about 1799`
> in-flight requests, close to the 2000 VUs in the test. If two connections were
> serving 1537.71 req/s, the implied DB service time was
> `2 / 1537.71 = 1.3ms/query`. The required pool width for 2000 req/s at that
> service time is `2000 req/s * 0.0013s = 2.6 connections`, so two connections
> were already close to sufficient for DB work. A pool of 20 cannot help much
> once the bottleneck is outside MySQL.
>
> The strongest proof is the after-run resource split: MySQL had 21 connected
> threads but only 3 running threads and 23.00% CPU, while `capacity-api` used
> 123.33% CPU. Reducing the response payload cut network volume from 894MB to
> 460MB and improved p95 from 1.64s to 1.17s. That points to Node CPU,
> serialization, and socket output, not MySQL saturation. The non-200 k6 checks
> did not appear as Express 500s, so the remaining failure mode is at the
> connection layer above the app handler. The endpoint still missed a 300ms p95
> target under 2000 VUs.

### Fix & verify
> Fix applied for this incident: the MySQL pool was increased from 2 to 20
> connections with an unbounded wait queue, and `/api/patients/recent` was
> changed from `SELECT *` to the same bounded summary columns used by the search
> endpoint: `id`, `first_name`, `last_name`, `email`, `diagnosis`, and
> `created_at`.
>
> Verification: the rerun reached 1896.60 req/s, p95=1.17s, and 0.57% failures.
> That is better than the before run (1537.71 req/s, p95=1.8s), and the payload
> size dropped from 875MB to 460MB. The fix is a partial improvement, not a full
> SLO pass. The strongest conclusion is that the database pool was not the
> dominant constraint; after widening it, API response work remained the limit.
>
> Upstream protection: this endpoint needs admission control or rate limiting
> before the API accepts more concurrent work than it can finish inside the
> latency target. A production version should return a controlled overload
> response instead of allowing thousands of requests to build up inside the
> Node process.
>
> Baseline caveat for later incidents: OPS-2202 changed the `/api/patients/recent`
> response from `SELECT *` to summary columns, so the original baseline was
> measured against a larger payload than the current code returns. That change is
> negligible at the baseline's 49.42 req/s, but OPS-2203 and OPS-2204 comparisons
> should note that the control group was captured before the OPS-2202 payload
> reduction.
>
> Prediction for OPS-2204: raising `connectionLimit` to 20 can make the export
> incident worse because `/api/patients/export` still performs an unbounded
> `SELECT *` and returns every patient row. More concurrent export queries will
> multiply heap pressure against the 160MB API container limit.

---

## Investigation — OPS-2203
*Ticket:* [Bed admissions fail with DB errors under load](./incidents/OPS-2203.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2203.js`

### Hypothesis
> Given one-at-a-time works but concurrent admits to the *same* hospital fail,
> I think the cause is InnoDB row-lock contention on one hot `hospitals` row
> and the failure will show up as lock waits, timeouts, database errors, or a collapse in throughput. The app updates the hospital row and then waits about 500ms for `notifyBedRegistry()` before committing, so the row lock is held during external I/O.

### Observation (evidence)
> While the reproduction runs, inspect concurrent writers to one row:
> ```sql
> SELECT * FROM performance_schema.data_locks\G
> SELECT * FROM sys.innodb_lock_waits\G
> SHOW ENGINE INNODB STATUS\G   -- TRANSACTIONS section
> ```
> Paste the most telling waiter/blocker rows and the failure signature you saw
> (a DB error + code, a timeout, or stalled/near-zero throughput):
> ```
>
> ```
| Metric                     | Value | vs. baseline |
|----------------------------|-------|--------------|
| p95 / p99 latency          |       |              |
| Max successful admits/sec  |       |              |
| DB error(s) + code         |       |              |
| Error rate                 |       |              |

### Root cause & mechanism
> Explain why concurrency cannot beat serialization on a single hot row. If the
> critical section is held for W seconds per admit, what is the theoretical max
> throughput for that one row, regardless of how many callers pile on?
> 1 / W = ______ admits/sec. Where does the time in the critical section go, and
> which of the transactional guarantees is enforcing the wait? ________________

### Fix & verify
> The change you made (consider: shrinking the critical section, moving slow
> work out of the transaction, atomic guarded updates, reducing contention on
> the hot row): _____________________________________________________________
> Re-measured throughput / error rate: ______________________________________

---

## Investigation — OPS-2204
*Ticket:* [Nightly export crashes the service repeatedly](./incidents/OPS-2204.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2204.js`

### Hypothesis
> Given memory spikes right before each restart and only the big export is
> affected, I think the cause is unbounded result materialization in `/api/patients/export`
> because the endpoint loads every patient row into Node memory with `SELECT * FROM patients` and then serializes one huge JSON response. With 50 concurrent export callers, memory can exceed the 160MB container limit and trigger OOM restarts.

### Observation (evidence)
> Watch `nodejs_heap_size_used_bytes`, GC pauses, and restarts:
> ```bash
> docker stats
> docker compose logs -f capacity-api
> ```
| Metric                          | Value |
|---------------------------------|-------|
| Approx. payload size per request|       |
| Peak heap before crash          |       |
| Time-to-first-crash             |       |
| Container restart count         |       |
| GC pause trend                  |       |

> Paste the crash / exit log lines:
> ```
>
> ```

### Root cause & mechanism
> Estimate per-row size, then the full payload: rows × bytes/row = ______ MB.
> With C concurrent callers, peak resident memory ≈ ______ MB — compare to the
> container's memory budget (160MB locally / 256MB in prod). Explain what happens
> to GC frequency, CPU, and
> throughput as live heap approaches the limit, and why the current approach
> uses O(N) memory while a better one could use far less. ____________________

### Fix & verify
> The change you made (consider: bounding how much of the result set is in
> memory at once, streaming to the response, sensible page sizes, compression):
> ____________________________________________________________________________
> Re-run evidence — new peak heap: ______  restarts: ______  error rate: ______

---

## Post-incident review (synthesis)

> Rank the four incidents by **blast radius** (threat to overall availability at
> scale), justified with your measured numbers:
> 1. ____________________________________________________________________
> 2. ____________________________________________________________________
> 3. ____________________________________________________________________
> 4. ____________________________________________________________________
>
> If you could ship only **one** fix before a launch, which and why?
> ____________________________________________________________________________
>
> For each incident, what alert or dashboard would have caught it in production
> *before* a user filed a ticket? ____________________________________________
