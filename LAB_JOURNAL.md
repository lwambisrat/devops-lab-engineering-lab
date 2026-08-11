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
> The before run reproduced the reporter's failure mode. With 500 VUs all
> admitting to hospital `id=1`, k6 completed only 216 requests in 60s, with
> 117 successful responses and 99 failed checks. p95 was 56.65s, the failure
> rate was 45.83%, and successful admission throughput was about
> `117 / 60s = 1.95 admits/sec`.
>
> MySQL showed the database-side mechanism directly. During the run,
> `Threads_connected=21` and `Threads_running=21`, and the processlist showed
> almost every app connection running the same statement:
> `UPDATE hospitals SET available_beds = available_beds - 1 WHERE id = 1`.
> `performance_schema.data_locks` showed one granted `X` record lock on
> `hospitals.PRIMARY` with `LOCK_DATA: 1` and many `WAITING` record locks for
> the same key. `performance_schema.data_lock_waits` listed waiter/blocker
> transaction pairs on that same record. `SHOW ENGINE INNODB STATUS` showed
> repeated `LOCK WAIT` entries for the same update, with transactions waiting
> up to 5 seconds for an exclusive record lock.
>
> The API metric after the failed run named the database error:
> `ER_LOCK_WAIT_TIMEOUT`. The counter value was cumulative across repeated
> investigation attempts, so I use it to identify the error code rather than as
> the exact per-run failure count. The k6 run's per-run failure count was
> 99 failed checks out of 216 requests.

| Metric                     | Baseline | Before | After |
|----------------------------|----------|--------|-------|
| p95 latency                | 19.27ms | 56.65s | 833.23ms |
| p95 vs. baseline           | 1x | 2939x worse | 43.2x worse |
| k6 request rate            | 49.42/s | 3.60/s | 779.05/s |
| Successful admits/sec      | n/a | 1.95/s | 779.05/s |
| DB error + code            | none | `ER_LOCK_WAIT_TIMEOUT` | none observed |
| Error rate                 | 0.00% | 45.83% | 0.00% |

### Root cause & mechanism
> The root cause is InnoDB exclusive record-lock contention on one hot
> `hospitals` row. The endpoint starts a transaction, updates the row, waits
> 500ms inside `notifyBedRegistry()`, and only then commits. The `UPDATE`
> obtains an exclusive lock on `hospitals.PRIMARY` for `id=1`, and InnoDB keeps
> that lock until transaction commit. Every concurrent admit to the same
> hospital must wait behind that one row lock.
>
> The capacity math matches the measurement. The critical section includes the
> simulated 500ms external registry call, so the theoretical maximum for one
> hospital row is `1 / 0.5s = 2 admits/sec`, no matter how many callers pile on.
> The before run measured about `117 successes / 60s = 1.95 successful
> admits/sec`, which is almost exactly that serialized limit. More concurrency
> only makes the lock queue longer until requests hit `ER_LOCK_WAIT_TIMEOUT`.
> The transactional guarantee enforcing the wait is InnoDB row-level locking
> for write isolation.
>
> The CPU evidence supports "waiting" rather than saturation: during the broken
> run, Docker stats showed `capacity-api` at 2.41% CPU and MySQL at 3.94% CPU
> while all 20 app MySQL connections were either holding or waiting on the same
> update. The system looked idle because threads were blocked on a row lock, not
> because there was no work queued.

### Fix & verify
> Fix applied: I removed the explicit transaction and changed the bed decrement
> into one atomic guarded update:
> `UPDATE hospitals SET available_beds = available_beds - 1 WHERE id = ? AND
> available_beds > 0`. If no row is affected, the API returns
> `409 NO_BEDS_AVAILABLE`. Otherwise the statement commits immediately and the
> simulated registry notify runs afterward, outside the database lock.
>
> Verification: the after run passed both k6 thresholds. p95 fell from 56.65s to
> 833.23ms, failures dropped from 45.83% to 0.00%, and throughput increased from
> 3.60 req/s to 779.05 req/s. `SHOW ENGINE INNODB STATUS` after the run showed
> no active lock waits. A mid-run after sample still showed momentary waiters on
> `hospitals.PRIMARY`, which is expected because all requests still update the
> same row, but the waits no longer include the 500ms external call and did not
> produce lock wait timeouts.
>
> The post-fix throughput is no longer the hot-row lock ceiling. The minimum
> response time was 504.55ms, which is the simulated `notifyBedRegistry()`
> latency floor. With 500 VUs and average latency of 635.05ms, Little's Law
> predicts `500 / 0.63505s = 787 req/s`, close to the measured 779.05 req/s.
> That means the fixed endpoint is bounded mostly by keeping the 500ms notify in
> the request path, not by the row lock.
>
> Trade-off: moving the registry notify after the database update improves
> throughput by shrinking the row-lock critical section, but it weakens
> cross-system consistency. If `notifyBedRegistry()` fails or the process dies
> after the local decrement commits, the hospital bed count changes locally but
> the registry may not hear about it. If the API returned 500 after such a
> committed decrement, a client retry could double-decrement a bed. A production
> version should use a transactional outbox or an idempotent admit request ID so
> the registry update can be retried safely.
>
> The `available_beds > 0` guard prevents over-admission and returns
> `409 NO_BEDS_AVAILABLE` when no row is affected. This path was not exercised
> in the load test because the seeded hospital had hundreds of thousands of beds
> remaining, so it is a correctness guard included with the fix rather than a
> measured part of the performance result.

