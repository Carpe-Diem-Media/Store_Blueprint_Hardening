# JC-258 policy inventory and matrix audit plan

> **For agentic workers:** Use the repository's current implementation workflow. This plan describes one focused test module and does not authorize policy, production, or matrix edits.

**Goal:** Add a fixture-backed audit test that inventories every compiled action in `Store.Subscriptions`, maps each action to the current policy group and canonical authority status, and records policy decisions for the required actor contexts.

**Architecture:** The test will use an explicit action-to-policy-group map, actual role-assigned users, and Ash policy preflight with `Ash.can/3`. A runtime coverage guard will compare the map with `Ash.Domain.Info.resources/1` and `Ash.Resource.Info.actions/1`, so additions or removals require review. Row visibility for `StoredPaymentMethod` and ownership-scoped `Subscription` reads will use real persisted rows and direct `Ash.read` calls as separate evidence.

**Tech Stack:** Elixir, ExUnit, Ash 3.x, `Store.DataCase`, SQL Sandbox, DevCore.

---

## Files and boundaries

Create only `test/store/governance/jc258_action_policy_inventory_audit_test.exs`. Use `Store.DataCase, async: false`. Do not modify policies, permissions, `docs/governance/policy_matrix.md`, providers, facades, UI, fixtures, or project configuration. Do not call external providers. Use existing role and subscription fixtures. No Mix or database command is part of plan authoring.

The sibling setup-flow test is owned separately. This test does not duplicate its provider stub or financial setup assertions.

## Reviewed 92-action inventory

Each action below appears in the explicit inventory map in the future test. Policy groups below reflect the currently inspected resource predicates and the corrected diagnostic probe. Expected checks are observations of this branch, not proof that an undocumented policy is good.

Canonical authority labels:

- `MATRIX`: the existing `docs/governance/policy_matrix.md` has an applicable row. This permits comparison, not correction.
- `MATRIX_DISCREPANCY`: current code permits a role or action that the matrix explicitly denies or excludes. Record the conflict for governance review.
- `NEEDS_PRODUCT_DECISION`: the matrix has no specific authority for the action. For non-read actions, the matrix default denies unless it lists an exception. Current admin writes on unlisted newer resources remain observed conflicts, not authorized behavior. Preserve current role results under `OBSERVED_CURRENT_POLICY`.
- `SYSTEM_ROW_GAP`: matrix language names a SYSTEM-only lifecycle operation, while current resource policy also accepts admin and super_admin. Record the mismatch as a candidate. Do not change it in this audit.
- `SELF_ROW`: matrix defines customer self-service. Query-level allowance does not prove that a particular row exists or is visible.

| Resource | Actions and current policy group | Canonical authority |
|---|---|---|
| `SubscriptionPlan` | `read`, `read_for_admin`, `get_for_admin`, `get_by_key_for_system`: `staff_read` (support, admin, super_admin, system); `read_for_public`: `public_read` (all eight contexts, including editor); `create`, `update`, `archive`, `activate`: `admin_write` (admin, super_admin, system) | `MATRIX` for plan read and create/update role authority. `read_for_public` editor allowance is `MATRIX_DISCREPANCY`, because matrix says editor NO. Support field projection and `get_by_key_for_system` alternatives are `NEEDS_PRODUCT_DECISION`. Archive/activate are `:update` actions, so their admin and super_admin authority is covered by the matrix C/U/D row. |
| `PlanRevision` | `read`, `get_effective_for_plan`: `staff_read`; `create_draft`, `update_draft`, `publish`, `retire`: `admin_write` | `NEEDS_PRODUCT_DECISION`. The current admin writes conflict with deny-by-default. Do not inherit the SubscriptionPlan row. |
| `ContractChange` | `read`, `read_for_subscription`: `staff_read`; `queue`, `supersede`, `cancel`, `bind_to_renewal`, `apply`: `admin_or_system_write` (admin, super_admin, system) | `NEEDS_PRODUCT_DECISION`. Current admin write allowances conflict with deny-by-default. Do not inherit Subscription cancellation authority. |
| `VariantSubscriptionPlan` | `read`, `read_active_for_variant`, `read_for_admin`: `staff_read`; `attach`, `set_active`: `admin_write` | `NEEDS_PRODUCT_DECISION`. Current admin write allowances conflict with deny-by-default. |
| `StoredPaymentMethod` | default `read`, `get_for_system`: `owner_or_staff_read` (staff roles and system; owner/non-owner/editor preflight is `:maybe`); `create_or_reuse`, `mark_active`, `mark_inactive`, `mark_revoked`: `admin_write` | `NEEDS_PRODUCT_DECISION`. Current admin write allowances conflict with deny-by-default. No field projection rule is defined. Direct row visibility is tested separately. |
| `Subscription` | `read`, `read_for_admin`, `get_for_admin`, `read_due_for_system`, `read_due_failed_payment_boundary_for_system`, `read_due_scheduled_cancellations_for_system`, `read_past_due_missing_boundary_for_system`: `staff_read`; `read_for_user`, `get_for_user`: `self_read`; `cancel_at_period_end_transition`, `cancel_now_transition`, `queue_change`, `rescind_cancel_at_period_end_transition`, `scheduled_boundary_cancellation_transition`: `self_or_admin_write`; `read_access_inventory_window_for_system`: `system_only`; `activate_now`, `mark_expired_transition`, `mark_past_due_transition`, `mark_suspended_transition`, `extend_period`, `set_provider_billing_reference`, `consume_contract_change_for_renewal`, `create_from_order_line`: `admin_or_system_write` | `MATRIX` R covers Subscription read actions, including due reads, with support LIMITED projection unspecified. `MATRIX` self read/cancel covers named user actions. `SYSTEM_ROW_GAP` applies to current admin/super_admin access for activate/past-due/reconcile actions. `NEEDS_PRODUCT_DECISION` applies to the inventory-window action and other non-read operations absent from the matrix. A `*_for_system` read suffix does not remove it from the R row. Query permission does not prove a due row exists. |
| `SubscriptionItem` | `read`, `read_for_subscription`: `staff_read`; `create_from_order_line`: `admin_write` | `NEEDS_PRODUCT_DECISION`. Current admin create allowance conflicts with deny-by-default. |
| `RenewalAttempt` | `read`, `read_for_subscription`, `read_for_admin`: `staff_read`; `create_or_reuse`, `mark_succeeded`, `mark_processing`, `mark_failed`, `mark_authority_withdrawn`: `admin_or_system_write` | `MATRIX` for reads and SYSTEM-only create/update. Current admin alternatives on writes are `SYSTEM_ROW_GAP`. Support field projection is unspecified. |
| `RenewalCollectionAttempt` | `read`, `read_for_renewal_attempt`: `staff_read`; `create`, `assign_reservation_generation`, `attach_payment_intent`, `claim_dispatch`, `attach_and_claim_dispatch`, `record_financial_outcome`, `fence_before_submission`, `resume_after_fence`: `admin_or_system_write` | `NEEDS_PRODUCT_DECISION`. Current admin write allowances conflict with deny-by-default. Do not inherit RenewalAttempt's row. |
| `AccessEffect` | `read`, `read_current_for_subscription`, `read_for_subscription_source_version`, `read_recoverable_effective_for_system`, `read_recoverable_non_effective_for_system`, `read_target_order_candidates_for_system`, `read_pending_projection_repair_for_system`: `system_only`; `read_applied_verification_window_for_system`: private `system_only_action`; `establish`, `mark_applied`, `mark_pending_from_required`, `mark_projection_delivered`, `mark_failed_retryable`, `retry_to_pending`, `supersede`: `system_only` | `NEEDS_PRODUCT_DECISION`. The names and architecture do not establish permission law. Preserve trusted system operations; record absent explicit role authority as a decision, not a blanket change to system orchestration. |

