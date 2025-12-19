defmodule SlackBot.TierRegistry.Builder do
  @moduledoc false

  @base_spec %{
      scope: :workspace,
      burst_ratio: 0.25,
      initial_fill_ratio: 0.5
    }

  @tier_defaults %{
    tier1: %{tier: :tier1, window_ms: 60_000, max_calls: 1},
    tier2: %{tier: :tier2, window_ms: 60_000, max_calls: 20},
    tier3: %{tier: :tier3, window_ms: 60_000, max_calls: 50},
    tier4: %{tier: :tier4, window_ms: 60_000, max_calls: 100}
  }

  @workspace_methods %{
    tier1: ~w(conversations.listConnectInvites rtm.connect rtm.start),
    tier2: ~w(
        auth.teams.list
        conversations.acceptSharedInvite
        conversations.archive
        conversations.canvases.create
        conversations.close
        conversations.create
        conversations.externalInvitePermissions.set
        conversations.inviteShared
        conversations.list
        conversations.rename
        conversations.requestSharedInvite.approve
        conversations.requestSharedInvite.deny
        conversations.requestSharedInvite.list
        conversations.setPurpose
        conversations.setTopic
        conversations.unarchive
        emoji.list
        files.comments.delete
        files.remote.add
        files.remote.info
        files.remote.list
        files.remote.remove
        files.remote.share
        files.remote.update
        reminders.add
        reminders.complete
        reminders.delete
        reminders.info
        reminders.list
        search.all
        search.files
        search.messages
        slackLists.create
        slackLists.download.start
        slackLists.items.delete
        slackLists.items.deleteMultiple
        slackLists.items.info
        slackLists.items.list
        slackLists.update
        usergroups.create
        usergroups.disable
        usergroups.enable
        usergroups.list
        usergroups.update
        usergroups.users.list
        usergroups.users.update
        users.deletePhoto
        users.discoverableContacts.lookup
        users.setActive
        users.setPhoto
        users.setPresence
        workflows.featured.add
        workflows.featured.list
        workflows.featured.remove
        workflows.featured.set
      ),
    tier3: ~w(
        auth.revoke
        bots.info
        conversations.approveSharedInvite
        conversations.declineSharedInvite
        conversations.history
        conversations.info
        conversations.invite
        conversations.join
        conversations.kick
        conversations.leave
        conversations.mark
        conversations.open
        conversations.replies
        entity.presentDetails
        files.delete
        files.list
        files.revokePublicURL
        files.sharedPublicURL
        slackLists.access.delete
        slackLists.access.set
        slackLists.items.create
        slackLists.items.update
        workflows.triggers.permissions.add
        workflows.triggers.permissions.list
        workflows.triggers.permissions.remove
        workflows.triggers.permissions.set
        users.conversations
        users.getPresence
        users.identity
        users.lookupByEmail
        users.profile.set
      ),
    tier4: ~w(
        auth.test
        conversations.members
        files.completeUploadExternal
        files.getUploadURLExternal
        files.info
        slackLists.download.get
        users.info
        users.profile.get
      )
  }

  @channel_methods [
    %{method: "bookmarks.add", tier: :tier2, channel_field: "channel_id"},
    %{method: "bookmarks.edit", tier: :tier2, channel_field: "channel_id"},
    %{method: "bookmarks.list", tier: :tier3, channel_field: "channel_id"},
    %{method: "bookmarks.remove", tier: :tier2, channel_field: "channel_id"},
    %{method: "chat.appendStream", tier: :tier4},
    %{method: "chat.delete", tier: :tier3},
    %{method: "chat.deleteScheduledMessage", tier: :tier3},
    %{method: "chat.meMessage", tier: :tier3},
    %{method: "chat.postEphemeral", tier: :tier4},
    %{method: "chat.scheduleMessage", tier: :tier3},
    %{method: "chat.scheduledMessages.list", tier: :tier3},
    %{method: "chat.startStream", tier: :tier2},
    %{method: "chat.stopStream", tier: :tier2},
    %{method: "chat.unfurl", tier: :tier3},
    %{method: "chat.update", tier: :tier3},
    %{method: "pins.add", tier: :tier2},
    %{method: "pins.list", tier: :tier2},
    %{method: "pins.remove", tier: :tier2},
    %{method: "reactions.add", tier: :tier3},
    %{method: "reactions.get", tier: :tier3},
    %{method: "reactions.list", tier: :tier2},
    %{method: "reactions.remove", tier: :tier2}
  ]

  @grouped_methods [
    %{method: "users.list", tier: :tier2, group: :metadata_catalog}
  ]

  @special_methods %{
    "chat.getPermalink" => %{window_ms: 60_000, max_calls: 200},
    "chat.postMessage" => %{
      window_ms: 1_000,
      max_calls: 1,
      scope: {:channel, "channel"},
      burst_ratio: 0.0,
      initial_fill_ratio: 1.0
    }
  }

  defp workspace_specs do
    Enum.reduce(@workspace_methods, %{}, fn {tier, methods}, acc ->
      Enum.reduce(methods, acc, fn method, acc_inner ->
        Map.put(acc_inner, method, tier_spec(tier, %{}))
      end)
    end)
  end

  defp channel_specs do
    Enum.reduce(@channel_methods, %{}, fn %{method: method, tier: tier} = entry, acc ->
      field = Map.get(entry, :channel_field, "channel")
      Map.put(acc, method, channel_tier_spec(tier, channel_field: field))
    end)
  end

  defp grouped_specs do
    Enum.reduce(@grouped_methods, %{}, fn %{method: method, tier: tier} = entry, acc ->
      Map.put(acc, method, tier_spec(tier, Map.take(entry, [:group])))
    end)
  end

  defp special_specs do
    Enum.reduce(@special_methods, %{}, fn {method, opts}, acc ->
      Map.put(acc, method, special_spec(opts))
    end)
  end

  defp tier_spec(tier, overrides) do
    defaults = Map.fetch!(@tier_defaults, tier)
    merge_spec(defaults, overrides)
  end

  defp channel_tier_spec(tier, overrides) do
    overrides = normalize_overrides(overrides)
    channel_field = Map.get(overrides, :channel_field, "channel")

    overrides =
      overrides
      |> Map.delete(:channel_field)
      |> Map.put(:scope, {:channel, channel_field})

    tier_spec(tier, overrides)
  end

  defp special_spec(opts) do
    opts
    |> normalize_overrides()
    |> Map.put(:tier, :special)
    |> merge_spec(%{})
  end

  defp merge_spec(base, overrides) do
    overrides = normalize_overrides(overrides)

    @base_spec
    |> Map.merge(base)
    |> Map.merge(overrides)
  end

  defp normalize_overrides(%{} = overrides), do: overrides
  defp normalize_overrides(list) when is_list(list), do: Map.new(list)
  defp normalize_overrides(nil), do: %{}

  defmacro default_tiers do
    quote do
      unquote(Macro.escape(build_default_tiers()))
    end
  end

  defmacro method_catalog do
    quote do
      unquote(Macro.escape(build_method_catalog()))
    end
  end

  defp build_default_tiers do
    workspace_specs()
    |> Map.merge(channel_specs())
    |> Map.merge(grouped_specs())
    |> Map.merge(special_specs())
  end

  defp build_method_catalog do
    %{
      workspace: @workspace_methods,
      channel: @channel_methods,
      grouped: @grouped_methods,
      special: @special_methods
    }
  end