---

## Investigation — OPS-2204
*Ticket:* [Nightly export crashes the service repeatedly](./incidents/OPS-2204.md)
*Reproduce:* `k6 run load-tests/reproduce-OPS-2204.js`

### Hypothesis
> Given memory spikes right before each restart and only the big export is
> affected, I think the cause is unbounded result materialization in `/api/patients/export`
> because the endpoint loads every patient row into Node memory with `SELECT * FROM patients` and then serializes one huge JSON response. With 50 concurrent export callers, memory can exceed the 160MB container limit and trigger OOM restarts.

### Observation (evidence)
> The before run reproduced a container-level failure, not a database error.
> During the run, Docker stats showed `capacity-api` at 159.8MiB / 160MiB
> (99.89% of its memory limit) and 109.60% CPU while MySQL was only at 0.67%
> CPU. The API restart count reached 12 during the first capture and 26 after
> the crash loop continued. The before k6 file was truncated before its final
> summary, but its progress output shows the failure shape: the run reported
> hundreds of thousands of completed iterations while the API was repeatedly
> restarting, which means requests were failing immediately against a dead or
> restarting socket rather than completing real exports.
>
> Docker events provided the strongest proof: repeated
> `container oom`, then `container die ... exitCode=137`, then `container start`
> for `capacity-api` between 23:38:01.528 and 23:41:32.228. The event file
> contains 14 `oom` events, 14 `die exitCode=137` events, and 14 `start` events.
> The `die` events show each failed container instance survived only 6-10s under
> the export job (`execDuration=6` x5, `7` x3, `8` x4, `9` x1, `10` x1). That
> reconciles the restart counter change from 12 to 26. The API logs also showed
> the service starting repeatedly, which matches the restart loop.
> Grafana was not reliable for route-level export evidence during the failure
> because the API was repeatedly dying, so Prometheus could not consistently
> scrape `/metrics`.

| Metric                          | Before | After |
|---------------------------------|--------|-------|
| API memory sample               | 159.8MiB / 160MiB (99.89%) | 71.5MiB / 160MiB (44.69%) |
| API CPU sample                  | 109.60% | 125.57% |
| MySQL CPU sample                | 0.67% | 15.06% |
| Docker OOM/die/start events     | 14 / 14 / 14 | 0 / 0 / 0 in after-events window |
| Time alive before crash         | 6-10s per restarted instance | no crash in sampled after window |
| Restart count                   | 12, then 26 in same crash loop | 0 on rebuilt fixed container |
| Peak Node heap                  | not captured; API died before reliable `/metrics` scrape | 26,685,832 bytes (~25.4MiB) post-run sample |
| k6 checks                       | no final summary; run interrupted by crash loop | 150/150 passed |
| Error rate                      | not reported by truncated k6 output | 0.00% |

