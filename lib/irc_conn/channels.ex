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

defmodule M51.IrcConn.Channels do
  @moduledoc """
    Stores the IRC-side state of a channel (backed by a Matrix room), and
    contains functions for communicating about channels to the client.

    A channel is created from the Matrix side, and initially has an empty queue
    and is not joined. Messages sent to it from Matrix are either dropped or
    enqueued.

    Once the IRC side issues a JOIN command, it is marked joined and any messages
    in the queue are replayed for the client.

    TODO: the matrix side should have some way of telling when it's processing
    backscroll more reliable than is_backlog, which would let us add a sync bit
    and hold off on processing joins until a channel is fully synced.
  """
  require Logger
  alias M51.IrcConn.State, as: IrcState
  alias M51.MatrixClient.State, as: MatrixState
  alias M51.Irc.Command, as: IrcCommand
  alias M51.IrcConn.Handler, as: Handler

  defstruct [
    # ID of the corresponding Matrix room.
    :room_id,
    # User has joined this channel from IRC.
    joined: false,
    # Events delivered from matrix and not yet sent to IRC.
    # These will be buffered (and older ones discarded if it gets too long)
    # until the user joins the channel *and* the channel is marked synced.
    queue: [],
  ]

  defp make_numeric(numeric, params) do
    %M51.Irc.Command{source: "server.", command: numeric, params: ["*" | params]}
  end

  defp _update_channel(pid, name, f) do
    Agent.update(pid, fn state ->
      update_in(state.channels[name], f)
    end)
  end

  def get_room_id(pid, name) do
    Agent.get(pid, fn state -> state.channels[name].room_id end)
  end

  def exists?(pid, name) do
    Agent.get(pid, fn state -> state.channels[name] != nil end)
  end

  def create(pid, name, room_id) do
    Logger.debug("create: #{name}")
    _update_channel(pid, name, fn _ -> %M51.IrcConn.Channels{room_id: room_id} end)
  end

  def delete(pid, name, send) do
    Logger.debug("delete: #{name}")
    Agent.update(pid, fn state ->
      if state.channels[name].joined do
        _part(state, name, "Channel deleted by server", send)
      end
      update_in(state.channels, fn channels -> Map.delete(channels, name) end)
    end)
  end

  def joined?(pid, name) do
    Agent.get(pid, fn state -> state.channels[name].joined end)
  end

  def join(pid, name, send, sup_pid) do
    Logger.debug("join: #{name}")
    Agent.update(pid, fn state -> _join(sup_pid, state, name, send) end)
  end

  defp _join(sup_pid, state, name, send) do
    send_numeric = fn numeric, params -> send.(make_numeric(numeric, params)) end
    send_ack = fn -> send.(%M51.Irc.Command{command: "ACK", params: []}) end
    channel = state.channels[name]

    Logger.debug("_join: #{Kernel.inspect(state)}")

    cond do
      is_nil(channel) ->
        send_numeric.("403", ["No such channel"])
        state

      channel.joined ->
        send_ack.()
        state

      # Channel exists and wasn't previously joined. Announce it, replay all
      # queued messages, and mark it joined.
      true ->
        _announce(sup_pid, state, name, send)
        channel.queue |> Enum.map(fn msg -> send.(msg) end)
        update_in(state.channels[name], fn chan -> %{chan | joined: true, queue: []} end)
    end
  end

  defp nick2nuh(nick) do
    [local_name, hostname] = String.split(nick, ":", parts: 2)
    "#{nick}!#{local_name}@#{hostname}"
  end

  defp compute_topic(sup_pid, room_id) do
    state = M51.IrcConn.Supervisor.matrix_state(sup_pid)
    name = M51.MatrixClient.State.room_name(state, room_id)
    topicwhotime = M51.MatrixClient.State.room_topic(state, room_id)

    case {name, topicwhotime} do
      {nil, nil} -> nil
      {name, nil} -> {"[" <> name <> "]", nil}
      {nil, {topic, who, time}} -> {"[] " <> topic, {who, time}}
      {name, {topic, who, time}} -> {"[" <> name <> "] " <> topic, {who, time}}
    end
  end

  defp _announce(sup_pid, irc_state, channel, send) do
    room_id = irc_state.channels[channel].room_id
    capabilities = irc_state.capabilities
    nick = irc_state.nick

    send_numeric = fn numeric, params ->
      send.(make_numeric(numeric, params))
    end

    send.(%M51.Irc.Command{
      tags: %{"account" => nick},
      source: nick2nuh(nick),
      command: "JOIN",
      params: [channel, nick, nick]
    })

    case compute_topic(sup_pid, room_id) do
      nil ->
        # RPL_NOTOPIC
        send_numeric.("331", [channel, "No topic is set"])

      {topic, whotime} ->
        # RPL_TOPIC
        send_numeric.("332", [channel, topic])

        case whotime do
          nil -> nil
          {who, time} ->
            # RPL_TOPICWHOTIME
            send_numeric.("333", [channel, who, Integer.to_string(div(time, 1000))])
        end
    end

    matrix_state = M51.IrcConn.Supervisor.matrix_state(sup_pid)
    if !Enum.member?(capabilities, :no_implicit_names) do
      # send RPL_NAMREPLY
      overhead =
        make_numeric("353", ["=", channel, ""]) |> IrcCommand.format() |> byte_size()

      # note for later: if we ever implement prefixes, make sure to add them
      # *after* calling nick2nuh; we don't want to have prefixes in the username part.
      MatrixState.room_members(matrix_state, room_id)
      |> Enum.map(fn {user_id, _member} ->
        nuh = nick2nuh(user_id)
        # M51.Irc.Command does not escape " " in trailing
        String.replace(nuh, " ", "\\s") <> " "
      end)
      |> Enum.sort()
      |> M51.Irc.WordWrap.join_tokens(512 - overhead) # TODO: can the client request long lines?
      |> Enum.map(fn line ->
        line = line |> String.trim_trailing()

        if line != "" do
          # RPL_NAMREPLY
          send_numeric.("353", ["=", channel, line])
        end
      end)
      |> Enum.filter(fn line -> line != nil end)

      # RPL_ENDOFNAMES
      send_numeric.("366", [channel, "End of /NAMES list"])
    end
  end

  def part(pid, channel, reason, send) do
    Agent.update(pid, fn state ->

      _part(state, channel, reason, send) end)
  end

  defp _part(
    state,
    name,
    reason,
    send)
  do
    send_numeric = fn numeric, params -> send.(make_numeric(numeric, params)) end
    channel = state.channels[name]
    nick = state.nick

    Logger.debug("_part: #{Kernel.inspect(state)}")

    cond do
      is_nil(channel) ->
        send_numeric.("403", ["No such channel"])
        state

      !channel.joined ->
        send_numeric.("442", ["You can't part a channel you aren't in"])
        state

      true ->
        send.(%M51.Irc.Command{
          tags: %{"account" => nick},
          source: nick2nuh(nick),
          command: "PART",
          params: [name, reason]
        })
        update_in(state.channels[name], fn chan -> %{chan | joined: false} end)
    end
  end

  # TODO: if channel was joined, deannounce/announce or rename it
  def rename(pid, old_name, new_name, send, sup_pid) do
    Logger.debug("rename: #{new_name} <- #{old_name}")
    Agent.update(pid, fn state -> _rename(state, old_name, new_name, send, sup_pid) end)
  end

  defp _rename(state, old_name, new_name, send, sup_pid) do
    supports_channel_rename = Enum.member?(state.capabilities, :channel_rename)
    channel = state.channels[old_name]
    source = "server."

    cond do
      # If the channel isn't joined, we don't need to inform the client.
      !channel.joined -> nil

      # If the client supports RENAME we just send one of those.
      supports_channel_rename ->
        send.(%M51.Irc.Command{
          source: source,
          command: "RENAME",
          params: [old_name, new_name, "Channel renamed"]
        })

      # Otherwise we have to open the new channel and close the old one.
      true ->
        _announce(sup_pid, state, new_name, send)
        _part(state, old_name, send, "Channel renamed to #{new_name}")
        send.(%M51.Irc.Command{
          source: "server.",
          command: "NOTICE",
          params: [new_name, "Channel renamed from #{old_name}"]
        })
    end

    update_in(state.channels, fn channels -> channels |> Map.delete(old_name) |> Map.put(new_name, channel) end)
  end

  def send_to(pid, name, message, write) do
    _update_channel(pid, name, fn chan -> _send_to(chan, message, write) end)
  end

  def _send_to(channel, message, write) do
    cond do
      # If we don't know about a channel of that name, we assume it's non-channel
      # traffic intended for the client and pass it through.
      is_nil(channel) ->
        write.(message)
        channel

      # Also passthrough if the channel is already joined.
      channel.joined ->
        write.(message)
        channel

      # If the channel is not joined but the message is enqueueable, we store it
      # to replay for the user when (or if) they join the channel
      _should_queue?(message) ->
        update_in(channel.queue, fn queue -> [message | queue] |> Enum.take(256) end)

      # Otherwise we just drop the message on the floor.
      true -> channel
    end
  end

  # A message is enqueueable for later if it's an actual readable message to
  # the channel. Channel metadata (topic, userlist, etc) we just drop; we'll
  # send the user a consistent view of the channel metadata if they join.
  defp _should_queue?(message) do
    message.command == "PRIVMSG" || message.command == "NOTICE"
  end
end