The two action names missing from `origin/main` in the reviewed stack are `Subscription.read_access_inventory_window_for_system` and `AccessEffect.read_applied_verification_window_for_system`. The future coverage assertion must compare against the runtime compiled inventory of this branch, not a committed snapshot or an assumed main inventory. The current facade adds no action for this issue.

The facade guard also uses explicit names from `tmp/jc258/facade-inventory.md`: 7 USER names, 7 ADMIN names, and 33 SYSTEM names. Compare their union with `Store.Subscriptions.Facade.__info__(:functions)` names, and assert the current compiled facade has 47 distinct names and 61 name/arity pairs. These are approved consumer categories in `Store.Support.Governance.SurfaceRegistry`, not runtime roles. Do not classify by suffix or imply that the guard proves runtime call-graph confinement. The 102 source clauses include fallback clauses and are not compiled exports. The `:system` category means trusted application code, not a user role.

The policy matrix's step-up rules name refunds, provider configuration, and bank details. Do not extend those rules to customer payment-method setup. Phase 26 names `provider_customer_ref` and `provider_billing_ref` as optional support snapshots and `billing_status_reason` for support visibility. That does not define the complete `LIMITED` projection, so this audit records returned Subscription and nested fields without calling any one forbidden. The older canceled-after-grace wording in Phase 26 is superseded by current `SUSPENDED` semantics.

## Test design and evidence rules

### 1. Inventory drift guard

At test start, collect `Store.Subscriptions` resources using `Ash.Domain.Info.resources(Store.Subscriptions)`. For each resource, collect action names through `Ash.Resource.Info.actions(resource)`. Compare sorted `{resource, action}` pairs for exact equality with the explicit map. Assert there are ten expected resources and 92 entries on this branch. The equality assertion is the durable check; the counts give a clear failure if an unexpected resource or action appears. Keep the expected map in test source. Do not build expected policy categories by reflecting policy definitions, because that would make implementation and expectation derive from the same source.

The map stores `{group, canonical_label}` per action. Expand groups only for actor expectation, not for expected coverage. Use groups defined in the inventory table above. Canonical labels remain explicit per action so every action has an auditable authority assignment.

### 2. Actor fixtures and contexts

Create actual persisted users and assign exactly one role each with `Store.TestFixtures.register_user!/1` and `Store.TestFixtures.assign_role!/2` for `:support`, `:editor`, `:admin`, and `:super_admin`. Create an owner and a non-owner with `Store.SubscriptionsFixtures.create_customer!/1`. Add `anonymous` as `{nil, %{}}` and `system` as `{nil, %{system?: true}}`. The actor context order is owner customer, non-owner customer, support, editor, admin, super_admin, anonymous, system.

Use the corrected probe's eight context names, but do not copy its generated UUID fallback values or its `Ash.can?/3` call. `Ash.can?/3` defaults `maybe_is: true`, so it is not used. Call `Ash.can(subject, actor, validate?: false, context: context)` for every policy cell. Its result is only `CURRENT_POLICY_PREFLIGHT`, even when it is true. The prior diagnostic probe observed 736 outcomes as 277 true, 449 false, 6 maybe, and 4 errors. Those totals are debugging evidence only, never a golden assertion.

When `Ash.can/3` returns `{:ok, :maybe}`, keep that as `:maybe` and do not collapse it to allowed or denied. Do not rescue arbitrary exceptions into false. A raised exception, returned error, or unexpected result must fail the assertion with action and actor context in its message, except for the separately specified actor-required nil user-read contract.

### 3. Typed action input and valid preflight subjects

For every action, construct a separate validity subject by action type with `Ash.Query.for_read/4`, `Ash.Changeset.for_create/4`, `Ash.Changeset.for_update/4`, or `Ash.ActionInput.for_action/4`, using arguments declared by `Ash.Resource.Info.action/2`. Run `Ash.can(subject, actor, validate?: false, context: context)` for policy preflight regardless of changeset attribute validity, and label every result `CURRENT_POLICY_PREFLIGHT`. Keep the validity result beside it. Invalid action inputs do not become permission denials. A valid policy preflight does not prove handler execution.

Use the action's declared Ash types. Supply `subscription.id` only for Subscription IDs, `payment_method.id` only for StoredPaymentMethod IDs, `plan.id` only for SubscriptionPlan IDs, and `subscription_item.id` only for SubscriptionItem IDs. Use those records for corresponding foreign keys. For optional cursors, use `nil` only when the argument type/options allow nil. Use UTC datetimes truncated to microseconds for time arguments, positive integer values within declared constraints, and action-specific enum values from the action definitions. For required records whose valid creation requires a complex lifecycle or foreign graph, use the separate policy preflight evidence limitation below instead of fabricating an ID or claiming valid commerce execution.