### Root cause & mechanism
> The root cause is unbounded result materialization in
> `/api/patients/export`. The endpoint ran `SELECT * FROM patients`, stored the
> full result set in a JavaScript array, then asked Express to serialize one huge
> JSON response. With 50 export callers and the OPS-2202 pool widened to 20
> MySQL connections, multiple full-table exports could be live in the Node
> process at the same time.
>
> The mechanism is O(N) memory per request, multiplied by concurrency. From the
> after run, one successful full export response was about
> `5.5GB / 150 = 36.7MB` over the wire, which is about
> `36.7MB / 100,000 rows = 367 bytes/row` serialized. Before the fix, Node had
> to hold the MySQL rows plus the JSON/string/socket buffers for each in-flight
> export. Wire bytes are not the same as resident memory, but they show the
> scale: one unfixed in-flight export can hold roughly JS row objects (~48MB),
> JSON/string output (~35MB), and socket buffers (~35MB), or about 120MB before
> overhead. Against a 160MB container limit, one or two concurrent full exports
> can be enough to OOM the process; the 50-VU test and 20-connection pool made
> that failure repeat quickly.
>
> The container configuration makes the crash sharper: `docker-compose.yml`
> gives Node `--max-old-space-size=256`, but the API container is capped at
> 160MB. V8 believes it can grow beyond the cgroup memory limit, so it can
> over-commit before garbage collection rescues the process. The 109.60% API CPU
> sample during the crash loop is consistent with GC pressure while live export
> data approaches the cap. At the captured failure point the API hit
> 159.8MiB / 160MiB and Docker killed it with exit code 137. MySQL was idle
> because the crash was in API memory, not in the database.

### Fix & verify
> Fix applied: I changed `/api/patients/export` to stream one JSON response in
> 500-row batches using keyset pagination (`WHERE id > ? ORDER BY id LIMIT ?`).
> The API still exports all patient rows, but it no longer holds the full result
> set and full serialized JSON body in memory at once.
>
> Verification: the after k6 run completed successfully with 150/150 checks
> passing, 0.00% failures, and 150 full exports completed. Docker stats during
> the run showed `capacity-api` at 71.5MiB / 160MiB (44.69%) instead of
> 159.8MiB / 160MiB. The after-window Docker events capture records the command
> and no output, meaning zero OOM, die, or start events during that sampled
> window. Final inspect showed the rebuilt fixed container at
> `OOMKilled=false ExitCode=0 RestartCount=0`; because the container was rebuilt,
> I treat `RestartCount=0` as "no restarts since the fixed deploy," not as a
> direct continuation of the before counter. API logs showed only the startup
> line.
>
> The exported payload was still large: k6 received 5.5GB total, and p95 was
> 51.49s. That is the trade-off of preserving a full-table export: it is stable
> and bounded in memory, but still slow and bandwidth-heavy. Two production
> improvements would be cheaper than this JSON-array streaming approach:
> mysql2 row streaming would avoid about 200 batch queries per export, and
> dropping unneeded large fields such as `notes` would reduce bytes sent.

---

## Post-incident review (synthesis)

### Blast-radius ranking

> All latency comparisons below are against the baseline control group:
> p95=19.27ms, p99=74.03ms, 0.00% errors at 49.42 req/s.

1. **OPS-2204 — export OOM/restart loop.** This is the highest availability
   risk because one endpoint repeatedly killed the API container. Before the
   fix, Docker showed `capacity-api` at 159.8MiB / 160MiB, then 14 `oom`,
   14 `die exitCode=137`, and 14 `start` events in about 3.5 minutes. Each
   restarted instance survived only 6-10s under the export job. A slow endpoint
   is bad; a restart loop takes the whole API with it.

2. **OPS-2203 — hot-row admission lock.** This blocked a critical write path.
   Before the fix, 21/21 MySQL threads were updating the same hospital row,
   p95 was 56.65s (2939x baseline), failures were 45.83%, and successful admits were only
   `117 / 60s = 1.95/sec`. That matches the theoretical limit of
   `1 / 0.5s = 2/sec` caused by holding the row lock during the 500ms registry
   notify.

3. **OPS-2202 — registration surge app-tier bottleneck.** This looked like a
   database-pool incident, but the pool-only test disproved that as the dominant
   cause: RPS changed only 1537.71/s -> 1581.49/s. The stronger evidence was
   API CPU at 123.33%, MySQL at 23.00%, and k6 failures that never appeared as
   Express 500s. The blast radius is high because 2000 concurrent clients can
   overload the single Node process even while MySQL looks healthy: p95 went to
   1.63s (85x baseline) on the cheapest read in the service, and every read
   endpoint shares that process. I rank it below OPS-2203 because it degraded
   without failing — 0.00% errors before the fix, and it recovered on its own
   when concurrency dropped — whereas OPS-2203 hard-failed 45.83% of admissions
   on a clinical write path. If the ranking criterion were "number of endpoints
   affected" rather than "severity of failure," these two would swap.

4. **OPS-2201 — patient search payload blow-up.** This was severe for the
   search route but had the narrowest blast radius. Before the fix, p95 was
   10.58s (549x baseline) and throughput was 19.83/s. The index-only test showed the obvious
   index fix did not help: p95 was 16.59s and throughput was 19.64/s because
   the endpoint still returned 10,000 full records. Bounding the payload fixed
   the route to p95=173.26ms and 1798.85/s.

