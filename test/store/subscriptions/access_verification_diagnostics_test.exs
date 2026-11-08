defmodule Store.Subscriptions.AccessVerificationDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Store.Entitlements.EntitlementGrant
  alias Store.Entitlements.Inputs.SubscriptionSourceConvergenceInput
  alias Store.Entitlements.Types.EntitlementSet
  alias Store.Subscriptions.AccessVerificationDiagnostics

  @observed_at ~U[2025-06-01 12:00:00.000000Z]
  @valid_from ~U[2025-06-01 12:00:00.000000Z]
  @valid_until ~U[2025-06-02 12:00:00.000000Z]
  @subscription_id "018f0000-0000-7000-8000-000000000001"
  @user_id "018f0000-0000-7000-8000-000000000002"
  @grant_id "018f0000-0000-7000-8000-000000000003"

  test "uses inclusive starts and exclusive ends like the public entitlement set" do
    start_grant = grant(valid_from_at: @observed_at)

    end_grant =
      grant(
        valid_from_at: DateTime.add(@observed_at, -1, :day),
        valid_to_at: @observed_at
      )

    open_end_grant = grant(valid_to_at: nil)
    revoked_grant = grant(revoked_at: @observed_at)

    assert Enum.map(
             [start_grant, end_grant, open_end_grant, revoked_grant],
             &AccessVerificationDiagnostics.classify(input(), [&1], @observed_at)
           )
           |> Enum.map(&hd(&1.samples).effective_at_observation?) == [true, false, true, false]

    assert AccessVerificationDiagnostics.classify(input(), [end_grant], @observed_at)
           |> Map.fetch!(:samples)
           |> hd()
           |> Map.fetch!(:temporal_state) == :expired

    set = %EntitlementSet{
      user_id: @user_id,
      grants: [start_grant, end_grant, open_end_grant, revoked_grant],
      fetched_at: @observed_at,
      expires_at: DateTime.add(@observed_at, 1, :hour)
    }

    assert Enum.map(EntitlementSet.effective_grants(set, @observed_at), & &1.id) ==
             [start_grant.id, open_end_grant.id]
  end

  test "reports sampled identity, validity, and revocation mismatches" do
    rows = [
      grant(user_id: "018f0000-0000-7000-8000-000000000010"),
      grant(kind: :digital_library),
      grant(scope_key: "another-scope"),
      grant(valid_from_at: DateTime.add(@valid_from, -1, :day), revoked_reason: "legacy")
    ]

    diagnostics =
      Enum.map(rows, &AccessVerificationDiagnostics.classify(input(), [&1], @observed_at))

    classifications = Enum.flat_map(diagnostics, & &1.classifications)
    samples = Enum.flat_map(diagnostics, & &1.samples)

    assert :wrong_owner in classifications
    assert :wrong_kind in classifications
    assert :wrong_scope in classifications
    assert :validity_mismatch in classifications
    assert :invalid_revocation_metadata in classifications

    assert Enum.all?(Enum.take(diagnostics, 3), fn diag ->
             :effective_overgrant in diag.classifications
           end)

    refute :effective_overgrant in List.last(diagnostics).classifications
    assert Enum.all?(samples, &is_boolean(&1.owner_matches?))
    assert Enum.all?(samples, &is_boolean(&1.kind_matches?))
    assert Enum.all?(samples, &is_boolean(&1.scope_matches?))
    assert Enum.all?(samples, &is_boolean(&1.valid_from_matches?))
    assert Enum.all?(samples, &is_boolean(&1.valid_to_matches?))
    assert Enum.all?(samples, &is_boolean(&1.revocation_metadata_valid?))
  end

  test "separates an absent exact target from absent current access" do
    diagnostics =
      AccessVerificationDiagnostics.classify(
        input(),
        [grant(valid_from_at: DateTime.add(@valid_from, -1, :day))],
        @observed_at
      )

    assert diagnostics.desired_target_effective?
    assert diagnostics.exact_target_in_sample? == false
    assert diagnostics.effective_matching_sample_count == 1
    assert :missing_required_target in diagnostics.classifications
    refute :missing_current_access in diagnostics.classifications
    assert :validity_mismatch in diagnostics.classifications
  end

  test "future and expired targets do not require current access" do
    future_input =
      input(
        valid_from_at: DateTime.add(@observed_at, 1, :day),
        valid_until_at: DateTime.add(@observed_at, 2, :day)
      )

    expired_input =
      input(
        valid_from_at: DateTime.add(@observed_at, -2, :day),
        valid_until_at: DateTime.add(@observed_at, -1, :day)
      )

    for target_input <- [future_input, expired_input] do
      diagnostics = AccessVerificationDiagnostics.classify(target_input, [], @observed_at)

      assert diagnostics.desired_target_effective? == false
      assert :missing_required_target in diagnostics.classifications
      refute :missing_current_access in diagnostics.classifications
    end
  end

  test "marks invalid active windows without treating them as current" do
    diagnostics =
      AccessVerificationDiagnostics.classify(
        input(),
        [grant(valid_to_at: DateTime.add(@valid_from, -1, :second))],
        @observed_at
      )

    assert [sample] = diagnostics.samples
    assert sample.temporal_state == :invalid
    refute sample.effective_at_observation?
  end

  test "handles a non-effective nil target without adding pair mismatch classes" do
    diagnostics =
      AccessVerificationDiagnostics.classify(
        input(
          disposition: :non_effective,
          entitlement_kind: nil,
          entitlement_scope_key: nil,
          valid_from_at: nil,
          valid_until_at: nil
        ),
        [grant(revoked_reason: "unexpected_active_metadata")],
        @observed_at
      )

    assert :invalid_revocation_metadata in diagnostics.classifications
    assert :effective_overgrant in diagnostics.classifications
    refute :wrong_kind in diagnostics.classifications
    refute :wrong_scope in diagnostics.classifications
    refute :validity_mismatch in diagnostics.classifications
  end

  test "does not infer missing evidence from a full sample but reports visible overgrants" do
    diagnostics =
      AccessVerificationDiagnostics.classify(
        input(
          disposition: :non_effective,
          entitlement_kind: nil,
          entitlement_scope_key: nil,
          valid_from_at: nil,
          valid_until_at: nil
        ),
        [grant(scope_key: "unexpected-a"), grant(scope_key: "unexpected-b")],
        @observed_at
      )

    assert diagnostics.sample_count == 2
    assert diagnostics.sample_complete? == false
    assert diagnostics.classifications == [:effective_overgrant, :incomplete_evidence]
    assert :incomplete_evidence in diagnostics.classifications
    assert :effective_overgrant in diagnostics.classifications
    refute :missing_required_target in diagnostics.classifications
    refute :missing_current_access in diagnostics.classifications
  end

  test "does not infer absence for a current desired target from two expired or future samples" do
    diagnostics =
      AccessVerificationDiagnostics.classify(
        input(),
        [
          grant(
            scope_key: "expired",
            valid_from_at: DateTime.add(@observed_at, -2, :day),
            valid_to_at: DateTime.add(@observed_at, -1, :day)
          ),
          grant(
            scope_key: "future",
            valid_from_at: DateTime.add(@observed_at, 1, :day),
            valid_to_at: DateTime.add(@observed_at, 2, :day)
          )
        ],
        @observed_at
      )

    assert diagnostics.sample_complete? == false
    assert :incomplete_evidence in diagnostics.classifications
    refute :missing_required_target in diagnostics.classifications
    refute :missing_current_access in diagnostics.classifications
  end

  test "does not call a legitimate future or expired target stale when another sampled grant causes drift" do
    for {valid_from_at, valid_until_at, cleanup_class} <- [
          {DateTime.add(@observed_at, 1, :day), DateTime.add(@observed_at, 2, :day),
           :future_active_cleanup},
          {DateTime.add(@observed_at, -2, :day), DateTime.add(@observed_at, -1, :day),
           :expired_active_cleanup}
        ] do
      diagnostics =
        AccessVerificationDiagnostics.classify(
          input(valid_from_at: valid_from_at, valid_until_at: valid_until_at),
          [
            grant(valid_from_at: valid_from_at, valid_to_at: valid_until_at),
            grant(scope_key: "unexpected-current")
          ],
          @observed_at
        )

      assert diagnostics.exact_target_in_sample?
      refute cleanup_class in diagnostics.classifications
      assert :effective_overgrant in diagnostics.classifications
    end
  end

  test "caps returned evidence at two samples and marks a two row result incomplete" do
    diagnostics =
      AccessVerificationDiagnostics.classify(
        input(
          disposition: :non_effective,
          entitlement_kind: nil,
          entitlement_scope_key: nil,
          valid_from_at: nil,
          valid_until_at: nil
        ),
        [grant(), grant(scope_key: "extra"), grant(scope_key: "third")],
        @observed_at
      )

    assert diagnostics.sample_limit == 2
    assert length(diagnostics.samples) == 2
    assert diagnostics.sample_count == 2
    refute diagnostics.sample_complete?
  end

  defp input(overrides \\ []) do
    struct!(
      SubscriptionSourceConvergenceInput,
      Map.merge(
        %{
          subscription_id: @subscription_id,
          user_id: @user_id,
          disposition: :effective,
          entitlement_kind: :membership_access,
          entitlement_scope_key: "scope-a",
          valid_from_at: @valid_from,
          valid_until_at: @valid_until,
          reason: "test",
          access_effect_id: "018f0000-0000-7000-8000-000000000004",
          source_version: 1,
          target_fingerprint: String.duplicate("a", 64)
        },
        Map.new(overrides)
      )
    )
  end

  defp grant(overrides \\ []) do
    struct!(
      EntitlementGrant,
      Map.merge(
        %{
          id: @grant_id,
          user_id: @user_id,
          kind: :membership_access,
          scope_key: "scope-a",
          source_kind: :subscription,
          source_id: @subscription_id,
          status: :active,
          valid_from_at: @valid_from,
          valid_to_at: @valid_until,
          revoked_at: nil,
          revoked_reason: nil
        },
        Map.new(overrides)
      )
    )
  end
end
