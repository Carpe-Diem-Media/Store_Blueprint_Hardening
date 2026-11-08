# JC-248 durable repair delivery

Use `subagent-driven-development` for R3. Root owns all Mix, DevCore, formatting, migrations/snapshots, Git and external writes. The approved correction design is `docs/superpowers/specs/2026-11-08-jc-248-review-corrections-design.md`. This task preserves the entire APPLIED AccessEffect and all existing source/provenance fences.

## Files and boundaries

- Add the purpose-specific `Store.Subscriptions.AccessRepairDelivery` Ash resource and register it in the Subscriptions domain.
- Add private action/change/query helpers only where needed to preserve resource ownership and indexed bounded reads. Do not add a public facade entrypoint or a new worker solely for delivery.
- Modify the existing APPLIED repair transaction and the existing periodic recovery facade and worker.
- Add focused tests beside the committed AccessEffect execution fixtures, plus migration tests as needed. Leave the shared paid-activation fixture unchanged.
- Root generates the migration and resource snapshot, then adds a rollback fence before dropping a table with pending delivery obligations.

## Test first

Start with a regression that reproduces repair correctness followed by failed publication, five real acknowledged Oban failures and discarded work. Use the installed Oban Executor with `ack: true`, preserving actual attempt and job states. Restore publication, confirm grants are already healthy and the original effect timestamp is nonnull, and run periodic recovery. Require rediscovered publication without changing any AccessEffect field. Root must observe this fail before production edits.

Add separate focused tests for cache failure and PubSub failure. Test both actual crash boundaries, after correctness commit before side effects and after side effects before acknowledgement. A telemetry barrier can stop the exact worker at COMMIT or before its acknowledgement write, while an independent connection proves durable committed grants and pending delivery. Do not add a test-only production callback. Keep process/backend distinctions explicit and clean up tasks, telemetry and fault adapters in `after` blocks.

## Operational resource

Store one row per AccessEffect with UUIDv7 ID, effect relationship, complete recipient UUID array sorted by binary UUID order, positive requested generation, nonnegative delivered generation, successful delivery timestamp and insertion/update timestamps. Enforce unique effect identity and `0 <= delivered_generation <= generation` in the database. There is no business target or alternate grant authority.

Use private Ash actions with explicit system-context authorization. Request creation or update runs inside the existing source correctness transaction after grant convergence. Existing Subscription, effect and grant locks precede the operational row lock. Requests retain the union of all outstanding recipients. An actual grant change always advances generation. An unchanged pending request can reuse its generation. A new request after successful delivery advances generation. Acknowledgement takes only the operational row lock and compares the exact generation and recipient snapshot.

Pending discovery uses the partial index `(inserted_at, id) WHERE delivered_generation < generation`. Use a typed composite lower cursor, a fixed insertion high-water, ordered LIMIT and validated cursor pairs. Do not introduce another expanded OR cursor that rescans visited history.

## Delivery and recovery

After correctness commit, use the existing Entitlements post-commit invalidation and broadcast for every durable recipient. Hold no source or operational lock during these calls. Acknowledge only after all recipients succeed and only for the snapshot actually delivered. Partial failure, process death, stale acknowledgement or acknowledgement failure must leave the current obligation pending. Preserve the existing facade's retryable error behavior and the worker's truthful success/failure semantics.

Add a fourth independent `repair_delivery` stream to `run_subscription_access_effect_recovery_for_system/1` and `RunSubscriptionAccessEffectRecoveryWorker`. Include count, cursor and skip state, paired cursor validation and continuation serialization. Advance the cursor past failures so early persistent failures cannot starve later rows. A fresh sweep must rediscover pending work regardless of grant health, original effect delivery timestamp or lost/discarded repair job.

Old pending notifications remain deliverable after newer authority commits. They invalidate caches and publish user IDs; they never write grants or execute old targets. Acknowledgement covers sender-local cache invalidation and PubSub publication. Receiving-node cache eviction is the separate pre-existing JC-374 gap, not a claim of this correction.

## Required green evidence

- Atomic grant correction plus delivery request, full APPLIED equality and rollback of both when the correctness transaction fails.
- Cache and PubSub failures separately; actual five-attempt Oban discard and periodic rediscovery afterward.
- Actual process death at each specified boundary and safe repeated publication.
- Partial current/historical-owner delivery with complete durable recipient retention.
- Concurrent repairs produce one obligation and lose no recipients. A later generation survives an old in-flight acknowledgement, including a grant change with unchanged recipients.
- Newer source authority remains unchanged when an older delivery completes.
- Bounded recovery pages with timestamp ties, repeated failing prefix and insertion high-water exclusion.
- Non-system reads and writes rejected before SQL; actual positive system actions work. Refresh #220's literal inventory and authorization evidence during downstream propagation.
- Rollback refuses pending obligations and succeeds after delivery. Root checks generated migration and snapshot alignment.

Run targeted tests through a fresh DevCore test suffix before the whole issue's required checks. Obtain fresh specification and quality reviews of the complete R3 diff. Report query counts, cleanup and repeated bounded measurements. Do not certify arbitrary grant-history fanout, memory convergence, remote receipt or production capacity.
