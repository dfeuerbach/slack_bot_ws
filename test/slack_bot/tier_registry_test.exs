defmodule SlackBot.TierRegistryTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias SlackBot.TierRegistry

  setup do
    original = Application.get_env(:slack_bot_ws, SlackBot.TierRegistry)

    on_exit(fn ->
      if original do
        Application.put_env(:slack_bot_ws, SlackBot.TierRegistry, original)
      else
        Application.delete_env(:slack_bot_ws, SlackBot.TierRegistry)
      end
    end)

    Application.delete_env(:slack_bot_ws, SlackBot.TierRegistry)
    :ok
  end

  @tier_defaults %{
    tier1: %{window_ms: 60_000, max_calls: 1},
    tier2: %{window_ms: 60_000, max_calls: 20},
    tier3: %{window_ms: 60_000, max_calls: 50},
    tier4: %{window_ms: 60_000, max_calls: 100}
  }

  @method_catalog TierRegistry.__method_catalog__()
  @workspace_methods Map.fetch!(@method_catalog, :workspace)
  @channel_methods Map.fetch!(@method_catalog, :channel)
  @grouped_methods Map.fetch!(@method_catalog, :grouped)
  @special_methods Map.fetch!(@method_catalog, :special)

  @issue_methods [
                   ~w(auth.revoke auth.teams.list auth.test),
                   ~w(bots.info),
                   ~w(bookmarks.add bookmarks.edit bookmarks.list bookmarks.remove),
                   ~w(
      chat.appendStream
      chat.delete
      chat.deleteScheduledMessage
      chat.getPermalink
      chat.meMessage
      chat.postEphemeral
      chat.postMessage
      chat.scheduleMessage
      chat.scheduledMessages.list
      chat.startStream
      chat.stopStream
      chat.unfurl
      chat.update
    ),
                   ~w(
      conversations.acceptSharedInvite
      conversations.approveSharedInvite
      conversations.archive
      conversations.canvases.create
      conversations.close
      conversations.create
      conversations.declineSharedInvite
      conversations.externalInvitePermissions.set
      conversations.history
      conversations.info
      conversations.invite
      conversations.inviteShared
      conversations.join
      conversations.kick
      conversations.leave
      conversations.list
      conversations.listConnectInvites
      conversations.mark
      conversations.members
      conversations.open
      conversations.rename
      conversations.replies
      conversations.requestSharedInvite.approve
      conversations.requestSharedInvite.deny
      conversations.requestSharedInvite.list
      conversations.setPurpose
      conversations.setTopic
      conversations.unarchive
    ),
                   ~w(emoji.list),
                   ~w(entity.presentDetails),
                   ~w(
      files.comments.delete
      files.completeUploadExternal
      files.delete
      files.getUploadURLExternal
      files.info
      files.list
      files.remote.add
      files.remote.info
      files.remote.list
      files.remote.remove
      files.remote.share
      files.remote.update
      files.revokePublicURL
      files.sharedPublicURL
    ),
                   ~w(pins.add pins.list pins.remove),
                   ~w(reactions.add reactions.get reactions.list reactions.remove),
                   ~w(reminders.add reminders.complete reminders.delete reminders.info reminders.list),
                   ~w(rtm.connect rtm.start),
                   ~w(search.all search.files search.messages),
                   ~w(
      slackLists.access.delete
      slackLists.access.set
      slackLists.create
      slackLists.download.get
      slackLists.download.start
      slackLists.items.create
      slackLists.items.delete
      slackLists.items.deleteMultiple
      slackLists.items.info
      slackLists.items.list
      slackLists.items.update
      slackLists.update
    ),
                   ~w(
      usergroups.create
      usergroups.disable
      usergroups.enable
      usergroups.list
      usergroups.update
      usergroups.users.list
      usergroups.users.update
    ),
                   ~w(
      users.conversations
      users.deletePhoto
      users.discoverableContacts.lookup
      users.getPresence
      users.identity
      users.info
      users.list
      users.lookupByEmail
      users.profile.get
      users.profile.set
      users.setActive
      users.setPhoto
      users.setPresence
    ),
                   ~w(
      workflows.featured.add
      workflows.featured.list
      workflows.featured.remove
      workflows.featured.set
      workflows.triggers.permissions.add
      workflows.triggers.permissions.list
      workflows.triggers.permissions.remove
      workflows.triggers.permissions.set
    )
                 ]
                 |> List.flatten()

  test "workspace-scoped methods use tier defaults" do
    Enum.each(@workspace_methods, fn {tier, methods} ->
      Enum.each(methods, fn method ->
        assert_default_spec(method, tier)
      end)
    end)
  end

  test "channel-scoped methods enforce channel buckets" do
    Enum.each(@channel_methods, fn %{tier: tier, method: method} = entry ->
      field = Map.get(entry, :channel_field, "channel")
      assert_channel_spec(method, tier, field)
    end)
  end

  test "grouped methods share their configured bucket" do
    Enum.each(@grouped_methods, fn %{tier: tier, method: method, group: group} ->
      assert_grouped_spec(method, tier, group)
    end)
  end

  test "special methods enforce documented quotas" do
    Enum.each(@special_methods, fn {method, expect} ->
      assert_special_spec(method, Map.put_new(expect, :tier, :special))
    end)
  end

  test "categorized data matches the issue #5 method list" do
    expected =
      @workspace_methods
      |> Map.values()
      |> List.flatten()
      |> Kernel.++(Enum.map(@channel_methods, & &1.method))
      |> Kernel.++(Enum.map(@grouped_methods, & &1.method))
      |> Kernel.++(Map.keys(@special_methods))
      |> MapSet.new()

    assert expected == MapSet.new(@issue_methods)
  end

  defp assert_default_spec(method, tier) do
    assert {:ok, spec} = TierRegistry.lookup(method)
    defaults = Map.fetch!(@tier_defaults, tier)

    assert spec.tier == tier
    assert spec.scope == :workspace
    assert spec.window_ms == defaults.window_ms
    assert spec.max_calls == defaults.max_calls
    assert spec.group == nil
    assert spec.burst_ratio == 0.25
    assert spec.initial_fill_ratio == 0.5
  end

  defp assert_channel_spec(method, tier, channel_field) do
    assert {:ok, spec} = TierRegistry.lookup(method)
    defaults = Map.fetch!(@tier_defaults, tier)

    assert spec.tier == tier
    assert spec.scope == {:channel, channel_field}
    assert spec.window_ms == defaults.window_ms
    assert spec.max_calls == defaults.max_calls
  end

  defp assert_grouped_spec(method, tier, group) do
    assert {:ok, spec} = TierRegistry.lookup(method)
    defaults = Map.fetch!(@tier_defaults, tier)

    assert spec.tier == tier
    assert spec.group == group
    assert spec.window_ms == defaults.window_ms
    assert spec.max_calls == defaults.max_calls
  end

  defp assert_special_spec(method, expect) do
    assert {:ok, spec} = TierRegistry.lookup(method)

    assert spec.tier == expect.tier
    assert spec.window_ms == expect.window_ms
    assert spec.max_calls == expect.max_calls

    if scope = Map.get(expect, :scope) do
      assert spec.scope == scope
    end

    if burst = Map.get(expect, :burst_ratio) do
      assert spec.burst_ratio == burst
    end

    if initial = Map.get(expect, :initial_fill_ratio) do
      assert spec.initial_fill_ratio == initial
    end
  end
end