### How the four incidents and fixes interact

These were not four independent bugs. Two mechanisms account for all four
tickets, and one of my own fixes made a later incident worse.

- **`SELECT *` with no bound appeared in three of the four incidents.**
  `/api/patients/search` returned 10,000 full rows (3.59MB/response),
  `/api/patients/recent` returned all columns for 50 rows (18.4KB/response),
  and `/api/patients/export` returned the whole table (36.7MB/response). Three
  different tickets, three different symptoms — 10s latency, app-tier CPU
  saturation, and OOM kills — from the same coding habit. Bounding columns
  and row counts was part of the fix in all three.
- **`connectionLimit: 2` shaped OPS-2201 and OPS-2202.** Two independent runs
  converged on the same ceiling: 2 connections / 1.11ms = 1798/s in the fixed
  2201 run, and 2 / 1.30ms = 1537/s in the 2202 before-run. That agreement is
  what let me measure the pool width from throughput alone.
- **Fixing OPS-2202 made OPS-2204 worse.** I widened the pool from 2 to 20 for
  the registration surge. That permitted up to 20 concurrent unbounded exports
  instead of 2, and each in-flight export needed roughly 120MB against a 160MB
  cap. I predicted this in the OPS-2201 write-up before running OPS-2204, and
  the crash loop confirmed it: instances died after 6-10s. The order I fixed
  things in changed the severity of a later incident, which is an argument for
  bounding payloads *before* widening any concurrency limit.

### One fix before launch

If I could ship only one fix before launch, I would ship **OPS-2204's streaming
export fix**. It changes the failure mode from "the API restarts every 6-10s"
to "the export is slow but completes." The after run completed 150/150 checks
with 0.00% failures, API memory stayed around 71.5MiB / 160MiB, and the sampled
Docker events window had no OOM, die, or start events. This is the fix that most
directly protects overall service availability.

The deciding factor is that OPS-2204 is the only incident triggered by a
*scheduled* job rather than by user traffic. The other three need a traffic
spike to fire, so their probability depends on load. The nightly export runs
every night, so this failure is a certainty rather than a risk, and it is the
only one of the four that kills the process and takes unrelated requests down
with it.

### Alerts and dashboards

- **OPS-2201:** alert on `/api/patients/search` p95 latency over 300ms for
  5 minutes, plus a dashboard panel for response bytes per route. The real
  signal was not just query time; it was multi-MB responses from a lookup
  endpoint.
- **OPS-2202:** alert when API CPU is above 100% while MySQL CPU and
  `Threads_running` stay low, plus an alert on non-200 or aborted client
  requests that do not appear as Express 500s. That catches the "DB looks idle,
  app is overloaded" case. The most direct signal would have been
  `nodejs_eventloop_lag_seconds`, which `collectDefaultMetrics` already exports
  and which no dashboard in this lab plots — it measures the bottleneck I found
  instead of inferring it from a CPU ratio. Pool acquire-wait time would have
  been the companion metric, and its absence is why the pool looked guilty for
  as long as it did.
- **OPS-2203:** alert on `ER_LOCK_WAIT_TIMEOUT` and InnoDB row-lock waits for
  `hospitals.PRIMARY`, plus a dashboard showing lock wait count by table/index.
  The capacity signal was 1.95 successful admits/sec against a 2/sec serialized
  lock ceiling.
- **OPS-2204:** alert when API RSS exceeds 85% of the container limit, and alert
  immediately on Docker `oom`, `die exitCode=137`, or restart-count increases.
  A full-table export should also have its own bytes-sent and duration panel.
  The cheapest control here is not an alert at all but a deploy-time check:
  fail the build when V8's `--max-old-space-size` exceeds the container memory
  limit. This service shipped with 256MB against a 160MB cap, which is why it
  over-committed and was OOM-killed instead of garbage-collecting to survive.

None of these four would have fired on a database dashboard. Every mechanism I
found — response payload size, Node event-loop saturation, row-lock hold time,
and container memory — lives above or beside MySQL, not inside it. That is the
practical reason the DBAs in OPS-2202 could truthfully say "the DB is bored"
while the service was failing.

### Biggest surprise

The surprise was that "the database looks fine" meant three different things in
three incidents. OPS-2202 was mostly Node/socket pressure, OPS-2203 was InnoDB
row-lock waiting with low CPU, and OPS-2204 was API memory/OOM while MySQL was
almost idle. The same surface symptom needed three different mechanisms and
three different fixes.
