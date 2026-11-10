defmodule Store.Subscriptions.CompositionSnapshot do
  @moduledoc """
  Immutable commercial evidence for the existing initial paid Subscription activation.

  This first format contains zero or one entitlement component. It records the already-applied
  payment and original paid interval; it is neither a billing lifecycle nor current access
  authority. Later source changes need not advance or rewrite this historical snapshot.

  `payment_amount_minor` is the succeeded PaymentIntent amount for the whole Order.
  Multiple line snapshots may reference that same payment occurrence; the amount is not
  an allocation of funds to a component and must not be summed across snapshots.
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

  # Version 1 identity is the original order-line UUID. A future format must define
  # durable identity across snapshots, creation, removal and reactivation explicitly.
  # Identity is independent of snapshot ID, array position and display labels. Equivalent
  # entitlement tuples must not result in duplicate charges or rights.
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
         kind when kind in ["membership_access", "digital_library", "discount_tier"] <-
           component["kind"],
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

  def valid_fingerprint?(_), do: false

  @doc false
  @spec fingerprint(map()) :: String.t() | {:error, :unsupported_format_version}
  def fingerprint(fields) do
    case Map.get(fields, :format_version, 1) do
      1 -> fingerprint_v1(fields)
      _ -> {:error, :unsupported_format_version}
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
end