For update actions where the policy decision depends on `user_id`, `owner`, or stored row state, build `Ash.Changeset.for_update/4` against a persisted fixture of that exact resource. `struct(resource)` is acceptable only when source inspection confirms the policy decision does not depend on persisted attributes and the result is labeled as policy preflight, with no claim about executable row mutation. Never reuse a subscription ID as the payment method ID. Never provide invented foreign keys and call them valid commerce inputs.

A well-typed subject does not execute the action handler. Any cell requiring handler results, lifecycle state changes, row existence, query filtering, or field projection is reported in its dedicated evidence case or marked `INDETERMINATE_PREFLIGHT_ONLY`.

### 4. Expected policy cells

Define expected actor sets explicitly, separately from policy reflection:

- `public_read`: all eight actor contexts.
- `staff_read`: support, admin, super_admin, system.
- `admin_write`: admin, super_admin, system.
- `admin_or_system_write`: admin, super_admin, system, while canonical authority labels determine whether those successes are only `OBSERVED_CURRENT_POLICY` or a `SYSTEM_ROW_GAP`.
- `self_read`: owner customer only. The persisted Subscription subject returns false for non-owner, support, editor, admin, and super_admin. Nil anonymous and system actors produce the action-required error, not denial.
- `self_or_admin_write`: owner customer, admin, super_admin, system. This is the current predicate expectation. Canonical self-cancel authority and action scope still require row-specific interpretation.
- `system_only` and `system_only_action`: system only.
- `owner_or_staff_read`: owner, non-owner, and editor preflight remains `:maybe` even for a persisted method. Preserve `:maybe` as `CURRENT_POLICY_PREFLIGHT`. Direct reads establish actual row visibility.

Assert the exact preflight result from the explicit role group, preserving `:maybe` and actor-required errors. Treat every result as `CURRENT_POLICY_PREFLIGHT`, not `PROVEN_GOOD` or executable permission. For `MATRIX` rows, compare only the stated matrix clause. A matrix read row does not prove field projection or row availability. For `NEEDS_PRODUCT_DECISION`, report current role results and absent authority. The category also identifies current non-read admin grants that conflict with deny-by-default. For `SYSTEM_ROW_GAP`, report the current admin/super_admin allowance against the named SYSTEM-only authority without changing policy.

The test keeps nil actor `read_for_user` and `get_for_user` contracts separate from denials. Both anonymous and system contexts produce `Ash.Error.Invalid` containing `Ash.Error.Query.ReadActionRequiresActor`. The persisted Subscription preflight yields true for its owner and false for non-owner, support, editor, admin, and super_admin. The fixture's subscription ID is used in each check.

### 5. Persisted owner and direct method visibility cases

Create one valid subscription fixture for an owner and one distinct non-owner. Use direct `Ash.read` for `Subscription.get_for_user` with `id: subscription.id`, once with owner and once with non-owner. Assert the owner result contains exactly the persisted subscription. Record the non-owner result as the actual contract. An empty query result is row filtering, not policy denial. Do not call the same action with an arbitrary UUID and label no result as forbidden.

For StoredPaymentMethod, use `create_subscription_fixture!/4` with unique fake `provider_customer_ref` and `provider_billing_ref` so the existing fixture creates the persisted method without a provider call. Retain that exact row and its own `id`. Execute direct `Ash.read` of the default `:read` action using a filter on that method's ID and compare owner, non-owner, editor, support, admin, super_admin, and system contexts. Assert the observed contract precisely: returned row versus filtered empty list versus `%Ash.Error.Forbidden{}`. Do not accept validation errors as access outcomes. Keep the `get_for_system` action separate from default `read`. Do not write an invented `LIMITED` field allowlist.

The test records direct read and preflight results separately. The owner, non-owner, and editor preflight remains `:maybe` for both stored-method read actions even against the persisted subject, so only the direct row result establishes visibility.

### 6. Evidence limits

This module audits policy predicates and two focused row-level read contracts. It does not execute all 92 handlers, prove that each operation's domain preconditions pass, verify support field projection, establish that system-only named resources should be system-only, or prove provider work. Some create/update actions need unrelated lifecycle state or handler dependencies. Record their result as `CURRENT_POLICY_PREFLIGHT` only, retain the known validity errors in the literal expected invalid-input set, and mark executable behavior `INDETERMINATE_EXECUTION`. Do not fabricate valid commerce state to turn those cases into execution tests. The separate setup audit owns provider-backed support initiation evidence.

Do not use one probe output file as expected test data. The corrected probe's 6 maybe outcomes and 4 actor errors, plus the earlier flawed probe's reused payment-method ID and intentionally incomplete validity checks, show why a copied 736-cell snapshot would be unsound.

## Proposed test module and codefreeze limits

The full module below uses the explicit 92-entry `@action_policy` map. Root ran a bounded direct-read diagnostic with a persisted method and the eight required contexts. The expected results below reflect that diagnostic. No preflight `true` is treated as executable authorization.

