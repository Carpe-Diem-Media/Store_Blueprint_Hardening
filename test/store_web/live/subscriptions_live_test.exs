defmodule StoreWeb.SubscriptionsLiveTest do
  use StoreWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AshAuthentication.Plug.Helpers
  alias Store.Entitlements.{Cache, EntitlementGrant, Facade}
  alias Store.Entitlements.Types.EntitlementSet
  alias Store.SubscriptionsFixtures
  alias Store.TestFixtures
  alias Store.TestSupport.StripeAPIStub
  alias StoreWeb.SubscriptionsLive.Index

  @max_schedule_chunk_ms 86_400_000

  setup context do
    previous = Application.get_env(:store, :payments, [])
    StripeAPIStub.setup_default(context)

    Application.put_env(:store, :payments,
      enabled_providers: [:stripe],
      stripe: [
        webhook_secret: "whsec_test_only_change_me",
        secret_key: "sk_test_live_subscriptions",
        publishable_key: "pk_test_live_subscriptions",
        request_options: StripeAPIStub.req_options()
      ]
    )

    on_exit(fn ->
      Application.put_env(:store, :payments, previous)
    end)

    :ok
  end

  test "account subscription detail queues plan changes inline and opens the card-update modal",
       %{
         conn: conn
       } do
    customer = signed_in_user(TestFixtures.unique_email("account_subscription_live"))
    conn = authenticated_conn(conn, customer)

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    current_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "live-current",
        name: "Live Current",
        amount_minor: 1_500
      })

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "live-target",
        name: "Live Target",
        amount_minor: 2_500
      })

    SubscriptionsFixtures.create_plan_revision!(target_plan)

    _current_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    _target_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_live_account_001",
        provider_billing_ref: "pm_live_account_001"
      })

    {:ok, view, html} = live(conn, ~p"/account/subscriptions/#{subscription.id}")

    assert html =~ "Current Renewal Price"
    assert html =~ "Update Card"

    updated_html =
      view
      |> form("form[phx-submit=\"queue_plan_change\"]", %{
        "queue_subscription_plan_change" => %{"subscription_plan_id" => target_plan.id}
      })
      |> render_submit()

    assert updated_html =~ "Plan change queued for the next successful renewal"
    assert updated_html =~ "USD 25.00"

    modal_html =
      view
      |> element("button[phx-click=\"start_payment_method_update\"]")
      |> render_click()

    assert modal_html =~ "pk_test_live_subscriptions"
    assert modal_html =~ "phx-hook=\"StripeElements\""
    assert modal_html =~ "Save Card"
  end

  test "admin subscription detail renders support-grade billing refs and queued-action controls",
       %{
         conn: conn
       } do
    admin = signed_in_user(TestFixtures.unique_email("admin_subscription_live"))
    _role = TestFixtures.assign_role!(admin, :admin)
    conn = authenticated_conn(conn, admin)

    customer = SubscriptionsFixtures.create_customer!("admin_subscription_customer")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    current_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "admin-current",
        name: "Admin Current",
        amount_minor: 1_500
      })

    target_plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "admin-target",
        name: "Admin Target",
        amount_minor: 2_500
      })

    _current_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, current_plan.id)
    _target_attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, target_plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, current_plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_admin_live_001",
        provider_billing_ref: "pm_admin_live_001"
      })

    {:ok, _view, html} = live(conn, ~p"/admin/subscriptions/#{subscription.id}")

    assert html =~ "Provider Customer Ref"
    assert html =~ "cus_admin_live_001"
    assert html =~ "Provider Billing Ref"
    assert html =~ "pm_admin_live_001"
    assert html =~ "Queue Plan Change"
    assert html =~ "Queue Variant Change"
    assert html =~ "Update Card"
  end

  test "support can read admin subscription detail without payment setup controls", %{conn: conn} do
    support = signed_in_user(TestFixtures.unique_email("support_subscription_live"))
    _role = TestFixtures.assign_role!(support, :support)
    conn = authenticated_conn(conn, support)

    customer = SubscriptionsFixtures.create_customer!("support_subscription_customer")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "support-current",
        name: "Support Current",
        amount_minor: 1_500
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe,
        provider_customer_ref: "cus_support_live_001",
        provider_billing_ref: "pm_support_live_001"
      })

    {:ok, _view, html} = live(conn, ~p"/admin/subscriptions/#{subscription.id}")

    assert html =~ "Provider Customer Ref"
    assert html =~ "cus_support_live_001"
    refute html =~ "Update Card"
    refute html =~ "start_payment_method_update"
  end

  test "authenticated non-admin is redirected away from admin subscriptions routes", %{conn: conn} do
    customer = signed_in_user(TestFixtures.unique_email("customer_admin_subscriptions_live"))
    conn = authenticated_conn(conn, customer)

    customer_record = SubscriptionsFixtures.create_customer!("non_admin_subscription_customer")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "non-admin-check",
        name: "Non Admin Check",
        amount_minor: 1_500
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer_record.id, variant, plan, %{
        provider: :stripe
      })

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/subscriptions")

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/admin/subscriptions/#{subscription.id}")
  end

  test "subscriptions index reacts to entitlement invalidation with a pushed event", %{conn: conn} do
    customer = signed_in_user(TestFixtures.unique_email("subscription_entitlement_live"))
    conn = authenticated_conn(conn, customer)

    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()

    plan =
      SubscriptionsFixtures.create_subscription_plan!(%{
        key: "membership-live",
        name: "Membership Live",
        entitlement_kind: :membership_access,
        entitlement_scope_key: "membership:live"
      })

    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan, %{
        provider: :stripe
      })

    assert {:ok, _grant} = Facade.issue_subscription_entitlement_for_system(subscription, plan)

    {:ok, view, html} = live(conn, ~p"/account/subscriptions")

    assert html =~ "membership:live"

    before_invalidation = live_assigns(view)
    old_timer_ref = Map.get(before_invalidation, :entitlement_boundary_timer_ref)
    old_generation = Map.get(before_invalidation, :entitlement_boundary_generation)
    old_boundary = Map.get(before_invalidation, :entitlement_boundary_at)

    assert is_reference(old_timer_ref)
    assert is_integer(old_generation)
    assert %DateTime{} = old_boundary

    assert {:ok, _revoked_count} =
             Facade.revoke_subscription_entitlements_for_system(
               subscription.id,
               "grace_expired"
             )

    assert_push_event(view, "membership_expired", %{reason: "grace_expired"})
    assert render(view) =~ "No active entitlements."

    after_invalidation = live_assigns(view)

    assert Map.get(after_invalidation, :entitlement_boundary_timer_ref) == nil
    assert Map.get(after_invalidation, :entitlement_boundary_at) == nil
    assert Map.get(after_invalidation, :entitlement_boundary_generation) > old_generation
    assert Process.read_timer(old_timer_ref) == false

    send(
      view.pid,
      {:timeout, old_timer_ref, {:entitlement_boundary, old_generation, old_boundary}}
    )

    assert live_assigns(view).entitlements == []

    assert {:ok, _grant} = Facade.issue_subscription_entitlement_for_system(subscription, plan)
    assert_push_event(view, "membership_expired", %{reason: "entitlement_issued"})

    after_replacement = live_assigns(view)
    replacement_timer_ref = Map.get(after_replacement, :entitlement_boundary_timer_ref)

    assert is_reference(replacement_timer_ref)
    assert replacement_timer_ref != old_timer_ref

    assert Map.get(after_replacement, :entitlement_boundary_generation) >
             Map.get(after_invalidation, :entitlement_boundary_generation)

    assert is_integer(Process.read_timer(replacement_timer_ref))
    assert Process.read_timer(old_timer_ref) == false

    send(
      view.pid,
      {:timeout, old_timer_ref, {:entitlement_boundary, old_generation, old_boundary}}
    )

    assert live_assigns(view).entitlement_boundary_timer_ref == replacement_timer_ref
    assert render(view) =~ "membership:live"
  end

  test "subscriptions index schedules no timer for an empty entitlement set", %{conn: conn} do
    customer = signed_in_user(TestFixtures.unique_email("subscription_no_entitlement_timer"))
    conn = authenticated_conn(conn, customer)

    {:ok, view, _html} = live(conn, ~p"/account/subscriptions")
    assigns = live_assigns(view)

    assert assigns.entitlements == []
    assert Map.get(assigns, :entitlement_boundary_timer_ref) == nil
    assert Map.get(assigns, :entitlement_boundary_at) == nil
  end

  test "a matching start boundary refreshes entitlements from the held set" do
    start_at = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:microsecond)
    grant = raw_grant(valid_from_at: start_at)
    set = raw_entitlement_set([grant])
    timer_ref = make_ref()
    generation = 4
    socket = timer_socket(set, [], timer_ref, generation, start_at)
    telemetry_ref = make_ref()
    parent = self()

    :telemetry.attach_many(
      "entitlement-boundary-test-#{inspect(telemetry_ref)}",
      [[:store, :repo, :query]],
      fn _event, _measurements, _metadata, _config ->
        send(parent, {:repo_query, telemetry_ref})
      end,
      nil
    )

    Phoenix.PubSub.subscribe(Store.PubSub, Cache.topic(set.user_id))

    callback_pid =
      spawn(fn ->
        receive do
          :run_boundary ->
            result =
              Index.handle_info(
                {:timeout, timer_ref, {:entitlement_boundary, generation, start_at}},
                socket
              )

            send(parent, {:boundary_result, self(), result})
            receive do: (:release_boundary -> :ok)
        end
      end)

    monitor_ref = Process.monitor(callback_pid)
    cachex_fetch_trace = trace_cachex_fetches(callback_pid)

    try do
      send(callback_pid, :run_boundary)

      assert_receive {:boundary_result, ^callback_pid, {:noreply, refreshed_socket}}

      trace_ref = :erlang.trace_delivered(callback_pid)
      assert_receive {:trace_delivered, ^callback_pid, ^trace_ref}

      assert refreshed_socket.assigns.entitlements == [grant]
      assert refreshed_socket.assigns.entitlement_boundary_timer_ref == nil
      assert refreshed_socket.assigns.entitlement_boundary_at == nil
      refute_receive {:repo_query, ^telemetry_ref}, 0
      refute_receive {:entitlements_invalidated, _, _, _}, 0
      assert cachex_fetch_count(cachex_fetch_trace) == 0

      send(callback_pid, :release_boundary)
      assert_receive {:DOWN, ^monitor_ref, :process, ^callback_pid, :normal}
    after
      stop_cachex_fetch_trace(cachex_fetch_trace)
      if Process.alive?(callback_pid), do: Process.exit(callback_pid, :kill)
      Process.demonitor(monitor_ref, [:flush])
      :telemetry.detach("entitlement-boundary-test-#{inspect(telemetry_ref)}")
    end
  end

  test "a matching end boundary removes the grant from the displayed projection" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end_at = DateTime.add(now, -10, :second)
    grant = raw_grant(valid_from_at: DateTime.add(end_at, -1, :second), valid_to_at: end_at)
    set = raw_entitlement_set([grant])
    timer_ref = make_ref()
    generation = 5
    socket = timer_socket(set, [grant], timer_ref, generation, end_at)

    assert {:noreply, refreshed_socket} =
             Index.handle_info(
               {:timeout, timer_ref, {:entitlement_boundary, generation, end_at}},
               socket
             )

    assert refreshed_socket.assigns.entitlements == []
    assert refreshed_socket.assigns.entitlement_boundary_timer_ref == nil
    assert refreshed_socket.assigns.entitlement_boundary_at == nil
  end

  test "a pre-boundary timer chunk re-arms locally at the one-day cap" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    boundary = DateTime.add(now, 3 * @max_schedule_chunk_ms, :millisecond)
    timer_ref = make_ref()
    generation = 6
    socket = timer_socket(nil, [:held_projection], timer_ref, generation, boundary)

    assert {:noreply, rearmed_socket} =
             Index.handle_info(
               {:timeout, timer_ref, {:entitlement_boundary, generation, boundary}},
               socket
             )

    next_timer_ref = rearmed_socket.assigns.entitlement_boundary_timer_ref
    on_exit(fn -> Process.cancel_timer(next_timer_ref) end)

    assert is_reference(next_timer_ref)
    assert next_timer_ref != timer_ref
    assert rearmed_socket.assigns.entitlements == [:held_projection]
    assert rearmed_socket.assigns.entitlement_boundary_at == boundary

    remaining_ms = Process.read_timer(next_timer_ref)

    assert is_integer(remaining_ms)
    assert remaining_ms > 0
    assert remaining_ms <= @max_schedule_chunk_ms
  end

  test "stale timer reference and generation are ignored" do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    boundary = DateTime.add(now, 60, :second)
    current_ref = make_ref()
    current_generation = 9
    stale_ref = make_ref()
    socket = timer_socket(nil, [:held_projection], current_ref, current_generation, boundary)

    assert {:noreply, unchanged_socket} =
             Index.handle_info(
               {:timeout, stale_ref, {:entitlement_boundary, current_generation, boundary}},
               socket
             )

    assert unchanged_socket == socket

    assert {:noreply, unchanged_socket} =
             Index.handle_info(
               {:timeout, current_ref, {:entitlement_boundary, current_generation - 1, boundary}},
               socket
             )

    assert unchanged_socket == socket
  end

  defp authenticated_conn(conn, user) do
    conn
    |> init_test_session(%{})
    |> Helpers.store_in_session(user)
  end

  defp signed_in_user(email) do
    _registered = TestFixtures.register_user!(email: email)
    TestFixtures.sign_in_user!(email)
  end

  defp live_assigns(view) do
    %{socket: socket} = :sys.get_state(view.pid)
    socket.assigns
  end

  defp timer_socket(entitlement_set, entitlements, timer_ref, generation, boundary) do
    %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{
        __changed__: %{},
        entitlement_set: entitlement_set,
        entitlements: entitlements,
        entitlement_boundary_timer_ref: timer_ref,
        entitlement_boundary_generation: generation,
        entitlement_boundary_at: boundary
      }
    }
  end

  defp trace_cachex_fetches(pid) do
    assert :erlang.trace_pattern({Cachex, :fetch, 4}, true, [:global]) > 0
    assert :erlang.trace(pid, true, [:call]) == 1
    pid
  end

  defp stop_cachex_fetch_trace(pid) do
    if Process.alive?(pid), do: :erlang.trace(pid, false, [:call])

    :erlang.trace_pattern({Cachex, :fetch, 4}, false, [:global])
  end

  defp cachex_fetch_count(pid), do: collect_cachex_fetch_trace(pid, 0)

  defp collect_cachex_fetch_trace(pid, count) do
    receive do
      {:trace, ^pid, :call, {Cachex, :fetch, _args}} ->
        collect_cachex_fetch_trace(pid, count + 1)
    after
      0 ->
        count
    end
  end

  defp raw_entitlement_set(grants) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %EntitlementSet{
      user_id: "user-1",
      grants: grants,
      fetched_at: now,
      expires_at: DateTime.add(now, 60, :second)
    }
  end

  defp raw_grant(attrs) do
    defaults = [
      kind: :membership_access,
      scope_key: "membership:timer",
      status: :active,
      revoked_at: nil,
      valid_from_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      valid_to_at: nil
    ]

    struct!(EntitlementGrant, Keyword.merge(defaults, attrs))
  end
end
