##
# Copyright (C) 2021  Valentin Lorentz
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License version 3,
# as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
###

defmodule M51.MatrixClient.State do
  @moduledoc """
    Stores the state of a Matrix client (access token, joined rooms, ...)
  """

  require Logger

  defstruct [
    :rooms,
    # current value of the 'since' parameter to /_matrix/client/r0/sync
    poll_since: nil,
    # events handled since the last update to :poll_since (the poller updates
    # this set as it handles events in a batch; then updates :poll_since
    # an resets this set when it is done with a batch).
    # Stored as a Map from room ids to the set of event ids.
    handled_events: Map.new(),
    # %{channel name => list of callbacks to run when a room
    #                   with that channel name is completely synced }
    channel_sync_callbacks: Map.new()
  ]

  use Agent

  @emptyroom %M51.Matrix.RoomState{}

  def start_link(opts) do
    {sup_pid} = opts

    Agent.start_link(fn -> %M51.MatrixClient.State{rooms: %{}} end,
      name: {:via, Registry, {M51.Registry, {sup_pid, :matrix_state}}}
    )
  end

  defp update_room(pid, room_id, fun) do
    Agent.update(pid, fn state ->
      room = Map.get(state.rooms, room_id, @emptyroom)
      room = fun.(room)
      %{state | rooms: Map.put(state.rooms, room_id, room)}
    end)
  end

  def set_room_canonical_alias(pid, room_id, new_canonical_alias) do
    Agent.get_and_update(pid, fn state ->
      room = Map.get(state.rooms, room_id, @emptyroom)
      old_canonical_alias = room.canonical_alias
      room = %{room | canonical_alias: new_canonical_alias}

      remaining_callbacks = state.channel_sync_callbacks

      remaining_callbacks =
        if room.synced do
          {room_callbacks, remaining_callbacks} =
            Map.pop(remaining_callbacks, room.canonical_alias, [])

          room_callbacks |> Enum.map(fn cb -> cb.(room_id, room) end)
          remaining_callbacks
        else
          remaining_callbacks
        end

      {old_canonical_alias,
       %{
         state
         | rooms: Map.put(state.rooms, room_id, room),
           channel_sync_callbacks: remaining_callbacks
       }}
    end)
  end

  # Given info about a bridge endpoint, set the room's user-facing name, bridge
  # info, and bridge-derived alias from it.
  def set_room_bridge_info(pid, room_id, info) do
    update_room(pid, room_id, fn room ->
      Logger.debug("set_room_brige_info " <> Kernel.inspect(room) <> " <- " <> Kernel.inspect(info))
      %{room | bridge_info: info}
    end)
  end

  def room_canonical_alias(pid, room_id) do
    Agent.get(pid, fn state -> Map.get(state.rooms, room_id, @emptyroom).canonical_alias end)
  end

  @doc """
    Adds a member to the room and returns true iff it was already there

    `member` must be a `M51.Matrix.RoomMember` structure.
  """
  def room_member_add(pid, room_id, userid, member) do
    Agent.get_and_update(pid, fn state ->
      room = Map.get(state.rooms, room_id, @emptyroom)

      if Map.has_key?(room.members, userid) do
        {true, state}
      else
        room = %{room | members: Map.put(room.members, userid, member)}
        {false, %{state | rooms: Map.put(state.rooms, room_id, room)}}
      end
    end)
  end

  @doc """
    Removes a member from the room and returns true iff it was already there
  """
  def room_member_del(pid, room_id, userid) do
    Agent.get_and_update(pid, fn state ->
      room = Map.get(state.rooms, room_id, @emptyroom)

      if Map.has_key?(room.members, userid) do
        room = %{room | members: Map.delete(room.members, userid)}
        {true, %{state | rooms: Map.put(state.rooms, room_id, room)}}
      else
        {false, state}
      end
    end)
  end

  @doc """
    Returns [member: %{room_id => %M51.Matrix.RoomMember{...}}]
  """
  def user(pid, user_id) do
    Agent.get(pid, fn state ->
      [
        member:
          state.rooms
          |> Map.to_list()
          |> Enum.map(fn {room_id, room} -> {room_id, Map.get(room.members, user_id)} end)
          |> Enum.filter(fn {_room_id, member} -> member != nil end)
          |> Map.new()
      ]
    end)
  end

  @doc """
    Returns %{user_id => %M51.Matrix.RoomMember{...}}
  """
  def room_members(pid, room_id) do
    Agent.get(pid, fn state -> Map.get(state.rooms, room_id, @emptyroom).members end)
  end

  @doc """
    Returns a M51.Matrix.RoomMember structure or nil
  """
  def room_member(pid, room_id, user_id) do
    Agent.get(pid, fn state ->
      members = Map.get(state.rooms, room_id, @emptyroom).members
      Map.get(members, user_id)
    end)
  end

  @doc """
    Returns a stream of Matrix room info tuples suitable for use with IRC LIST,
    in the format { IRC channel name, user count, topic }
  """
  def list_rooms(pid) do
    Agent.get(pid, fn state -> Map.to_list(state.rooms) end)
    |> Stream.filter(fn {_k, room} -> room.type != "m.space" end)
    |> Stream.map(fn kv -> _room_to_322(kv) end)
  end

  defp _room_to_322({room_id, room}) do
    { _irc_channel_from_room(room_id, room),
      "#{Kernel.map_size(room.members)}",
      case room.topic do
        { topic, _, _ } -> topic
        _ -> ""
      end
    }
  end

  def set_room_name(pid, room_id, name) do
    update_room(pid, room_id, fn room -> %{room | name: name} end)
  end

  def room_name(pid, room_id) do
    Agent.get(pid, fn state -> Map.get(state.rooms, room_id, @emptyroom).name end)
  end

  def set_room_topic(pid, room_id, topic) do
    update_room(pid, room_id, fn room -> %{room | topic: topic} end)
  end

  def room_topic(pid, room_id) do
    Agent.get(pid, fn state -> Map.get(state.rooms, room_id, @emptyroom).topic end)
  end

  def set_room_type(pid, room_id, type) do
    update_room(pid, room_id, fn room -> %{room | type: type} end)
  end

  def room_type(pid, room_id) do
    Agent.get(pid, fn state -> Map.get(state.rooms, room_id, @emptyroom).type end)
  end

  @doc """
    Returns the IRC channel name for the room
  """
  def room_irc_channel(pid, room_id) do
    Agent.get(pid, fn state -> _irc_channel_from_room(room_id, Map.get(state.rooms, room_id, @emptyroom)) end)
  end

  # Try to come up with a sensible IRC channel name for the room.
  # If it has a canonical alias, we always use that.
  # If it doesn't, but it does have bridge info, we use that, constructing
  # a localpart from the bridge-side name, local display name, or room_id, in
  # that order.
  # If none of these are available we just use the room_id.
  # We also make sure it has a suitable channel prefix.
  defp _irc_channel_from_room(room_id, room) do
    canonical_alias = room.canonical_alias
    bridge_info = room.bridge_info
    cond do
      canonical_alias -> canonical_alias
      bridge_info -> _irc_channel_from_bridge(room_id, room.name, bridge_info)
      true -> room_id
    end
  end

  # Produce a human-readable name for a bridged channel.
  # Uses the bridge info to generate the remotepart; tries to generate the
  # localpart from the bridge info, but if it can't falls back to local display
  # name, then mxid localpart.
  defp _irc_channel_from_bridge(room_id, room_name, bridge_info) do
    _localpart_from_bridge(room_id, room_name, bridge_info.channel.name)
      <> ":"
      <> _remotepart_from_bridge(bridge_info)
  end

  defp _localpart_from_bridge(room_id, room_name, bridged_name) do
    cond do
      bridged_name -> _room_name_to_irc(bridged_name)
      room_name -> _room_name_to_irc(room_name)
      true -> String.replace(room_id, ~r/:.*$/, "")
    end
  end

  # Turn a name from a bridge into something IRC can compass.
  # At present this means replacing some reserved characters, and then slapping
  # a chanprefix on the start if it doesn't have one.
  # TODO: the chanprefix logic will need to be changed when we implement DMs.
  defp _room_name_to_irc(name) do
    name = String.replace(name, ~r/[@ :]/, "-")
    cond do
      String.match?(name, ~r/^[#!&@]/) -> name
      true -> "@" <> name
    end
  end

  defp _remotepart_from_bridge(info) do
    # TODO: this should be provided in a config file, or via a command from the
    # client.
    protocols = %{
      "discordgo" => "discord",
      "googlechat" => "gchat",
    }
    networks = %{
      # Add network mappings here for bridged networks. This should be mapping
      # of network ID to IRC-friendly human-readable name. We'll fall back to
      # the network display name if needed but the name is often quite long
      # and doesn't squish down comfortably.
      # TODO: in addition to the above, this should be scoped per protocol.
    }
    network = case Map.get(networks, info.network.id, info.network.name) do
      nil -> nil
      network -> String.replace(network, ~r/[^a-zA-Z0-9_-]+/, "-")
    end
    protocol = String.replace(
      Map.get(protocols, info.protocol.id, info.protocol.name),
      ~r/[^a-zA-Z0-9_-]+/, "-")
    case network do
      nil -> "#{protocol}"
      _ -> "#{network}.#{protocol}"
    end
  end

  @doc """
    Returns the {room_id, room} corresponding the to given channel name, or nil.
  """
  def room_from_irc_channel(pid, channel) do
    Agent.get(pid, fn state ->
      _room_from_irc_channel(state, channel)
    end)
  end

  defp _room_from_irc_channel(state, channel) do
    state.rooms
    |> Map.to_list()
    |> Enum.find_value(fn {room_id, room} ->
      # The canonical alias (if set) and mxid can always be used to refer to a room,
      # even if that's not how it appears on IRC.
      if room.canonical_alias == channel || room_id == channel || _irc_channel_from_room(room_id, room) == channel do
        {room_id, room}
      else
        nil
      end
    end)
  end

  @doc """
    Takes a callback to run as soon as the room matching the given channel name
    is completely synced.
  """
  def queue_on_channel_sync(pid, channel, callback) do
    Agent.update(pid, fn state ->
      case _room_from_irc_channel(state, channel) do
        {room_id, %M51.Matrix.RoomState{synced: true} = room} ->
          # We already have the room, call immediately
          callback.(room_id, room)
          state

        _ ->
          # We don't have the member list yet, queue it.
          %{
            state
            | channel_sync_callbacks:
                Map.put(state.channel_sync_callbacks, channel, [
                  callback | Map.get(state.channel_sync_callbacks, channel, [])
                ])
          }
      end
    end)
  end

  @doc """
    Updates the state to mark a room is completely synced, and runs all callbacks
    that were waiting on it being synced.
  """
  def mark_synced(pid, room_id) do
    Agent.update(pid, fn state ->
      room = Map.get(state.rooms, room_id, @emptyroom)
      room = %{room | synced: true}
      remaining_callbacks = state.channel_sync_callbacks

      # Run callbacks registered for the room_id itself
      {room_callbacks, remaining_callbacks} = Map.pop(remaining_callbacks, room_id, [])
      room_callbacks |> Enum.map(fn cb -> cb.(room_id, room) end)

      # Run callbacks registered for the canonical alias
      remaining_callbacks =
        case room.canonical_alias do
          nil ->
            remaining_callbacks

          _ ->
            {room_callbacks, remaining_callbacks} =
              Map.pop(remaining_callbacks, room.canonical_alias, [])

            room_callbacks |> Enum.map(fn cb -> cb.(room_id, room) end)
            remaining_callbacks
        end

      %{
        state
        | rooms: Map.put(state.rooms, room_id, room),
          channel_sync_callbacks: remaining_callbacks
      }
    end)
  end

  def poll_since_marker(pid) do
    Agent.get(pid, fn state -> state.poll_since end)
  end

  def handled_events(pid, room_id) do
    Agent.get(pid, fn state -> Map.get(state.handled_events, room_id) || MapSet.new() end)
  end

  @doc """
    Updates the 'since' marker, and resets the 'handled_events' set.
  """
  def update_poll_since_marker(pid, new_since_marker) do
    Agent.update(pid, fn state ->
      %{state | poll_since: new_since_marker, handled_events: Map.new()}
    end)
  end

  def mark_handled_event(pid, room_id, event_id) do
    if event_id != nil do
      Agent.update(pid, fn state ->
        handled_events =
          Map.update(state.handled_events, room_id, nil, fn event_ids ->
            MapSet.put(event_ids || MapSet.new(), event_id)
          end)

        %{state | handled_events: handled_events}
      end)
    end
  end
end