```elixir
defmodule Store.Governance.JC258ActionPolicyInventoryAuditTest do
  use Store.DataCase, async: false

  import Ash.Expr
  require Ash.Query

  alias Store.Payments.PaymentIntent
  alias Store.Subscriptions
  alias Store.Subscriptions.AccessEffect
  alias Store.Subscriptions.ContractChange
  alias Store.Subscriptions.PlanRevision
  alias Store.Subscriptions.RenewalAttempt
  alias Store.Subscriptions.RenewalCollectionAttempt
  alias Store.Subscriptions.StoredPaymentMethod
  alias Store.Subscriptions.Subscription
  alias Store.Subscriptions.SubscriptionItem
  alias Store.Subscriptions.SubscriptionPlan
  alias Store.Subscriptions.VariantSubscriptionPlan
  alias Store.SubscriptionsFixtures
  alias Store.Subscriptions.Facade, as: SubscriptionsFacade
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub

  setup context do
    StripeAPIStub.setup_default(context)
    StripeAPIStub.stub_unexpected!("policy inventory audit must not call Stripe")
    :ok
  end

  @user_facade_names [:list_subscriptions_for_user, :get_subscription_for_user,
    :get_subscription_detail_for_user, :cancel_subscription_for_user,
    :queue_subscription_plan_change_for_user, :queue_subscription_variant_change_for_user,
    :start_subscription_payment_method_update_for_user]
  @admin_facade_names [:list_subscriptions_for_admin, :get_subscription_for_admin,
    :get_subscription_detail_for_admin, :cancel_subscription_for_admin,
    :queue_subscription_plan_change_for_admin, :queue_subscription_variant_change_for_admin,
    :start_subscription_payment_method_update_for_admin]
  @system_facade_names [:list_subscription_access_inventory_window_for_system,
    :subscription_access_inventory_upper_bound_for_system, :establish_access_effect_for_system,
    :get_current_access_effect_for_system, :list_applied_access_verification_window_for_system,
    :verify_subscription_access_window_for_system,
    :validate_complete_bound_renewal_attempt_for_system,
    :mark_access_effect_pending_for_system, :mark_access_effect_applied_for_system,
    :mark_access_effect_failed_retryable_for_system, :retry_access_effect_for_system,
    :execute_effective_access_effect_for_system, :reconcile_subscription_access_for_system,
    :execute_suspension_access_effect_for_system, :repair_applied_access_effect_for_system,
    :repair_suspension_access_effect_projection_for_system,
    :run_subscription_access_effect_recovery_for_system,
    :run_access_effect_target_order_reconciliation_for_system,
    :list_variant_subscription_plan_options_for_system,
    :resolve_variant_subscription_plan_for_system,
    :ensure_membership_purchase_allowed_for_system,
    :order_has_subscription_lines_for_system, :order_is_subscription_only_for_system,
    :create_subscriptions_from_paid_order_for_system,
    :handle_payment_method_update_succeeded_for_system, :run_due_renewals_for_system,
    :run_due_failed_payment_suspensions_for_system,
    :run_due_scheduled_cancellations_for_system,
    :replay_scheduled_cancellation_notifications_for_system,
    :list_past_due_missing_failed_payment_boundary_for_system,
    :list_due_renewal_jobs_for_system, :process_due_subscription_renewal_for_system,
    :reconcile_paid_subscription_renewal_for_system]

  @resource_modules [AccessEffect, ContractChange, PlanRevision, RenewalAttempt,
    RenewalCollectionAttempt, StoredPaymentMethod, Subscription, SubscriptionItem,
    SubscriptionPlan, VariantSubscriptionPlan]

  @expected_invalid_input_errors %{
    {AccessEffect, :establish} => MapSet.new([Ash.Error.Changes.Required, Ash.Error.Changes.InvalidAttribute]),
    {ContractChange, :apply} => MapSet.new([Ash.Error.Changes.InvalidAttribute]),
    {ContractChange, :queue} => MapSet.new([Ash.Error.Changes.Required]),
    {PlanRevision, :create_draft} => MapSet.new([Ash.Error.Changes.Required]),
    {PlanRevision, :retire} => MapSet.new([Ash.Error.Changes.InvalidAttribute]),
    {RenewalAttempt, :create_or_reuse} => MapSet.new([Ash.Error.Changes.Required]),
    {RenewalCollectionAttempt, :create} => MapSet.new([Ash.Error.Changes.Required]),
    {StoredPaymentMethod, :create_or_reuse} => MapSet.new([Ash.Error.Changes.Required]),
    {Subscription, :create_from_order_line} => MapSet.new([Ash.Error.Changes.Required, Ash.Error.Changes.InvalidAttribute]),
    {Subscription, :mark_suspended_transition} => MapSet.new([Ash.Error.Changes.InvalidAttribute]),
    {SubscriptionItem, :create_from_order_line} => MapSet.new([Ash.Error.Changes.Required]),
    {SubscriptionPlan, :create} => MapSet.new([Ash.Error.Changes.Required]),
    {VariantSubscriptionPlan, :attach} => MapSet.new([Ash.Error.Changes.Required])
  }

  @staff_roles [:support, :admin, :super_admin]

  @action_policy %{
    {AccessEffect, :establish} => {:system_only, :needs_product_decision},
    {AccessEffect, :mark_applied} => {:system_only, :needs_product_decision},
    {AccessEffect, :mark_failed_retryable} => {:system_only, :needs_product_decision},
    {AccessEffect, :mark_pending_from_required} => {:system_only, :needs_product_decision},
    {AccessEffect, :mark_projection_delivered} => {:system_only, :needs_product_decision},
    {AccessEffect, :read} => {:system_only, :needs_product_decision},
    {AccessEffect, :read_applied_verification_window_for_system} => {:system_only_action, :needs_product_decision},
    {AccessEffect, :read_current_for_subscription} => {:system_only, :needs_product_decision},
    {AccessEffect, :read_for_subscription_source_version} => {:system_only, :needs_product_decision},
    {AccessEffect, :read_pending_projection_repair_for_system} => {:system_only, :needs_product_decision},
    {AccessEffect, :read_recoverable_effective_for_system} => {:system_only, :needs_product_decision},
    {AccessEffect, :read_recoverable_non_effective_for_system} => {:system_only, :needs_product_decision},
    {AccessEffect, :read_target_order_candidates_for_system} => {:system_only, :needs_product_decision},
    {AccessEffect, :retry_to_pending} => {:system_only, :needs_product_decision},
    {AccessEffect, :supersede} => {:system_only, :needs_product_decision},
    {ContractChange, :apply} => {:admin_or_system_write, :needs_product_decision},
    {ContractChange, :bind_to_renewal} => {:admin_or_system_write, :needs_product_decision},
    {ContractChange, :cancel} => {:admin_or_system_write, :needs_product_decision},
    {ContractChange, :queue} => {:admin_or_system_write, :needs_product_decision},
    {ContractChange, :read} => {:staff_read, :needs_product_decision},
    {ContractChange, :read_for_subscription} => {:staff_read, :needs_product_decision},
    {ContractChange, :supersede} => {:admin_or_system_write, :needs_product_decision},
    {PlanRevision, :create_draft} => {:admin_write, :needs_product_decision},
    {PlanRevision, :get_effective_for_plan} => {:staff_read, :needs_product_decision},
    {PlanRevision, :publish} => {:admin_write, :needs_product_decision},
    {PlanRevision, :read} => {:staff_read, :needs_product_decision},
    {PlanRevision, :retire} => {:admin_write, :needs_product_decision},
    {PlanRevision, :update_draft} => {:admin_write, :needs_product_decision},
    {RenewalAttempt, :create_or_reuse} => {:admin_or_system_write, :system_row_gap},
    {RenewalAttempt, :mark_authority_withdrawn} => {:admin_or_system_write, :system_row_gap},
    {RenewalAttempt, :mark_failed} => {:admin_or_system_write, :system_row_gap},
    {RenewalAttempt, :mark_processing} => {:admin_or_system_write, :system_row_gap},
    {RenewalAttempt, :mark_succeeded} => {:admin_or_system_write, :system_row_gap},
    {RenewalAttempt, :read} => {:staff_read, :matrix},
    {RenewalAttempt, :read_for_admin} => {:staff_read, :matrix},
    {RenewalAttempt, :read_for_subscription} => {:staff_read, :matrix},
    {RenewalCollectionAttempt, :assign_reservation_generation} => {:admin_or_system_write, :needs_product_decision},
    {RenewalCollectionAttempt, :attach_and_claim_dispatch} => {:admin_or_system_write, :needs_product_decision},
    {RenewalCollectionAttempt, :attach_payment_intent} => {:admin_or_system_write, :needs_product_decision},
    {RenewalCollectionAttempt, :claim_dispatch} => {:admin_or_system_write, :needs_product_decision},
    {RenewalCollectionAttempt, :create} => {:admin_or_system_write, :needs_product_decision},
    {RenewalCollectionAttempt, :fence_before_submission} => {:admin_or_system_write, :needs_product_decision},
    {RenewalCollectionAttempt, :read} => {:staff_read, :needs_product_decision},
    {RenewalCollectionAttempt, :read_for_renewal_attempt} => {:staff_read, :needs_product_decision},
    {RenewalCollectionAttempt, :record_financial_outcome} => {:admin_or_system_write, :needs_product_decision},
    {RenewalCollectionAttempt, :resume_after_fence} => {:admin_or_system_write, :needs_product_decision},
    {StoredPaymentMethod, :create_or_reuse} => {:admin_write, :needs_product_decision},
    {StoredPaymentMethod, :get_for_system} => {:owner_or_staff_read, :needs_product_decision},
    {StoredPaymentMethod, :mark_active} => {:admin_write, :needs_product_decision},
    {StoredPaymentMethod, :mark_inactive} => {:admin_write, :needs_product_decision},
    {StoredPaymentMethod, :mark_revoked} => {:admin_write, :needs_product_decision},
    {StoredPaymentMethod, :read} => {:owner_or_staff_read, :needs_product_decision},
    {Subscription, :activate_now} => {:admin_or_system_write, :system_row_gap},
    {Subscription, :cancel_at_period_end_transition} => {:self_or_admin_write, :matrix},
    {Subscription, :cancel_now_transition} => {:self_or_admin_write, :matrix},
    {Subscription, :consume_contract_change_for_renewal} => {:admin_or_system_write, :needs_product_decision},
    {Subscription, :create_from_order_line} => {:admin_or_system_write, :needs_product_decision},
    {Subscription, :extend_period} => {:admin_or_system_write, :needs_product_decision},
    {Subscription, :get_for_admin} => {:staff_read, :matrix},
    {Subscription, :get_for_user} => {:self_read, :matrix},
    {Subscription, :mark_expired_transition} => {:admin_or_system_write, :needs_product_decision},
    {Subscription, :mark_past_due_transition} => {:admin_or_system_write, :system_row_gap},
    {Subscription, :mark_suspended_transition} => {:admin_or_system_write, :needs_product_decision},
    {Subscription, :queue_change} => {:self_or_admin_write, :needs_product_decision},
    {Subscription, :read} => {:staff_read, :matrix},
    {Subscription, :read_access_inventory_window_for_system} => {:system_only, :needs_product_decision},
    {Subscription, :read_due_failed_payment_boundary_for_system} => {:staff_read, :matrix},
    {Subscription, :read_due_for_system} => {:staff_read, :matrix},
    {Subscription, :read_due_scheduled_cancellations_for_system} => {:staff_read, :matrix},
    {Subscription, :read_for_admin} => {:staff_read, :matrix},
    {Subscription, :read_for_user} => {:self_read, :matrix},
    {Subscription, :read_past_due_missing_boundary_for_system} => {:staff_read, :matrix},
    {Subscription, :rescind_cancel_at_period_end_transition} => {:self_or_admin_write, :needs_product_decision},
    {Subscription, :scheduled_boundary_cancellation_transition} => {:self_or_admin_write, :needs_product_decision},
    {Subscription, :set_provider_billing_reference} => {:admin_or_system_write, :needs_product_decision},
    {SubscriptionItem, :create_from_order_line} => {:admin_write, :needs_product_decision},
    {SubscriptionItem, :read} => {:staff_read, :needs_product_decision},
    {SubscriptionItem, :read_for_subscription} => {:staff_read, :needs_product_decision},
    {SubscriptionPlan, :activate} => {:admin_write, :matrix},
    {SubscriptionPlan, :archive} => {:admin_write, :matrix},
    {SubscriptionPlan, :create} => {:admin_write, :matrix},
    {SubscriptionPlan, :get_by_key_for_system} => {:staff_read, :needs_product_decision},
    {SubscriptionPlan, :get_for_admin} => {:staff_read, :matrix},
    {SubscriptionPlan, :read} => {:staff_read, :matrix},
    {SubscriptionPlan, :read_for_admin} => {:staff_read, :matrix},
    {SubscriptionPlan, :read_for_public} => {:public_read, :matrix_discrepancy},
    {SubscriptionPlan, :update} => {:admin_write, :matrix},
    {VariantSubscriptionPlan, :attach} => {:admin_write, :needs_product_decision},
    {VariantSubscriptionPlan, :read} => {:staff_read, :needs_product_decision},
    {VariantSubscriptionPlan, :read_active_for_variant} => {:staff_read, :needs_product_decision},
    {VariantSubscriptionPlan, :read_for_admin} => {:staff_read, :needs_product_decision},
    {VariantSubscriptionPlan, :set_active} => {:admin_write, :needs_product_decision},
  }

  test "inventory covers every compiled action" do
    compiled =
      Subscriptions
      |> Ash.Domain.Info.resources()
      |> Enum.flat_map(fn resource ->
        Enum.map(Ash.Resource.Info.actions(resource), &{resource, &1.name})
      end)
      |> Enum.sort()

    assert compiled == (@action_policy |> Map.keys() |> Enum.sort())
    assert length(compiled) == 92
    resources = @action_policy |> Map.keys() |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    assert resources == MapSet.new(@resource_modules)
  end

  test "facade names have explicit consumer categories" do
    functions = SubscriptionsFacade.__info__(:functions)
    names = functions |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    expected = MapSet.new(@user_facade_names ++ @admin_facade_names ++ @system_facade_names)

    assert length(@user_facade_names) == 7
    assert length(@admin_facade_names) == 7
    assert length(@system_facade_names) == 33
    assert MapSet.size(expected) == 47
    assert names == expected
    assert length(functions) == 61
  end

  test "public plan query filters archived plans for all actor contexts" do
    active_plan = SubscriptionsFixtures.create_subscription_plan!(%{status: :active})
    archived_plan = SubscriptionsFixtures.create_subscription_plan!(%{status: :archived})
    ids = [active_plan.id, archived_plan.id]

    owner = SubscriptionsFixtures.create_customer!("jc258_public_owner")
    non_owner = SubscriptionsFixtures.create_customer!("jc258_public_non_owner")
    for {_name, actor, context} <- actor_contexts!(%{owner: owner, non_owner: non_owner}) do
      query =
        SubscriptionPlan
        |> Ash.Query.for_read(:read_for_public, %{}, actor: actor, context: context)
        |> Ash.Query.filter(expr(id in ^ids))

      assert query.valid?
      assert {:ok, rows} = Ash.read(query, domain: Subscriptions, actor: actor, context: context)
      assert Enum.map(rows, & &1.id) == [active_plan.id]
    end
  end

  test "preflights every action for all eight actor contexts" do
    fixtures = fixtures!()
    contexts = actor_contexts!(fixtures)

    for {{resource, action}, {group, authority}} <- @action_policy,
        {context_name, actor, context} <- contexts do
      args = arguments!(resource, action, fixtures)
      validity = input_validity(resource, action, args, actor, context, fixtures)
      assert_input_validity!(validity, resource, action, context_name)
      subject = preflight_subject(resource, action, args, fixtures)
      current_policy_preflight = Ash.can(subject, actor, validate?: false, context: context)
      assert_current_preflight!(current_policy_preflight, group, authority, action, context_name)
    end
  end

  test "user reads preflight and execute against the persisted Subscription row" do
    fixture = fixtures!()
    contexts = actor_contexts!(fixture)

    for action <- [:read_for_user, :get_for_user],
        {name, actor, context} <- contexts do
      args = if action == :get_for_user, do: %{id: fixture.subscription.id}, else: %{}
      query =
        Subscription
        |> Ash.Query.for_read(action, args, actor: actor, context: context)
        |> Ash.Query.filter(expr(id == ^fixture.subscription.id))

      if name in [:anonymous, :system] do
        assert query.valid? == false
        assert Enum.any?(query.errors, &match?(%Ash.Error.Query.ReadActionRequiresActor{}, &1))
      else
        assert query.valid?
        policy = Ash.can({fixture.subscription, action, args}, actor,
          validate?: false, context: context)
        assert policy == {:ok, name == :owner_customer}

        case Ash.read(query, domain: Subscriptions, actor: actor, context: context) do
          {:ok, [subscription]} when name == :owner_customer ->
            assert subscription.id == fixture.subscription.id
          {:ok, []} when name != :owner_customer ->
            :ok
          other ->
            flunk("#{inspect(action)} #{name} expected owner row or empty filtered result, got #{inspect(other)}")
        end
      end
    end
  end

  test "default and get_for_system reads use the persisted method id" do
    fixture = fixtures!()
    method = stored_method!(fixture)
    contexts = actor_contexts!(fixture)

    for action <- [:read, :get_for_system],
        {name, actor, context} <- contexts do
      args = if action == :get_for_system, do: %{id: method.id}, else: %{}
      query = Ash.Query.for_read(StoredPaymentMethod, action, args,
        actor: actor, context: context)
      query = Ash.Query.filter(query, expr(id == ^method.id))
      assert query.valid?
      result = Ash.read(query, domain: Subscriptions, actor: actor, context: context)
      assert_direct_method_result!(result, action, name, method)
    end
  end

  defp fixtures! do
    owner = SubscriptionsFixtures.create_customer!("jc258_matrix_owner")
    non_owner = SubscriptionsFixtures.create_customer!("jc258_matrix_non_owner")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    plan = SubscriptionsFixtures.create_subscription_plan!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    subscription_fixture =
      SubscriptionsFixtures.create_subscription_fixture!(owner.id, variant, plan, %{
        provider_customer_ref: "cus_jc258_matrix_#{System.unique_integer([:positive])}",
        provider_billing_ref: "pm_jc258_matrix_#{System.unique_integer([:positive])}",
        create_payment_intent?: true
      })

    subscription = subscription_fixture.subscription
    attempt = create_pending_attempt!(subscription)
    payment_intent = payment_intent_for_order!(subscription_fixture.order.id)
    stored_method = stored_method!(%{subscription: subscription})
    %{owner: owner, non_owner: non_owner, variant: variant, plan: plan,
      subscription: subscription, item: subscription_fixture.item,
      order: subscription_fixture.order, line_item: subscription_fixture.line_item,
      revision: subscription_fixture.revision, renewal_attempt: attempt,
      payment_intent: payment_intent, stored_method: stored_method}
  end

  defp actor_contexts!(fixtures) do
    roles = Map.new(@staff_roles ++ [:editor], fn role -> {role, role_actor!(role)} end)
    [
      {:owner_customer, fixtures.owner, %{}},
      {:non_owner_customer, fixtures.non_owner, %{}},
      {:support, roles.support, %{}},
      {:editor, roles.editor, %{}},
      {:admin, roles.admin, %{}},
      {:super_admin, roles.super_admin, %{}},
      {:anonymous, nil, %{}},
      {:system, nil, %{system?: true}}
    ]
  end

  defp role_actor!(role) do
    actor = TestFixtures.register_user!(email: TestFixtures.unique_email("jc258_#{role}"))
    _assignment = TestFixtures.assign_role!(actor, role)
    actor
  end

  defp stored_method!(%{subscription: subscription}) do
    query = Ash.Query.filter(StoredPaymentMethod, expr(id == ^subscription.stored_payment_method_id))
    Ash.read_one!(query, domain: Subscriptions, authorize?: false)
  end

  defp arguments!(resource, action, fixtures) do
    info = Ash.Resource.Info.action(resource, action)
    Map.new(info.arguments, fn argument ->
      {argument.name, argument_value(argument.name, resource, fixtures)}
    end)
  end

  defp argument_value(:id, StoredPaymentMethod, %{subscription: s}), do: s.stored_payment_method_id
  defp argument_value(:id, Subscription, %{subscription: s}), do: s.id
  defp argument_value(:id, SubscriptionPlan, %{plan: p}), do: p.id
  defp argument_value(:subscription_id, _resource, %{subscription: s}), do: s.id
  defp argument_value(:subscription_plan_id, _resource, %{plan: p}), do: p.id
  defp argument_value(:variant_id, _resource, %{variant: v}), do: v.id
  defp argument_value(:renewal_attempt_id, _resource, %{renewal_attempt: r}), do: r.id
  defp argument_value(:payment_intent_id, _resource, %{payment_intent: p}), do: p.id
  defp argument_value(:through_id, _resource, %{subscription: s}), do: s.id
  defp argument_value(:dunning_renewal_attempt_id, _resource, _fixtures), do: nil
  defp argument_value(:recovery_renewal_attempt_id, _resource, _fixtures), do: nil
  defp argument_value(:after_id, _resource, _fixtures), do: nil
  defp argument_value(:after_inserted_at, _resource, _fixtures), do: nil
  defp argument_value(:after_updated_at, _resource, _fixtures), do: nil
  defp argument_value(:after_boundary_at, _resource, _fixtures), do: nil
  defp argument_value(:as_of, _resource, _fixtures), do: now()
  defp argument_value(:now, _resource, _fixtures), do: now()
  defp argument_value(:through_inserted_at, _resource, _fixtures), do: now()
  defp argument_value(:through_updated_at, _resource, _fixtures), do: now()
  defp argument_value(:limit, _resource, _fixtures), do: 10
  defp argument_value(:source_version, _resource, _fixtures), do: 1
  defp argument_value(:expected_epoch, _resource, _fixtures), do: 1
  defp argument_value(:key, _resource, %{plan: p}), do: p.key
  defp argument_value(name, _resource, _fixtures), do: raise("unmapped required argument #{inspect(name)}")

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp create_pending_attempt!(subscription) do
    attrs = %{subscription_id: subscription.id,
      period_start_at: subscription.current_period_start_at,
      period_end_at: subscription.current_period_end_at,
      renewal_key: "jc258_matrix_#{Ash.UUIDv7.generate()}"}
    RenewalAttempt
    |> Ash.Changeset.for_create(:create_or_reuse, attrs, context: %{system?: true})
    |> Ash.create!(domain: Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp payment_intent_for_order!(order_id) do
    query = Ash.Query.filter(PaymentIntent, expr(order_id == ^order_id))
    Ash.read_one!(query, domain: Store.Payments, authorize?: false)
  end

  defp preflight_subject(resource, action, args, fixtures) do
    action_type = Ash.Resource.Info.action(resource, action).type

    cond do
      resource == Subscription and action in [:read_for_user, :get_for_user] ->
        {fixtures.subscription, action, args}
      resource == Subscription and action_type == :update ->
        {fixtures.subscription, action, args}
      resource == StoredPaymentMethod and action_type == :update ->
        {fixtures.stored_method, action, args}
      resource == StoredPaymentMethod and action == :read ->
        {fixtures.stored_method, action, args}
      resource == StoredPaymentMethod and action == :get_for_system ->
        {StoredPaymentMethod, action, args}
      action_type == :update ->
        {struct(resource), action, args}
      action_type == :destroy ->
        {struct(resource), action, args}
      true ->
        {resource, action, args}
    end
  end

  defp input_validity(resource, action, args, actor, context, fixtures) do
    action_info = Ash.Resource.Info.action(resource, action)
    subject =
      case action_info.type do
        :read -> Ash.Query.for_read(resource, action, args, actor: actor, context: context)
        :create -> Ash.Changeset.for_create(resource, action, args, actor: actor, context: context)
        :update ->
          Ash.Changeset.for_update(update_record(resource, fixtures), action, args,
            actor: actor, context: context)
        :action -> Ash.ActionInput.for_action(resource, action, args, actor: actor, context: context)
        :destroy ->
          Ash.Changeset.for_destroy(struct(resource), action, args, actor: actor, context: context)
      end

    %{valid?: subject.valid?, error_classes: error_classes(Map.get(subject, :errors, []))}
  end

  defp update_record(Subscription, fixtures), do: fixtures.subscription
  defp update_record(StoredPaymentMethod, fixtures), do: fixtures.stored_method
  defp update_record(resource, _fixtures), do: struct(resource)

  defp error_classes(errors) do
    errors
    |> Enum.map(fn
      %{__struct__: module} -> module
      _ -> :non_struct_error
    end)
    |> MapSet.new()
  end

  defp assert_input_validity!(%{valid?: false, error_classes: errors}, resource, action, context_name) do
    key = {resource, action}

    if action in [:read_for_user, :get_for_user] and context_name in [:anonymous, :system] do
      assert errors == MapSet.new([Ash.Error.Query.ReadActionRequiresActor]),
        "#{inspect(key)} #{context_name} actor contract had #{inspect(errors)}"
    else
      assert Map.fetch!(@expected_invalid_input_errors, key) == errors,
        "#{inspect(key)} #{context_name} invalid input classes changed to #{inspect(errors)}"
    end
  end

  defp assert_input_validity!(%{valid?: true}, resource, action, _context_name) do
    refute Map.has_key?(@expected_invalid_input_errors, {resource, action}),
      "#{inspect({resource, action})} became valid; review and update the explicit validity contract"
  end

  defp assert_current_preflight!(result, group, authority, action, context_name) do
    expected = expected_result(group, context_name)
    if group == :self_read and context_name in [:anonymous, :system] do
      assert match?({:error, %Ash.Error.Invalid{}}, result),
        "#{inspect(action)} #{context_name} #{authority} CURRENT_POLICY_PREFLIGHT expected actor-required error, got #{inspect(result)}"
      assert nested_error?(elem(result, 1), Ash.Error.Query.ReadActionRequiresActor),
        "#{inspect(action)} #{context_name} #{authority} CURRENT_POLICY_PREFLIGHT lacked nested ReadActionRequiresActor, got #{inspect(result)}"
    else
      assert result == expected,
        "#{inspect(action)} #{context_name} #{authority} CURRENT_POLICY_PREFLIGHT expected #{inspect(expected)}, got #{inspect(result)}"
    end
  end

  defp nested_error?(%{__struct__: module}, module), do: true
  defp nested_error?(%{errors: errors}, expected),
    do: Enum.any?(errors, &nested_error?(&1, expected))
  defp nested_error?(_error, _expected), do: false

  defp expected_result(:public_read, _), do: {:ok, true}
  defp expected_result(:staff_read, name), do: {:ok, name in [:support, :admin, :super_admin, :system]}
  defp expected_result(:admin_write, name), do: {:ok, name in [:admin, :super_admin, :system]}
  defp expected_result(:admin_or_system_write, name), do: {:ok, name in [:admin, :super_admin, :system]}
  defp expected_result(:self_or_admin_write, name), do: {:ok, name in [:owner_customer, :admin, :super_admin, :system]}
  defp expected_result(:system_only, name), do: {:ok, name == :system}
  defp expected_result(:system_only_action, name), do: {:ok, name == :system}
  defp expected_result(:self_read, :owner_customer), do: {:ok, true}
  defp expected_result(:self_read, _), do: {:ok, false}
  defp expected_result(:owner_or_staff_read, name) when name in [:owner_customer, :non_owner_customer, :editor], do: {:ok, :maybe}
  defp expected_result(:owner_or_staff_read, name), do: {:ok, name in [:support, :admin, :super_admin, :system]}

  defp assert_direct_method_result!({:error, %Ash.Error.Forbidden{}}, _action, :anonymous, _method), do: :ok

  defp assert_direct_method_result!({:ok, rows}, _action, name, method) when is_list(rows) and name != :anonymous do
    expected_count = if name in [:owner_customer, :support, :admin, :super_admin, :system], do: 1, else: 0
    assert length(rows) == expected_count
    if expected_count == 1, do: assert(hd(rows).id == method.id)
  end
  defp assert_direct_method_result!(other, action, name, _method), do: flunk("#{inspect(action)} #{name} unexpected direct read result: #{inspect(other)}")
end
```

