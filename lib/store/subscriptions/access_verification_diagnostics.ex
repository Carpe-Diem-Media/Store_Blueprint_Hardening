defmodule Store.Subscriptions.AccessVerificationDiagnostics do
  @moduledoc """
  Builds bounded, read-only diagnostics for a source whose persisted authority
  has already passed verification and whose active grant set does not match it.

  This module only classifies the sampled rows. It does not validate authority,
  choose a repair, or change grants.
  """

  alias Store.Entitlements.Inputs.SubscriptionSourceConvergenceInput

  @sample_limit 2
  @classifications [
    :effective_overgrant,
    :expired_active_cleanup,
    :future_active_cleanup,
    :wrong_owner,
    :wrong_kind,
    :wrong_scope,
    :validity_mismatch,
    :invalid_revocation_metadata,
    :missing_required_target,
    :missing_current_access,
    :incomplete_evidence
  ]

  @type classification ::
          :effective_overgrant
          | :expired_active_cleanup
          | :future_active_cleanup
          | :wrong_owner
          | :wrong_kind
          | :wrong_scope
          | :validity_mismatch
          | :invalid_revocation_metadata
          | :missing_required_target
          | :missing_current_access
          | :incomplete_evidence

  @type sample :: %{
          grant_id: Ecto.UUID.t(),
          temporal_state: :current | :expired | :future | :invalid,
          effective_at_observation?: boolean(),
          owner_matches?: boolean(),
          kind_matches?: boolean(),
          scope_matches?: boolean(),
          source_matches?: boolean(),
          status_active?: boolean(),
          valid_from_matches?: boolean(),
          valid_to_matches?: boolean(),
          revocation_metadata_valid?: boolean()
        }

  @typedoc "Bounded classification evidence attached to one verification repair candidate."
  @type t :: %{
          classifications: [classification()],
          observed_at: DateTime.t(),
          desired_target_effective?: boolean(),
          sample_limit: 2,
          sample_count: 0..2,
          sample_complete?: boolean(),
          exact_target_in_sample?: boolean(),
          effective_matching_sample_count: non_neg_integer(),
          samples: [sample()]
        }

  @doc "Classifies at most two active grant samples against verified source authority at one observation time."
  @spec classify(SubscriptionSourceConvergenceInput.t(), [map()], DateTime.t()) :: t()
  def classify(%SubscriptionSourceConvergenceInput{} = input, grants, %DateTime{} = observed_at)
      when is_list(grants) do
    samples =
      grants
      |> Enum.take(@sample_limit)
      |> Enum.map(&sample(&1, input, observed_at))

    sample_count = length(samples)
    sample_complete? = sample_count < @sample_limit
    target_pair? = target_pair?(input)
    desired_target_effective? = target_pair? and interval_effective?(input, observed_at)

    evidence = %{
      observed_at: observed_at,
      desired_target_effective?: desired_target_effective?,
      sample_limit: @sample_limit,
      sample_count: sample_count,
      sample_complete?: sample_complete?,
      exact_target_in_sample?: Enum.any?(samples, &exact_target_sample?/1),
      effective_matching_sample_count: Enum.count(samples, &matching_effective_sample?/1),
      samples: samples
    }

    inferred =
      samples
      |> sampled_classes(target_pair?, desired_target_effective?)
      |> add_absence_classes(evidence, target_pair?)

    Map.put(
      evidence,
      :classifications,
      Enum.filter(@classifications, &MapSet.member?(inferred, &1))
    )
  end

  defp sampled_classes(samples, target_pair?, desired_target_effective?) do
    Enum.reduce(samples, MapSet.new(), fn sample, classes ->
      sample
      |> sample_classes(target_pair?, desired_target_effective?)
      |> Enum.reduce(classes, &MapSet.put(&2, &1))
    end)
  end

  defp sample_classes(sample, target_pair?, desired_target_effective?) do
    []
    |> maybe_class(temporal_cleanup?(sample, :expired), :expired_active_cleanup)
    |> maybe_class(temporal_cleanup?(sample, :future), :future_active_cleanup)
    |> maybe_class(not sample.owner_matches?, :wrong_owner)
    |> maybe_class(target_pair? and not sample.kind_matches?, :wrong_kind)
    |> maybe_class(target_pair? and not sample.scope_matches?, :wrong_scope)
    |> maybe_class(validity_mismatch?(sample, target_pair?), :validity_mismatch)
    |> maybe_class(not sample.revocation_metadata_valid?, :invalid_revocation_metadata)
    |> maybe_class(effective_overgrant?(sample, desired_target_effective?), :effective_overgrant)
  end

  defp temporal_cleanup?(sample, state),
    do: sample.temporal_state == state and not exact_target_sample?(sample)

  defp validity_mismatch?(sample, target_pair?),
    do: target_pair? and not (sample.valid_from_matches? and sample.valid_to_matches?)

  defp effective_overgrant?(sample, desired_target_effective?),
    do:
      sample.effective_at_observation? and
        (not desired_target_effective? or not owner_and_capability_match?(sample))

  defp owner_and_capability_match?(sample),
    do: sample.owner_matches? and sample.kind_matches? and sample.scope_matches?

  defp matching_effective_sample?(sample),
    do:
      owner_and_capability_match?(sample) and sample.source_matches? and
        sample.effective_at_observation?

  defp add_absence_classes(classes, evidence, target_pair?) do
    classes
    |> maybe_put(
      evidence.sample_complete? and target_pair? and not evidence.exact_target_in_sample?,
      :missing_required_target
    )
    |> maybe_put(
      evidence.sample_complete? and evidence.desired_target_effective? and
        evidence.effective_matching_sample_count == 0,
      :missing_current_access
    )
    |> maybe_put(not evidence.sample_complete?, :incomplete_evidence)
  end

  defp sample(grant, input, observed_at) do
    owner_matches? = Map.get(grant, :user_id) == input.user_id

    kind_matches? =
      not is_nil(input.entitlement_kind) and Map.get(grant, :kind) == input.entitlement_kind

    scope_matches? =
      not is_nil(input.entitlement_scope_key) and
        Map.get(grant, :scope_key) == input.entitlement_scope_key

    source_matches? =
      Map.get(grant, :source_kind) == :subscription and
        Map.get(grant, :source_id) == input.subscription_id

    valid_from_matches? = same_datetime?(Map.get(grant, :valid_from_at), input.valid_from_at)
    valid_to_matches? = same_datetime?(Map.get(grant, :valid_to_at), input.valid_until_at)
    revoked_at = Map.get(grant, :revoked_at)
    revoked_reason = Map.get(grant, :revoked_reason)
    revocation_metadata_valid? = is_nil(revoked_at) and is_nil(revoked_reason)
    state = temporal_state(grant, observed_at)

    %{
      grant_id: Map.get(grant, :id),
      temporal_state: state,
      effective_at_observation?: actual_effective?(grant, state),
      owner_matches?: owner_matches?,
      kind_matches?: kind_matches?,
      scope_matches?: scope_matches?,
      source_matches?: source_matches?,
      status_active?: Map.get(grant, :status) == :active,
      valid_from_matches?: valid_from_matches?,
      valid_to_matches?: valid_to_matches?,
      revocation_metadata_valid?: revocation_metadata_valid?
    }
  end

  defp actual_effective?(grant, :current) do
    Map.get(grant, :status) == :active and is_nil(Map.get(grant, :revoked_at))
  end

  defp actual_effective?(_grant, _state), do: false

  defp temporal_state(grant, observed_at) do
    valid_from_at = Map.get(grant, :valid_from_at)
    valid_to_at = Map.get(grant, :valid_to_at)

    if valid_interval?(valid_from_at, valid_to_at) do
      interval_state(valid_from_at, valid_to_at, observed_at)
    else
      :invalid
    end
  end

  defp valid_interval?(%DateTime{}, nil), do: true

  defp valid_interval?(%DateTime{} = valid_from_at, %DateTime{} = valid_to_at),
    do: DateTime.compare(valid_to_at, valid_from_at) == :gt

  defp valid_interval?(_valid_from_at, _valid_to_at), do: false

  defp interval_state(valid_from_at, valid_to_at, observed_at) do
    cond do
      DateTime.compare(valid_from_at, observed_at) == :gt -> :future
      expired_interval?(valid_to_at, observed_at) -> :expired
      true -> :current
    end
  end

  defp expired_interval?(nil, _observed_at), do: false

  defp expired_interval?(valid_to_at, observed_at),
    do: DateTime.compare(valid_to_at, observed_at) != :gt

  defp interval_effective?(input, observed_at) do
    match?(%DateTime{}, input.valid_from_at) and
      (is_nil(input.valid_until_at) or match?(%DateTime{}, input.valid_until_at)) and
      DateTime.compare(input.valid_from_at, observed_at) != :gt and
      (is_nil(input.valid_until_at) or DateTime.compare(input.valid_until_at, observed_at) == :gt)
  end

  defp target_pair?(%SubscriptionSourceConvergenceInput{
         disposition: :effective,
         entitlement_kind: kind,
         entitlement_scope_key: scope_key
       }),
       do: not is_nil(kind) and is_binary(scope_key)

  defp target_pair?(_input), do: false

  defp exact_target_sample?(sample) do
    sample.owner_matches? and sample.kind_matches? and sample.scope_matches? and
      sample.source_matches? and sample.status_active? and sample.valid_from_matches? and
      sample.valid_to_matches? and
      sample.revocation_metadata_valid?
  end

  defp same_datetime?(nil, nil), do: true

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp maybe_class(classes, true, class), do: [class | classes]
  defp maybe_class(classes, false, _class), do: classes

  defp maybe_put(classes, true, class), do: MapSet.put(classes, class)
  defp maybe_put(classes, false, _class), do: classes
end
