defmodule Store.Subscriptions.PlanRevisionTest do
  use Store.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  import Ash.Expr
  require Ash.Query

  alias Store.Subscriptions.{PlanRevision, Subscription}
  alias Store.SubscriptionsFixtures

  @commercial_attrs %{
    interval_unit: :month,
    interval_count: 1,
    currency: "USD",
    amount_minor: 1_999,
    anchor_mode: :start_anniversary,
    billing_timezone: "Etc/UTC",
    term_mode: :until_canceled,
    access_on_past_due: :keep_during_grace,
    access_on_cancel: :keep_until_period_end,
    grace_period_days: 7,
    max_retry_attempts: 3,
    retry_schedule_hours: [0, 24, 72]
  }

  setup do
    plan = SubscriptionsFixtures.create_subscription_plan!()
    %{plan: plan}
  end

  test "create_draft persists plan FK and complete commercial contract", %{plan: plan} do
    revision = create_draft!(plan, @commercial_attrs)

    assert revision.subscription_plan_id == plan.id
    assert revision.status == :draft
    assert revision.version == 1
    assert revision.amount_minor == 1_999
    assert revision.currency == "USD"
    assert revision.interval_unit == :month
    assert revision.interval_count == 1
    assert revision.max_retry_attempts == 3
    assert revision.retry_schedule_hours == [0, 24, 72]
  end

  test "create_draft uses the commercial timezone default when omitted", %{plan: plan} do
    revision = create_draft!(plan, Map.delete(@commercial_attrs, :billing_timezone))

    assert revision.billing_timezone == "Africa/Johannesburg"
  end

  test "draft creation and updates reject invalid timezones and accept trimmed supported zones",
       %{
         plan: plan
       } do
    for timezone <- [nil, "", "Not/A_Real_Zone"] do
      attrs = Map.put(@commercial_attrs, :billing_timezone, timezone)
      assert {:error, error} = create_draft(plan, attrs)
      assert billing_timezone_error?(error)
    end

    revision = create_draft!(plan, @commercial_attrs)

    for timezone <- [nil, "", "Not/A_Real_Zone"] do
      assert_raise Ash.Error.Invalid, fn ->
        update_draft!(revision, %{billing_timezone: timezone})
      end
    end

    updated = update_draft!(revision, %{billing_timezone: "  Africa/Johannesburg  "})
    assert updated.billing_timezone == "Africa/Johannesburg"
  end

  test "publish rejects a historical draft with an invalid timezone", %{plan: plan} do
    revision = create_draft!(plan, @commercial_attrs)

    Store.Repo.query!(
      "UPDATE plan_revisions SET billing_timezone = $1 WHERE id = $2",
      ["Not/A_Real_Zone", Ecto.UUID.dump!(revision.id)]
    )

    assert {:error, error} = publish(reload_revision!(revision.id))
    assert billing_timezone_error?(error)

    assert %{status: :draft, version: 1, billing_timezone: "Not/A_Real_Zone"} =
             reload_revision!(revision.id)
  end

  test "publish rejects a zone unsupported by the current timezone database", %{plan: plan} do
    revision = create_draft!(plan, %{@commercial_attrs | billing_timezone: "Africa/Johannesburg"})
    previous_database = Application.get_env(:elixir, :time_zone_database)

    try do
      Application.put_env(:elixir, :time_zone_database, Calendar.UTCOnlyTimeZoneDatabase)

      assert {:error, error} = publish(reload_revision!(revision.id))
      assert billing_timezone_error?(error)
      assert %{status: :draft, version: 1} = reload_revision!(revision.id)
    after
      if is_nil(previous_database) do
        Application.delete_env(:elixir, :time_zone_database)
      else
        Application.put_env(:elixir, :time_zone_database, previous_database)
      end
    end
  end

  test "status cannot be supplied to create an effective or retired revision", %{plan: plan} do
    for status <- [:effective, :retired] do
      assert {:error, error} =
               PlanRevision
               |> Ash.Changeset.for_create(
                 :create_draft,
                 Map.merge(@commercial_attrs, %{
                   subscription_plan_id: plan.id,
                   status: status
                 }),
                 context: %{system?: true}
               )
               |> Ash.create(
                 domain: Store.Subscriptions,
                 authorize?: false,
                 context: %{system?: true}
               )

      assert [%Ash.Error.Invalid.NoSuchInput{input: :status, action: :create_draft}] =
               invalid_errors(error)
    end

    assert reload_drafts_for_plan!(plan.id) == []
  end

  test "draft commercial edit succeeds and advances optimistic version", %{plan: plan} do
    revision = create_draft!(plan, @commercial_attrs)

    updated =
      update_draft!(revision, %{amount_minor: 2_499, currency: "usd", billing_timezone: "Etc/UTC"})

    assert updated.amount_minor == 2_499
    assert updated.currency == "USD"
    assert updated.version == revision.version + 1
    assert reload_revision!(revision.id).amount_minor == 2_499
  end

  test "draft to effective succeeds", %{plan: plan} do
    revision = create_draft!(plan, @commercial_attrs)
    published = publish!(revision)

    assert published.status == :effective
    assert published.version == revision.version + 1
    assert reload_revision!(revision.id).status == :effective
  end

  test "effective selector fails closed when no revision is effective", %{plan: plan} do
    draft = create_draft!(plan, @commercial_attrs)

    assert {:error, error} = effective_for_plan(plan.id)
    assert not_found_error?(error)

    retired = retire!(publish!(draft))

    assert retired.status == :retired
    assert {:error, error} = effective_for_plan(plan.id)
    assert not_found_error?(error)
  end

  test "effective selector returns the exact effective revision identity", %{plan: plan} do
    _retired = retire!(publish!(create_draft!(plan, %{@commercial_attrs | amount_minor: 1_111})))
    effective = publish!(create_draft!(plan, %{@commercial_attrs | amount_minor: 2_222}))
    _draft = create_draft!(plan, %{@commercial_attrs | amount_minor: 3_333})

    assert {:ok, selected} = effective_for_plan(plan.id)
    assert selected.id == effective.id
    assert selected.status == :effective
  end

  test "effective selector does not fall back to incidental historical order", %{plan: plan} do
    _draft = create_draft!(plan, %{@commercial_attrs | amount_minor: 1_111})
    _retired = retire!(publish!(create_draft!(plan, %{@commercial_attrs | amount_minor: 2_222})))
    _newer_draft = create_draft!(plan, %{@commercial_attrs | amount_minor: 3_333})

    assert {:error, error} = effective_for_plan(plan.id)
    assert not_found_error?(error)
  end

  test "sequential second publication is rejected by the one-effective invariant", %{plan: plan} do
    first = create_draft!(plan, %{@commercial_attrs | amount_minor: 1_111})
    second = create_draft!(plan, %{@commercial_attrs | amount_minor: 2_222})

    assert {:ok, published_first} = publish(first)
    assert {:error, error} = publish(second)
    assert effective_uniqueness_error?(error)

    assert reload_revision!(published_first.id).status == :effective
    assert reload_revision!(second.id).status == :draft
    assert effective_count!(plan.id) == 1
  end

  test "different plans may each publish one effective revision", %{plan: plan} do
    other_plan = SubscriptionsFixtures.create_subscription_plan!()
    first = publish!(create_draft!(plan, @commercial_attrs))
    second = publish!(create_draft!(other_plan, %{@commercial_attrs | amount_minor: 2_222}))

    assert first.id != second.id
    assert effective_count!(plan.id) == 1
    assert effective_count!(other_plan.id) == 1
    assert first.subscription_plan_id != second.subscription_plan_id
  end

  test "retirement releases the effective slot for a later publication", %{plan: plan} do
    first = publish!(create_draft!(plan, %{@commercial_attrs | amount_minor: 1_111}))
    retired = retire!(first)

    assert {:error, error} = effective_for_plan(plan.id)
    assert not_found_error?(error)

    second = publish!(create_draft!(plan, %{@commercial_attrs | amount_minor: 2_222}))

    assert {:ok, selected} = effective_for_plan(plan.id)
    assert selected.id == second.id
    assert reload_revision!(retired.id).status == :retired
  end

  test "competing publications on independent connections yield one winner", %{plan: _plan} do
    {race_plan_id, first_id, second_id} = create_committed_race_fixture!()

    try do
      parent = self()

      tasks =
        Enum.map([first_id, second_id], fn revision_id ->
          Task.async(fn ->
            Sandbox.unboxed_run(Store.Repo, fn ->
              send(parent, {:publication_ready, self()})

              receive do
                :publish ->
                  revision = reload_revision!(revision_id)
                  publish(revision)
              end
            end)
          end)
        end)

      ready_pids =
        Enum.map(tasks, fn _task ->
          assert_receive {:publication_ready, pid}, 5_000
          pid
        end)

      Enum.each(ready_pids, &send(&1, :publish))
      results = Enum.map(tasks, &Task.await(&1, 15_000))

      assert Enum.count(results, &match?({:ok, %PlanRevision{}}, &1)) == 1
      assert Enum.count(results, &match?({:error, _}, &1)) == 1
      assert effective_count_unboxed!(race_plan_id) == 1
    after
      delete_committed_race_fixture!(race_plan_id)
    end
  end

  test "effective commercial edit is rejected", %{plan: plan} do
    revision = publish!(create_draft!(plan, @commercial_attrs))

    assert {:error, error} =
             revision
             |> Ash.Changeset.for_update(:update_draft, %{amount_minor: 9_999},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert stale_or_filter_error?(error)
    assert reload_revision!(revision.id).amount_minor == 1_999
  end

  test "effective to retired succeeds", %{plan: plan} do
    revision = publish!(create_draft!(plan, @commercial_attrs))
    retired = retire!(revision)

    assert retired.status == :retired
    assert retired.version == revision.version + 1
    assert reload_revision!(revision.id).status == :retired
  end

  test "retired commercial edit is rejected", %{plan: plan} do
    revision = retire!(publish!(create_draft!(plan, @commercial_attrs)))

    assert {:error, error} =
             revision
             |> Ash.Changeset.for_update(:update_draft, %{amount_minor: 9_999},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert stale_or_filter_error?(error)
    assert reload_revision!(revision.id).amount_minor == 1_999
  end

  test "draft to retired is impossible", %{plan: plan} do
    revision = create_draft!(plan, @commercial_attrs)

    assert {:error, error} =
             revision
             |> Ash.Changeset.for_update(:retire, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert invalid_state_transition_error?(error)
    assert reload_revision!(revision.id).status == :draft
  end

  test "retired to effective is impossible", %{plan: plan} do
    revision = retire!(publish!(create_draft!(plan, @commercial_attrs)))

    assert {:error, error} =
             revision
             |> Ash.Changeset.for_update(:publish, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert invalid_state_transition_error?(error)
    assert reload_revision!(revision.id).status == :retired
  end

  test "stale draft edit after publish fails and durable row remains effective", %{plan: plan} do
    draft = create_draft!(plan, @commercial_attrs)
    stale_draft = draft

    published = publish!(draft)

    assert {:error, error} =
             stale_draft
             |> Ash.Changeset.for_update(:update_draft, %{amount_minor: 4_444},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert stale_record_error?(error)

    reloaded = reload_revision!(published.id)
    assert reloaded.status == :effective
    assert reloaded.amount_minor == 1_999
  end

  test "stale publisher after committed draft edit fails and draft keeps edited values", %{
    plan: plan
  } do
    draft = create_draft!(plan, @commercial_attrs)
    stale_publisher = draft

    edited = update_draft!(draft, %{amount_minor: 3_333})

    assert {:error, error} =
             stale_publisher
             |> Ash.Changeset.for_update(:publish, %{}, context: %{system?: true})
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert stale_record_error?(error)

    reloaded = reload_revision!(edited.id)
    assert reloaded.status == :draft
    assert reloaded.amount_minor == 3_333
    assert reloaded.version == edited.version
  end

  test "competing edits from the same version cannot both commit", %{plan: plan} do
    draft = create_draft!(plan, @commercial_attrs)
    stale = draft

    assert {:ok, winner} =
             draft
             |> Ash.Changeset.for_update(:update_draft, %{amount_minor: 2_100},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert {:error, error} =
             stale
             |> Ash.Changeset.for_update(:update_draft, %{amount_minor: 2_200},
               context: %{system?: true}
             )
             |> Ash.update(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert stale_record_error?(error)
    assert reload_revision!(winner.id).amount_minor == 2_100
  end

  test "mutable subscription plan changes after publication do not alter the revision", %{
    plan: plan
  } do
    revision = publish!(create_draft!(plan, %{@commercial_attrs | amount_minor: 1_500}))

    plan
    |> Ash.Changeset.for_update(
      :update,
      %{amount_minor: 9_999, currency: "EUR", interval_count: 12},
      context: %{system?: true}
    )
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    reloaded = reload_revision!(revision.id)
    assert reloaded.amount_minor == 1_500
    assert reloaded.currency == "USD"
    assert reloaded.interval_count == 1
  end

  test "multiple revisions for one plan remain distinct historical identities", %{plan: plan} do
    revision_a =
      retire!(
        publish!(
          create_draft!(plan, %{
            @commercial_attrs
            | amount_minor: 1_111,
              billing_timezone: "Etc/UTC"
          })
        )
      )

    revision_b = publish!(create_draft!(plan, %{@commercial_attrs | amount_minor: 2_222}))

    assert revision_a.id != revision_b.id
    assert reload_revision!(revision_a.id).amount_minor == 1_111
    assert reload_revision!(revision_a.id).status == :retired
    assert reload_revision!(revision_b.id).amount_minor == 2_222
    assert reload_revision!(revision_b.id).status == :effective
  end

  test "retired revision preserves commercial fields after a later revision is published", %{
    plan: plan
  } do
    retired =
      retire!(
        publish!(
          create_draft!(plan, %{
            @commercial_attrs
            | amount_minor: 1_111,
              grace_period_days: 14,
              billing_timezone: "Etc/UTC"
          })
        )
      )

    _later = publish!(create_draft!(plan, %{@commercial_attrs | amount_minor: 5_555}))

    reloaded = reload_revision!(retired.id)
    assert reloaded.status == :retired
    assert reloaded.amount_minor == 1_111
    assert reloaded.grace_period_days == 14
  end

  test "max_retry_attempts = 0 is accepted", %{plan: plan} do
    revision =
      create_draft!(plan, %{
        @commercial_attrs
        | max_retry_attempts: 0,
          retry_schedule_hours: []
      })

    assert revision.max_retry_attempts == 0
    assert revision.retry_schedule_hours == []
    assert reload_revision!(revision.id).max_retry_attempts == 0
  end

  test "invalid anchor, term, retry, and entitlement contract shapes are rejected", %{plan: plan} do
    assert {:error, _} =
             create_draft(
               plan,
               Map.merge(@commercial_attrs, %{
                 anchor_mode: :fixed_day_of_month,
                 anchor_day_of_month: nil
               })
             )

    assert {:error, _} =
             create_draft(
               plan,
               Map.merge(@commercial_attrs, %{
                 term_mode: :fixed_cycles,
                 term_cycles: nil
               })
             )

    assert {:error, _} =
             create_draft(
               plan,
               Map.merge(@commercial_attrs, %{
                 term_mode: :fixed_end_at,
                 term_end_at: nil
               })
             )

    assert {:error, _} =
             create_draft(
               plan,
               Map.merge(@commercial_attrs, %{
                 max_retry_attempts: 3,
                 retry_schedule_hours: [0]
               })
             )

    assert {:error, _} =
             create_draft(
               plan,
               Map.merge(@commercial_attrs, %{
                 entitlement_kind: :membership_access,
                 entitlement_scope_key: nil
               })
             )
  end

  test "FK prevents orphan plan revision creation" do
    assert {:error, error} =
             PlanRevision
             |> Ash.Changeset.for_create(
               :create_draft,
               Map.put(@commercial_attrs, :subscription_plan_id, Ash.UUID.generate()),
               context: %{system?: true}
             )
             |> Ash.create(
               domain: Store.Subscriptions,
               authorize?: false,
               context: %{system?: true}
             )

    assert fk_violation_error?(error)
  end

  test "unresolved legacy subscription remains unbound and unchanged as revisions churn", %{
    plan: plan
  } do
    customer = SubscriptionsFixtures.create_customer!("sbh_10_01_side_effect")
    %{variant: variant} = SubscriptionsFixtures.create_subscription_sellable!()
    _attachment = SubscriptionsFixtures.attach_variant_plan!(variant.id, plan.id)

    %{subscription: subscription, revision: initial_revision} =
      SubscriptionsFixtures.create_subscription_fixture!(customer.id, variant, plan)

    clear_plan_revision_binding!(subscription.id)
    before = subscription_snapshot!(subscription.id)
    assert is_nil(before.current_plan_revision_id)

    _retired_initial = retire!(initial_revision)
    revision = publish!(create_draft!(plan, @commercial_attrs))
    _retired = retire!(revision)
    _another = publish!(create_draft!(plan, %{@commercial_attrs | amount_minor: 4_321}))

    after_snapshot = subscription_snapshot!(subscription.id)
    assert before == after_snapshot
  end

  test "draft edit can clear optional entitlement kind and scope together", %{plan: plan} do
    revision =
      create_draft!(
        plan,
        Map.merge(@commercial_attrs, %{
          entitlement_kind: :membership_access,
          entitlement_scope_key: "premium"
        })
      )

    cleared =
      update_draft!(revision, %{entitlement_kind: nil, entitlement_scope_key: nil})

    assert cleared.entitlement_kind == nil
    assert cleared.entitlement_scope_key == nil

    reloaded = reload_revision!(revision.id)
    assert reloaded.entitlement_kind == nil
    assert reloaded.entitlement_scope_key == nil
  end

  defp create_draft!(plan, attrs) do
    attrs = Map.put(attrs, :subscription_plan_id, plan.id)

    PlanRevision
    |> Ash.Changeset.for_create(:create_draft, attrs, context: %{system?: true})
    |> Ash.create!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp create_draft(plan, attrs) do
    attrs = Map.put(attrs, :subscription_plan_id, plan.id)

    PlanRevision
    |> Ash.Changeset.for_create(:create_draft, attrs, context: %{system?: true})
    |> Ash.create(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp update_draft!(revision, attrs) do
    revision
    |> Ash.Changeset.for_update(:update_draft, attrs, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp publish(revision) do
    revision
    |> Ash.Changeset.for_update(:publish, %{}, context: %{system?: true})
    |> Ash.update(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp publish!(revision) do
    revision
    |> Ash.Changeset.for_update(:publish, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp retire!(revision) do
    revision
    |> Ash.Changeset.for_update(:retire, %{}, context: %{system?: true})
    |> Ash.update!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp reload_revision!(id) do
    PlanRevision
    |> Ash.Query.filter(expr(id == ^id))
    |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp reload_drafts_for_plan!(plan_id) do
    PlanRevision
    |> Ash.Query.filter(expr(subscription_plan_id == ^plan_id and status == :draft))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp effective_for_plan(plan_id) do
    PlanRevision.get_effective_for_plan(plan_id,
      authorize?: false,
      context: %{system?: true}
    )
  end

  defp effective_count!(plan_id) do
    PlanRevision
    |> Ash.Query.filter(expr(subscription_plan_id == ^plan_id and status == :effective))
    |> Ash.read!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
    |> length()
  end

  defp effective_count_unboxed!(plan_id) do
    Sandbox.unboxed_run(Store.Repo, fn ->
      %{rows: [[count]]} =
        Store.Repo.query!(
          "SELECT count(*) FROM plan_revisions WHERE subscription_plan_id = $1 AND status = 'effective'",
          [Ecto.UUID.dump!(plan_id)]
        )

      count
    end)
  end

  defp create_committed_race_fixture! do
    Sandbox.unboxed_run(Store.Repo, fn ->
      unique = Ecto.UUID.generate()

      plan =
        SubscriptionsFixtures.create_subscription_plan!(%{
          key: "SBH60RACE_#{unique}",
          name: "SBH-60-01 race #{unique}"
        })

      first = create_draft!(plan, %{@commercial_attrs | amount_minor: 1_111})
      second = create_draft!(plan, %{@commercial_attrs | amount_minor: 2_222})
      {plan.id, first.id, second.id}
    end)
  end

  defp delete_committed_race_fixture!(plan_id) do
    Sandbox.unboxed_run(Store.Repo, fn ->
      dumped_plan_id = Ecto.UUID.dump!(plan_id)

      Store.Repo.query!(
        "DELETE FROM plan_revisions WHERE subscription_plan_id = $1",
        [dumped_plan_id]
      )

      Store.Repo.query!("DELETE FROM subscription_plans WHERE id = $1", [dumped_plan_id])
    end)
  end

  defp subscription_snapshot!(id) do
    subscription =
      Subscription
      |> Ash.Query.filter(expr(id == ^id))
      |> Ash.read_one!(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})

    Map.take(subscription, [
      :id,
      :subscription_plan_id,
      :status,
      :renewal_amount_minor,
      :renewal_currency,
      :quantity,
      :current_plan_revision_id,
      :updated_at
    ])
  end

  defp clear_plan_revision_binding!(subscription_id) do
    assert %{num_rows: 1} =
             Store.Repo.query!(
               "UPDATE subscriptions SET current_plan_revision_id = NULL WHERE id = $1",
               [Ecto.UUID.dump!(subscription_id)]
             )
  end

  defp stale_record_error?(error) do
    invalid_errors(error)
    |> Enum.any?(&match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp stale_or_filter_error?(error) do
    invalid_errors(error)
    |> Enum.any?(fn err ->
      match?(%Ash.Error.Changes.StaleRecord{}, err) or
        match?(%Ash.Error.Changes.InvalidChanges{}, err)
    end)
  end

  defp invalid_state_transition_error?(error) do
    invalid_errors(error)
    |> Enum.any?(fn err ->
      match?(%Ash.Error.Changes.InvalidAttribute{message: "INVALID_STATE_TRANSITION"}, err) or
        (is_struct(err) and Exception.message(err) =~ "INVALID_STATE_TRANSITION")
    end)
  end

  defp fk_violation_error?(error) do
    invalid_errors(error)
    |> Enum.any?(fn err ->
      match?(%Ash.Error.Changes.InvalidAttribute{field: :subscription_plan_id}, err) or
        match?(%Ash.Error.Changes.InvalidRelationship{}, err) or
        String.contains?(Exception.message(err), "foreign key")
    end)
  end

  defp invalid_errors({:error, %Ash.Error.Invalid{errors: errors}}), do: errors
  defp invalid_errors(%Ash.Error.Invalid{errors: errors}), do: errors
  defp invalid_errors(_), do: []

  defp billing_timezone_error?(error) do
    Enum.any?(invalid_errors(error), fn validation_error ->
      Map.has_key?(Map.from_struct(validation_error), :field) and
        validation_error.field == :billing_timezone
    end)
  end

  defp not_found_error?(%Ash.Error.Query.NotFound{}), do: true

  defp not_found_error?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &not_found_error?/1)

  defp not_found_error?(error) when is_exception(error),
    do: Exception.message(error) =~ "record not found"

  defp not_found_error?(_error), do: false

  defp effective_uniqueness_error?(error) do
    inspect(error) =~ "plan_revisions_one_effective_per_plan_index" or
      Exception.message(error) =~ "plan_revisions_one_effective_per_plan_index"
  end
end