The module is complete source for the audit test. It keeps a real method, pending renewal attempt, and payment intent from existing fixtures. The pending attempt uses the diagnostic-proven required fields and current subscription period. Every ID argument comes from a persisted resource. The public-plan test asserts only the action's active-status query filter and current actor behavior. It records the editor allowance as `MATRIX_DISCREPANCY` because the matrix explicitly says editor NO. It does not claim that an active plan is sellable for a variant.

The module pins each expected invalid subject to its exact error-module set from the corrected probe. Actor-required nil user reads are checked against `Ash.Error.Query.ReadActionRequiresActor` separately. Every other action must build a valid query/input/changeset unless it appears in the explicit invalid map; any new invalid action or changed error class fails the focused test.

The owner/non-owner self-read expectations are source-backed and match the corrected preflight: owner true; non-owner, support, editor, admin, and super_admin false; anonymous and system contexts produce `Ash.Error.Query.ReadActionRequiresActor`. These are `CURRENT_POLICY_PREFLIGHT` observations. A true is not an executable authorization claim. Actions with no canonical row remain `NEEDS_PRODUCT_DECISION`. Current admin writes on unlisted resources are deny-by-default conflict candidates. Subscription/RenewalAttempt SYSTEM-only mismatches remain audit candidates.

The direct `StoredPaymentMethod.read` and `get_for_system` results match the bounded diagnostic: owner, support, admin, super_admin, and system return the exact row; non-owner and editor return an empty list; anonymous returns `%Ash.Error.Forbidden{}`. The preflight remains `:maybe` for owner, non-owner, and editor on both actions. The test records those values as `CURRENT_POLICY_PREFLIGHT` and uses the direct read for row visibility. No `LIMITED` field list is inferred.

