# JC-259 scheduler and worker recovery audit

JC-259 is a structured audit. It permits executable evidence and separate CANDIDATE findings, while preserving the current occurrence identity, claim CAS, collection ownership and dispatch fences. This branch starts at JC-258 head `523326e69a12213ed26f64d56be9d0070cf3b7a5` and will form the eighth draft PR in the requested stack. Canonical main is `12cb5ee4107ca465c9b773b258c1cbae4754b2c7`. The live prerequisites JC-229, JC-230, JC-237, JC-238, JC-239, JC-242 and JC-252 are Done, and their implementation exists on main.

## Current authority and corrections

The old issue cites Oban 2.20.3. The current lockfile pins 2.24.1. Review its installed source and version-compatible primary documentation before characterizing insertion conflicts, acknowledgement or retention. The process worker still uses infinite worker-and-args uniqueness with the default successful state group. A completed retained job can therefore conflict with a later insertion. The production fan-out treats every successful insertion result as success, including conflicts. This source observation needs a fixture-backed reproduction before it becomes the current audit finding.

The current not-due path can recover a reached collection. It does not always return noop. A missing-payment-method failure has no reached collection and provides a bounded case for testing an early technical retry. Run an identified persisted job through the actual Oban executor with acknowledgement enabled, rather than relying on the testing helper that disables acknowledgement. Any manually prepared execution state, prior attempt number or business deadline must be explicit in the report. Use no queue drain or global pruning operation.

The processing attempt now has an order-based resume clause. Current collections have database identity, exact PaymentIntent binding and dispatch epochs. The attempt CAS excludes the same stale snapshot; a fresh reader may claim again. That statement alone proves neither a second collection nor a duplicate provider operation. Investigate a controlled staggered execution using existing query telemetry and independent physical connections. If a safe deterministic proof is unavailable, retain the gap explicitly rather than adding a production seam or claiming financial safety.

## Evidence and scope

Add focused audit tests for completed-job retry conflicts, caller interpretation, payment-method repair and the durable state left by a final technical attempt. Distinguish actual executor acknowledgement from a seeded completed row and distinguish a seeded final attempt number from five observed executions. Test retained timestamps without claiming the Pruner ran. Its configured 24-hour retention is not an exact business scheduling guarantee.

Map C0 through C9 and all fourteen issue dimensions to current source, observed tests and explicit unresolved evidence. Run relevant accepted collection, retry, monotonicity and cancellation proofs. Provider response loss remains inconclusive when the current adapter cannot recover the exact transaction identity. Do not invent provider retrieval or same-request replay capabilities. Preserve JC-365 ownership of lost paid-order consequence enqueue and the narrower successful exact-renewal replay evidence from JC-257.

Use the existing DevCore TEST database and Redis, bounded local provider stubs and one Mix owner. Physical contention tests require committed fixtures, distinct PostgreSQL connections and exact cleanup. Do not change production scheduling, retry offsets, worker uniqueness, provider behavior, database pools, infrastructure or Product policy. No frontend changes are planned.

## Work sequence and review

1. Commit a complete root-reviewed plan for the retry and exhaustion proofs. Use a fresh implementation worker, then separate specification and quality reviews.
2. Resolve the feasibility of the C2 staggered proof. Commit its complete plan before implementation if the existing instrumentation supports a safe proof. Otherwise record the precise missing evidence.
3. Search Linear before filing findings. Write the durable audit with current outcomes for every crash boundary and acceptance dimension, without a blanket PROVEN_GOOD claim.
4. Inspect the complete final diff, run required repository checks and relevant real-connection proofs, and obtain fresh final reviews of the exact head. Publish the draft PR above JC-258. Human review and merge remain required.

The audit changes tests and documentation. Production resource measurements, capacity and convergence remain UNMEASURED. Any focused fixture counts describe those fixtures only.
