defmodule Store.Support.Governance.SurfaceRegistry do
  @moduledoc """
  Authoritative registry of allowed public facade surfaces for governance checks.
  """

  @consumer_suffix_pattern ~r/_for_(public|user|admin|support|system)$/

  @registry %{
    Store.Orders.Facade => %{
      allowed_consumers: [:user, :admin],
      exports: [
        {:list_orders_for_user, 2},
        {:list_orders_for_admin, 2},
        {:get_order_for_user, 2},
        {:get_order_for_admin, 2},
        {:get_order_detail_for_user, 2}
      ]
    },
    Store.Payments.Facade => %{
      allowed_consumers: [:admin, :system],
      exports: [
        {:list_payment_intents_for_admin, 2},
        {:get_payment_intent_for_admin, 2},
        {:observe_payment_intent_for_system, 1},
        {:apply_observed_payment_outcome_for_system, 1},
        {:record_and_apply_payment_observation_for_system, 2},
        {:renewal_payment_application_status_for_system, 1},
        {:serialize_renewal_payment_application_for_system, 1},
        {:serialize_renewal_order_payment_application_for_system, 1},
        {:request_renewal_cancellation_remediation_for_system, 1},
        {:ingest_webhook_receipt_for_system, 1},
        {:get_webhook_receipt_for_system, 1},
        {:process_payment_webhook_receipt_for_system, 1},
        {:process_refund_webhook_receipt_for_system, 1},
        {:purge_expired_webhook_evidence_for_system, 0},
        {:purge_expired_webhook_evidence_for_system, 1}
      ]
    },
    Store.Pricing.Facade => %{
      allowed_consumers: [:admin],
      exports: [
        {:list_shipping_zones_for_admin, 2},
        {:get_shipping_zone_for_admin, 2},
        {:create_shipping_zone_for_admin, 3},
        {:update_shipping_zone_for_admin, 4},
        {:list_shipping_rates_for_admin, 2},
        {:get_shipping_rate_for_admin, 2},
        {:list_tax_rates_for_admin, 2},
        {:get_tax_rate_for_admin, 2}
      ]
    },
    Store.Catalog.Facade => %{
      allowed_consumers: [:public, :admin],
      exports: [
        {:list_products_for_public, 2},
        {:list_product_cards_for_public, 2},
        {:get_product_for_public, 2},
        {:get_product_detail_for_public, 2},
        {:normalize_cart_line_for_public, 1},
        {:list_products_for_admin, 2},
        {:get_product_for_admin, 2},
        {:publish_product_for_admin, 2},
        {:unpublish_product_for_admin, 2},
        {:archive_product_for_admin, 2},
        {:list_product_options_for_admin, 2},
        {:create_product_option_for_admin, 3},
        {:update_product_option_for_admin, 3},
        {:delete_product_option_for_admin, 2},
        {:create_product_option_value_for_admin, 3},
        {:update_product_option_value_for_admin, 3},
        {:delete_product_option_value_for_admin, 2},
        {:list_variants_for_admin, 2},
        {:list_variant_selections_for_admin, 2},
        {:create_variant_for_admin, 3},
        {:update_variant_for_admin, 3},
        {:archive_variant_for_admin, 2},
        {:delete_variant_for_admin, 2},
        {:set_variant_selection_for_admin, 4},
        {:delete_variant_selection_for_admin, 2}
      ]
    },
    Store.Carts.Facade => %{
      allowed_consumers: [:user],
      exports: [
        {:get_cart_for_user, 2},
        {:get_cart_view_for_user, 3},
        {:add_item_for_user, 3},
        {:update_item_qty_for_user, 3},
        {:remove_item_for_user, 3},
        {:merge_token_into_user_for_user, 2}
      ]
    },
    Store.Shipping.Facade => %{
      allowed_consumers: [:admin, :system],
      exports: [
        {:list_shipping_zones_for_admin, 2},
        {:get_shipping_zone_for_admin, 2},
        {:create_shipping_zone_for_admin, 3},
        {:update_shipping_zone_for_admin, 4},
        {:list_shipping_methods_for_admin, 2},
        {:get_shipping_method_for_admin, 2},
        {:create_shipping_method_for_admin, 3},
        {:update_shipping_method_for_admin, 4},
        {:list_shipping_rate_rules_for_admin, 2},
        {:get_shipping_rate_rule_for_admin, 2},
        {:create_shipping_rate_rule_for_admin, 3},
        {:update_shipping_rate_rule_for_admin, 4},
        {:quote_options_for_system, 1},
        {:quote_options_for_system, 2}
      ]
    },
    Store.Fulfillment.Facade => %{
      allowed_consumers: [:admin, :support, :system],
      exports: [
        {:list_fulfillment_orders_for_admin, 2},
        {:get_fulfillment_order_for_admin, 2},
        {:mark_packed_for_support, 2},
        {:mark_shipped_for_support, 3},
        {:mark_delivered_for_support, 2},
        {:cancel_fulfillment_for_admin, 2},
        {:cancel_fulfillment_for_admin, 3},
        {:ensure_paid_order_fulfillment_for_system, 1},
        {:enqueue_paid_order_fulfillment_for_system, 1},
        {:get_fulfillment_by_order_id_for_system, 1}
      ]
    },
    Store.Comms.Facade => %{
      allowed_consumers: [:admin],
      exports: [
        {:list_email_outboxes_for_admin, 2},
        {:get_email_outbox_for_admin, 2}
      ]
    },
    Store.Digital.Facade => %{
      allowed_consumers: [:admin, :user, :system],
      exports: [
        {:list_digital_assets_for_admin, 2},
        {:get_digital_asset_for_admin, 2},
        {:list_product_digital_links_for_admin, 2},
        {:get_product_digital_link_for_admin, 2},
        {:list_download_grants_for_user, 2},
        {:issue_signed_download_url_for_user, 2},
        {:issue_signed_download_url_for_user, 3},
        {:ensure_paid_order_download_grants_for_system, 1},
        {:enqueue_paid_order_download_grants_for_system, 1},
        {:order_has_digital_assets_for_system, 1},
        {:ensure_checkout_actor_allowed_for_system, 2},
        {:apply_refund_revocation_for_system, 1}
      ]
    },
    Store.Subscriptions.Facade => %{
      allowed_consumers: [:admin, :user, :system],
      exports: [
        {:list_subscriptions_for_user, 2},
        {:get_subscription_for_user, 2},
        {:get_subscription_detail_for_user, 2},
        {:cancel_subscription_for_user, 2},
        {:cancel_subscription_for_user, 3},
        {:queue_subscription_plan_change_for_user, 3},
        {:queue_subscription_variant_change_for_user, 3},
        {:start_subscription_payment_method_update_for_user, 3},
        {:list_subscriptions_for_admin, 2},
        {:get_subscription_for_admin, 2},
        {:get_subscription_detail_for_admin, 2},
        {:cancel_subscription_for_admin, 2},
        {:cancel_subscription_for_admin, 3},
        {:queue_subscription_plan_change_for_admin, 3},
        {:queue_subscription_variant_change_for_admin, 3},
        {:start_subscription_payment_method_update_for_admin, 3},
        {:resolve_variant_subscription_plan_for_system, 1},
        {:resolve_variant_subscription_plan_for_system, 2},
        {:list_variant_subscription_plan_options_for_system, 1},
        {:list_variant_subscription_plan_options_for_system, 2},
        {:order_has_subscription_lines_for_system, 1},
        {:order_is_subscription_only_for_system, 1},
        {:create_subscriptions_from_paid_order_for_system, 1},
        {:ensure_membership_purchase_allowed_for_system, 2},
        {:handle_payment_method_update_succeeded_for_system, 1},
        {:list_due_renewal_jobs_for_system, 0},
        {:list_due_renewal_jobs_for_system, 1},
        {:list_due_renewal_job_page_for_system, 0},
        {:list_due_renewal_job_page_for_system, 1},
        {:process_due_subscription_renewal_for_system, 1},
        {:process_due_subscription_renewal_for_system, 2},
        {:validate_complete_bound_renewal_attempt_for_system, 1},
        {:reconcile_paid_subscription_renewal_for_system, 1},
        {:reconcile_paid_subscription_renewal_for_system, 2},
        {:run_due_renewals_for_system, 0},
        {:run_due_renewals_for_system, 1},
        {:run_due_failed_payment_suspensions_for_system, 0},
        {:run_due_failed_payment_suspensions_for_system, 1},
        {:run_due_scheduled_cancellations_for_system, 0},
        {:run_due_scheduled_cancellations_for_system, 1},
        {:replay_scheduled_cancellation_notifications_for_system, 0},
        {:replay_scheduled_cancellation_notifications_for_system, 1},
        {:list_past_due_missing_failed_payment_boundary_for_system, 0},
        {:list_past_due_missing_failed_payment_boundary_for_system, 1},
        {:execute_suspension_access_effect_for_system, 1},
        {:execute_effective_access_effect_for_system, 1},
        {:repair_suspension_access_effect_projection_for_system, 1},
        {:run_subscription_access_effect_recovery_for_system, 0},
        {:run_subscription_access_effect_recovery_for_system, 1},
        {:run_access_effect_target_order_reconciliation_for_system, 0},
        {:run_access_effect_target_order_reconciliation_for_system, 1},
        {:establish_access_effect_for_system, 1},
        {:get_current_access_effect_for_system, 1},
        {:mark_access_effect_pending_for_system, 1},
        {:mark_access_effect_applied_for_system, 1},
        {:mark_access_effect_failed_retryable_for_system, 1},
        {:retry_access_effect_for_system, 1}
      ]
    },
    Store.Entitlements.Facade => %{
      allowed_consumers: [:admin, :user, :system],
      exports: [
        {:list_entitlements_for_user, 2},
        {:entitlement_set_for_user, 1},
        {:issue_subscription_entitlement_for_system, 2},
        {:issue_subscription_source_grant_strict_for_system, 2},
        {:revoke_subscription_entitlements_for_system, 1},
        {:revoke_subscription_entitlements_for_system, 2},
        {:revoke_subscription_source_grants_strict_for_system, 2},
        {:invalidate_subscription_source_users_after_commit_for_system, 2},
        {:converge_subscription_source_grants_for_system, 1}
      ]
    }
  }

  @type facade_export :: {atom(), arity()}

  @spec registry() :: %{module() => [facade_export()]}
  def registry, do: @registry

  @spec allowed_exports(module()) :: [facade_export()]
  def allowed_exports(module) when is_atom(module) do
    @registry
    |> Map.get(module, %{exports: []})
    |> Map.get(:exports, [])
  end

  @spec allowed_consumers(module()) :: [atom()]
  def allowed_consumers(module) when is_atom(module) do
    @registry
    |> Map.get(module, %{allowed_consumers: []})
    |> Map.get(:allowed_consumers, [])
  end

  @spec facade_modules() :: [module()]
  def facade_modules, do: Map.keys(@registry)

  @spec consumer_surface?({atom(), arity()}) :: boolean()
  def consumer_surface?({name, _arity}) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.match?(@consumer_suffix_pattern)
  end

  @spec consumer_surface?(module(), {atom(), arity()}) :: boolean()
  def consumer_surface?(module, {name, _arity}) when is_atom(module) and is_atom(name) do
    case extract_consumer(name) do
      {:ok, consumer} -> consumer in allowed_consumers(module)
      :error -> false
    end
  end

  defp extract_consumer(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.split("_for_")
    |> case do
      [_prefix, consumer] -> {:ok, String.to_atom(consumer)}
      _ -> :error
    end
  end
end