## Commands and evidence capture

Use every command exactly through DevCore with the required environment prefix. Run each as a separate shell invocation and capture output plus the command's actual exit code immediately. A local shell helper may use a temporary ignored log path, `set +e`, execute the command, store `$?`, print the code, and exit with that same code. Never print credentials. Stop if DevCore reports bootstrap or service failure; do not fall back to direct Mix.

Focused module:

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix test test/store/governance/jc258_action_policy_inventory_audit_test.exs
```

Format check:

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix format --check-formatted
```

Positional strict Credo check:

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix credo --strict test/store/governance/jc258_action_policy_inventory_audit_test.exs
```

Warnings-as-errors compile check:

```bash
MIX_ENV=test STORE_TEST_DB_SUFFIX=_t3_132f19be_hardening STORE_BENCH_POOL_SIZE=4 STORE_BENCH_WRITER_POOL_SIZE=4 ERL_FLAGS='+S 4:4' mise exec -- devcore-project run test -- mix compile --warnings-as-errors
```

Run `mix format` only if the format check fails, then repeat the format check and all checks affected by the edit. Do not report a check as passing without a zero exit status observed in its captured output.

## Review limits

Review this test against the exact current branch and its compiled action list. Confirm all 92 actions appear once, the two review-stack-only names are present because they compile here, all canonical labels are explicit, and no expected group is generated from the policies under test. Confirm every direct row test uses its own persisted record ID and distinguishes forbidden from filtered empty results. Confirm no setup intent, provider call, production policy mutation, matrix edit, fixture module edit, or global cleanup was added. No CI or merge recommendation is included in this plan.

## Root preflight before implementation

The root reviewed the complete proposed module and ran it from an ignored scratch test file through DevCore. All six tests passed with exit code 0, including the 92-action drift guard, 47 facade names, all 736 policy preflight cells, direct ownership and method reads, and active-plan filtering. The scratch filename emitted a test-load-filter warning. The committed test filename below matches the repository test naming rule. This diagnostic does not replace verification of the final tracked file or exact-head review.
