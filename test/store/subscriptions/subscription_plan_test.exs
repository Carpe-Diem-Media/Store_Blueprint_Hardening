defmodule Store.Subscriptions.SubscriptionPlanTest do
  use Store.DataCase, async: false

  alias Store.Subscriptions.SubscriptionPlan

  test "create defaults the commercial billing timezone to Johannesburg" do
    unique = Ecto.UUID.generate()

    assert {:ok, plan} = create(%{key: "TZ_#{unique}", name: "Timezone test", amount_minor: 100})
    assert plan.billing_timezone == "Africa/Johannesburg"
  end

  test "create rejects invalid billing timezones after trimming" do
    for timezone <- [nil, "", "Not/A_Real_Zone"] do
      assert {:error, error} =
               create(%{
                 key: "TZ_#{Ecto.UUID.generate()}",
                 name: "Timezone test",
                 amount_minor: 100,
                 billing_timezone: timezone
               })

      assert timezone_error?(error)
    end

    assert {:ok, plan} =
             create(%{
               key: "TZ_#{Ecto.UUID.generate()}",
               name: "Timezone test",
               amount_minor: 100,
               billing_timezone: "  Africa/Johannesburg  "
             })

    assert plan.billing_timezone == "Africa/Johannesburg"
  end

  test "update rejects invalid billing timezones and accepts trimmed supported zones" do
    plan = Store.SubscriptionsFixtures.create_subscription_plan!()

    for timezone <- [nil, "", "Not/A_Real_Zone"] do
      assert {:error, error} = update_plan(plan, %{billing_timezone: timezone})
      assert timezone_error?(error)
    end

    assert {:ok, updated} = update_plan(plan, %{billing_timezone: "  Africa/Johannesburg  "})
    assert updated.billing_timezone == "Africa/Johannesburg"
  end

  defp create(attrs) do
    SubscriptionPlan
    |> Ash.Changeset.for_create(:create, attrs, context: %{system?: true})
    |> Ash.create(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp update_plan(plan, attrs) do
    plan
    |> Ash.Changeset.for_update(:update, attrs, context: %{system?: true})
    |> Ash.update(domain: Store.Subscriptions, authorize?: false, context: %{system?: true})
  end

  defp timezone_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, fn error ->
      Map.get(error, :field) == :billing_timezone or
        (Map.has_key?(Map.from_struct(error), :field) and error.field == :billing_timezone)
    end)
  end

  defp timezone_error?(_), do: false
end
