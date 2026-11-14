defmodule Store.Subscriptions.CompositionSnapshot do
  @moduledoc """
  Immutable commercial evidence for Subscription compositions.

  Format 1 records the existing initial paid activation with zero or one entitlement component.
  Its component key remains the original order-line UUID, and its fingerprint descriptor is frozen.
  Format 2 defines a stable UUIDv7 component instance key and supports up to 16 components in the
  codec. It is codec-only: the Ash resource and PostgreSQL table remain format 1 because this
  resource's order and payment fields describe the initial sale and cannot establish provenance
  for later composition changes.

  A governed persistence change must establish commercial source provenance, a v2 record shape,
  immutable creation and replay, matching Ash and PostgreSQL validation, a tested database
  round-trip, and migration and rollback safety before enabling persisted format 2 records.

  Neither format implements a billing lifecycle or current access authority. Later source changes
  require new immutable evidence and must not rewrite historical snapshots.

  `payment_amount_minor` is the succeeded PaymentIntent amount for the whole Order.
  Multiple line snapshots may reference that same payment occurrence; the amount is not
  an allocation of funds to a component and must not be summed across snapshots.

  Format 2 uses the owning Subscription UUID as the membership source. A component UUIDv7 names
  one recurring obligation within that source. It remains stable across snapshots and renewals,
  pending removal, rescission, and recovery of the same obligation. Re-admission after terminal
  removal receives a new component identity. Distinct component identities may share an entitlement
  scope; commercial admission and effective access rules remain separate responsibilities.
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Store.Subscriptions

  @fields [
    :id,
    :subscription_id,
    :source_version,
    :user_id,
    :order_id,
    :source_order_line_item_id,
    :plan_revision_id,
    :payment_intent_id,
    :payment_application_id,
    :variant_id,
    :quantity,
    :renewal_amount_minor,
    :payment_amount_minor,
    :currency,
    :period_start_at,
    :period_end_at,
    :components
  ]

  @v2_max_components 16
  @v2_max_scope_key_bytes 255
  @v2_max_timestamp_bytes 35
  @component_kinds ["membership_access", "digital_library", "discount_tier"]
  @v2_payload_fields [:format_version, :subscription_id, :source_version, :components]
  @v2_allowed_fields @v2_payload_fields ++ [:id, :fingerprint]

  attributes do
    attribute :format_version, :integer do
      allow_nil?(false)
      default(1)
      public?(false)
    end

    uuid_v7_primary_key(:id, writable?: true)

    for field <- [:source_version, :quantity] do
      attribute field, :integer do
        allow_nil?(false)
        constraints(min: 1)
        public?(false)
      end
    end

    for field <- [
          :user_id,
          :order_id,
          :source_order_line_item_id,
          :plan_revision_id,
          :payment_intent_id,
          :payment_application_id,
          :variant_id
        ] do
      attribute field, :uuid do
        allow_nil?(false)
        public?(false)
      end
    end

    for field <- [:renewal_amount_minor, :payment_amount_minor] do
      attribute field, :integer do
        allow_nil?(false)
        constraints(min: 0)
        public?(false)
      end
    end

    attribute :currency, :string do
      allow_nil?(false)
      constraints(min_length: 3, max_length: 3)
      public?(false)
    end

    for field <- [:period_start_at, :period_end_at] do
      attribute field, :utc_datetime_usec do
        allow_nil?(false)
        public?(false)
      end
    end

    attribute :components, {:array, :map} do
      allow_nil?(false)
      constraints(max_length: 1)
      public?(false)
    end

    attribute :fingerprint, :string do
      allow_nil?(false)
      constraints(min_length: 64, max_length: 64)
      public?(false)
    end

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :subscription, Store.Subscriptions.Subscription do
      allow_nil?(false)
      attribute_writable?(true)
      public?(false)
    end
  end

  identities do
    identity(:unique_source_version, [:subscription_id, :source_version])
    identity(:unique_snapshot_source, [:id, :subscription_id])
  end

  actions do
    defaults([])

    read :read do
      primary?(true)
      public?(false)
    end

    create :establish do
      public?(false)
      description("Records verified initial paid evidence inside the activation transaction.")
      accept(@fields)

      validate(fn changeset, _context ->
        start_at = Ash.Changeset.get_attribute(changeset, :period_start_at)
        end_at = Ash.Changeset.get_attribute(changeset, :period_end_at)

        if Store.Repo.in_transaction?() and match?(%DateTime{}, start_at) and
             match?(%DateTime{}, end_at) and DateTime.compare(start_at, end_at) == :lt do
          :ok
        else
          {:error,
           field: :period_end_at, message: "requires the caller transaction and a paid interval"}
        end
      end)

      validate(fn changeset, _context ->
        fields = Map.new(@fields, &{&1, Ash.Changeset.get_attribute(changeset, &1)})

        if valid_v1_components?(fields) do
          :ok
        else
          {:error, field: :components, message: "invalid version 1 components"}
        end
      end)

      change(fn changeset, _context ->
        fields = Map.new(@fields, &{&1, Ash.Changeset.get_attribute(changeset, &1)})

        if changeset.valid? and valid_v1_components?(fields) do
          Ash.Changeset.change_attribute(changeset, :fingerprint, fingerprint(fields))
        else
          changeset
        end
      end)
    end
  end

  postgres do
    table("composition_snapshots")
    repo(Store.Repo)

    references do
      reference(:subscription, on_delete: :delete)
    end

    check_constraints do
      check_constraint(:format_version, "composition_snapshots_format_version_check",
        check: "format_version = 1"
      )

      check_constraint(:source_version, "composition_snapshots_source_version_check",
        check: "source_version > 0"
      )

      check_constraint(:period_end_at, "composition_snapshots_period_check",
        check: "period_end_at > period_start_at"
      )

      check_constraint(:components, "composition_snapshots_scalar_components_check",
        check: "cardinality(components) <= 1"
      )
    end
  end

  policies do
    policy action_type([:read, :create]) do
      authorize_if(context_equals(:system?, true))
    end
  end

  # Version 1 identity is the original order-line UUID. Format 2 identity is a separate UUIDv7
  # for the logical recurring obligation. It is scoped by subscription_id, not by snapshot id,
  # array position, display label, variant, price, or entitlement scope.
  @doc false
  def valid_v1_components?(%{components: [], source_order_line_item_id: _}), do: true

  def valid_v1_components?(%{components: [component], source_order_line_item_id: line_id})
      when is_map(component) do
    with ["component_key", "kind", "scope_key", "valid_from_at", "valid_until_at"] <-
           Enum.sort(Map.keys(component)),
         key when is_binary(key) <- component["component_key"],
         {:ok, key_uuid} <- Ecto.UUID.cast(key),
         {:ok, line_uuid} <- Ecto.UUID.cast(line_id),
         true <- key_uuid == line_uuid,
         kind when kind in @component_kinds <- component["kind"],
         scope when is_binary(scope) and byte_size(scope) in 1..255 <- component["scope_key"],
         true <- String.valid?(scope) and String.trim(scope) != "",
         {:ok, from, _} <- parse_timestamp(component["valid_from_at"]),
         {:ok, until} <- parse_optional_timestamp(component["valid_until_at"]) do
      is_nil(until) or DateTime.compare(from, until) == :lt
    else
      _ -> false
    end
  end

  def valid_v1_components?(_), do: false

  @doc false
  def valid_v2_components?(%{components: components})
      when is_list(components) and length(components) <= @v2_max_components do
    with {:ok, keys} <- Enum.reduce_while(components, {:ok, []}, &collect_v2_component_key/2),
         true <- length(keys) == length(Enum.uniq(keys)) do
      true
    else
      _ -> false
    end
  end

  def valid_v2_components?(_), do: false

  @doc false
  def valid_components?(fields) when is_map(fields) do
    case Map.get(fields, :format_version, 1) do
      1 -> valid_v1_components?(fields)
      2 -> valid_v2_payload?(fields)
      _ -> false
    end
  end

  def valid_components?(_), do: false

  @doc false
  def canonical_v2_components(%{format_version: 2, components: components} = fields) do
    if valid_v2_payload?(fields) do
      {:ok, canonicalize_v2_components(components)}
    else
      {:error, :invalid_v2_payload}
    end
  end

  def canonical_v2_components(_), do: {:error, :unsupported_format_version}

  defp parse_timestamp(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp parse_timestamp(_), do: :error
  defp parse_optional_timestamp(nil), do: {:ok, nil}

  defp parse_optional_timestamp(value) do
    case parse_timestamp(value) do
      {:ok, timestamp, _} -> {:ok, timestamp}
      _ -> :error
    end
  end

  @doc false
  def valid_fingerprint?(%{format_version: 1} = fields) do
    valid_v1_components?(fields) and fields.fingerprint == fingerprint(fields)
  rescue
    ArgumentError -> false
    KeyError -> false
    MatchError -> false
    FunctionClauseError -> false
  end

  def valid_fingerprint?(%{format_version: 2} = fields) do
    valid_v2_payload?(fields) and fields.fingerprint == fingerprint(fields)
  rescue
    ArgumentError -> false
    KeyError -> false
    MatchError -> false
    FunctionClauseError -> false
  end

  def valid_fingerprint?(_), do: false

  @doc false
  @spec fingerprint(map()) ::
          String.t() | {:error, :invalid_v2_payload | :unsupported_format_version}
  def fingerprint(fields) do
    case Map.get(fields, :format_version, 1) do
      1 ->
        fingerprint_v1(fields)

      2 ->
        if valid_v2_payload?(fields),
          do: fingerprint_v2(fields),
          else: {:error, :invalid_v2_payload}

      _ ->
        {:error, :unsupported_format_version}
    end
  end

  defp fingerprint_v1(fields) do
    # UUID identities are encoded as binary, never sorted by their textual representation.
    descriptor =
      Enum.map(@fields -- [:id], fn field ->
        value = Map.fetch!(fields, field)

        cond do
          field in [
            :subscription_id,
            :user_id,
            :order_id,
            :source_order_line_item_id,
            :plan_revision_id,
            :payment_intent_id,
            :payment_application_id,
            :variant_id
          ] ->
            {field, Ecto.UUID.dump!(value)}

          field == :components ->
            {field,
             Enum.map(value, fn component ->
               Map.update!(component, "component_key", &Ecto.UUID.dump!/1)
             end)}

          is_struct(value, DateTime) ->
            {field, DateTime.to_unix(value, :microsecond)}

          true ->
            {field, value}
        end
      end)

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({:initial_composition, 1, descriptor}, [:deterministic])
    )
    |> Base.encode16(case: :lower)
  end

  defp fingerprint_v2(fields) do
    descriptor =
      {Ecto.UUID.dump!(fields.subscription_id), fields.source_version,
       canonical_v2_component_descriptor(fields.components)}

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({:store_composition_snapshot, 2, descriptor}, [:deterministic])
    )
    |> Base.encode16(case: :lower)
  end

  defp valid_v2_payload?(fields) do
    Enum.all?(@v2_payload_fields, &Map.has_key?(fields, &1)) and
      Enum.all?(Map.keys(fields), &(&1 in @v2_allowed_fields)) and
      Map.get(fields, :format_version) == 2 and valid_v2_source_fields?(fields) and
      valid_v2_components?(fields) and valid_v2_optional_fields?(fields)
  end

  defp valid_v2_source_fields?(fields) do
    match?({:ok, _}, uuid_v7_binary(Map.get(fields, :subscription_id))) and
      is_integer(Map.get(fields, :source_version)) and Map.get(fields, :source_version) > 0
  end

  defp valid_v2_optional_fields?(fields) do
    valid_v2_snapshot_id?(fields) and valid_v2_fingerprint_field?(fields)
  end

  defp valid_v2_snapshot_id?(fields) do
    not Map.has_key?(fields, :id) or match?({:ok, _}, uuid_v7_binary(Map.get(fields, :id)))
  end

  defp valid_v2_fingerprint_field?(fields) do
    not Map.has_key?(fields, :fingerprint) or
      (is_binary(Map.get(fields, :fingerprint)) and
         String.match?(Map.get(fields, :fingerprint), ~r/\A[0-9a-f]{64}\z/))
  end

  defp collect_v2_component_key(component, {:ok, keys}) do
    case v2_component_key(component) do
      {:ok, key} -> {:cont, {:ok, [key | keys]}}
      :error -> {:halt, :error}
    end
  end

  defp v2_component_key(component) when is_map(component) do
    with ["component_key", "kind", "scope_key", "valid_from_at", "valid_until_at"] <-
           Enum.sort(Map.keys(component)),
         {:ok, key} <- uuid_v7_binary(component["component_key"]),
         kind when kind in @component_kinds <- component["kind"],
         scope when is_binary(scope) and byte_size(scope) in 1..@v2_max_scope_key_bytes <-
           component["scope_key"],
         true <- String.valid?(scope) and String.trim(scope) != "",
         {:ok, from} <- parse_v2_timestamp(component["valid_from_at"]),
         {:ok, until} <- parse_optional_v2_timestamp(component["valid_until_at"]),
         true <- is_nil(until) or DateTime.compare(from, until) == :lt do
      {:ok, key}
    else
      _ -> :error
    end
  end

  defp v2_component_key(_), do: :error

  defp uuid_v7_binary(value) when is_binary(value) do
    with {:ok, uuid} <- Ecto.UUID.cast(value),
         binary <- Ecto.UUID.dump!(uuid),
         <<_::48, 7::4, _::12, 2::2, _::62>> <- binary do
      {:ok, binary}
    else
      _ -> :error
    end
  end

  defp uuid_v7_binary(_), do: :error

  defp parse_v2_timestamp(value)
       when is_binary(value) and byte_size(value) in 20..@v2_max_timestamp_bytes do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> {:ok, timestamp}
      _ -> :error
    end
  end

  defp parse_v2_timestamp(_), do: :error

  defp parse_optional_v2_timestamp(nil), do: {:ok, nil}

  defp parse_optional_v2_timestamp(value), do: parse_v2_timestamp(value)

  defp canonical_v2_component_descriptor(components) do
    components
    |> canonicalize_v2_components()
    |> Enum.map(fn component ->
      {:ok, from} = parse_v2_timestamp(component["valid_from_at"])
      {:ok, until} = parse_optional_v2_timestamp(component["valid_until_at"])

      {Ecto.UUID.dump!(component["component_key"]), component["kind"], component["scope_key"],
       DateTime.to_unix(from, :microsecond), until && DateTime.to_unix(until, :microsecond)}
    end)
  end

  defp canonicalize_v2_components(components) do
    components
    |> Enum.map(fn component ->
      {:ok, key} = v2_component_key(component)
      {:ok, from} = parse_v2_timestamp(component["valid_from_at"])
      {:ok, until} = parse_optional_v2_timestamp(component["valid_until_at"])

      canonical =
        component
        |> Map.put("component_key", Ecto.UUID.load!(key))
        |> Map.put("valid_from_at", canonical_v2_timestamp(from))
        |> Map.put("valid_until_at", until && canonical_v2_timestamp(until))

      {key, canonical}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp canonical_v2_timestamp(timestamp) do
    timestamp
    |> DateTime.to_unix(:microsecond)
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_iso8601()
  end
end