end

defmodule SlackBot.TierRegistry do
  @moduledoc false

  alias SlackBot.TierRegistry.Builder
  require SlackBot.TierRegistry.Builder

  @default_tiers Builder.default_tiers()
  @method_catalog Builder.method_catalog()

  @doc false
  def __default_tiers__, do: @default_tiers

  @doc false
  def __method_catalog__, do: @method_catalog

  @doc false
  def __default_spec__(method), do: Map.fetch!(@default_tiers, method)

  @doc """
  Returns the tier specification for a given Slack Web API method.

  Specs can be overridden via `config :slack_bot_ws, SlackBot.TierRegistry,
  tiers: %{ "users.list" => %{max_calls: 10, window_ms: 30_000} }`.
  """
  @spec lookup(String.t()) :: {:ok, map()} | :error
  def lookup(method) when is_binary(method) do
    tiers()
    |> Map.fetch(method)
    |> case do
      {:ok, spec} -> {:ok, normalize_spec(spec)}
      :error -> :error
    end
  end

  defp tiers do
    overrides =
      Application.get_env(:slack_bot_ws, __MODULE__, [])
      |> Keyword.get(:tiers, %{})

    Map.merge(@default_tiers, overrides)
  end

  defp normalize_spec(spec) do
    %{
      tier: Map.get(spec, :tier, :custom),
      window_ms: Map.get(spec, :window_ms) || Map.get(spec, :window, 60_000),
      max_calls: Map.get(spec, :max_calls) || Map.get(spec, :limit, 20),
      scope: Map.get(spec, :scope, :workspace),
      group: Map.get(spec, :group),
      burst_ratio: Map.get(spec, :burst_ratio, 0.25),
      capacity: Map.get(spec, :capacity),
      initial_fill_ratio: Map.get(spec, :initial_fill_ratio, 0.5)
    }
  end
end
