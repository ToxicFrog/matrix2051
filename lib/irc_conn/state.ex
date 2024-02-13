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

defmodule M51.IrcConn.State do
  @moduledoc """
    Stores the state of an open IRC connection.
  """
  defstruct [:sup_pid, :registered, :nick, :gecos, :capabilities, :batches, :channels]

  use Agent

  def start_link(args) do
    {sup_pid} = args

    Agent.start_link(
      fn ->
        %M51.IrcConn.State{
          sup_pid: sup_pid,
          registered: false,
          nick: nil,
          gecos: nil,
          capabilities: [],
          # %{id => {type, args, reversed_messages}}
          batches: Map.new(),
          # %{room_id => {joined: bool, synced: bool, queue: [pending messages]}}
          channels: Map.new(),
        }
      end,
      name: {:via, Registry, {M51.Registry, {sup_pid, :irc_state}}}
    )
  end

  def dump_state(pid) do
    Agent.get(pid, fn state -> state end)
  end

  @doc """
    Return {local_name, hostname}. Must be joined with ":" to get the actual nick.
  """
  def nick(pid) do
    Agent.get(pid, fn state -> state.nick end)
  end

  def set_nick(pid, nick) do
    Agent.update(pid, fn state -> %{state | nick: nick} end)
  end

  def registered(pid) do
    Agent.get(pid, fn state -> state.registered end)
  end

  def set_registered(pid) do
    Agent.update(pid, fn state -> %{state | registered: true} end)
  end

  def gecos(pid) do
    Agent.get(pid, fn state -> state.gecos end)
  end

  def set_gecos(pid, gecos) do
    Agent.update(pid, fn state -> %{state | gecos: gecos} end)
  end

  def capabilities(pid) do
    Agent.get(pid, fn state -> state.capabilities end)
  end

  def add_capabilities(pid, new_capabilities) do
    Agent.update(pid, fn state ->
      %{state | capabilities: new_capabilities ++ state.capabilities}
    end)
  end

  def batch(pid, id) do
    Agent.get(pid, fn state -> Map.get(state.batches, id) end)
  end

  @doc """
    Creates a buffer for a client-initiated batch.

    https://ircv3.net/specs/extensions/batch
    https://github.com/ircv3/ircv3-specifications/pull/454
  """
  def create_batch(pid, reference_tag, opening_command) do
    Agent.update(pid, fn state ->
      %{state | batches: state.batches |> Map.put(reference_tag, {opening_command, []})}
    end)
  end

  def add_batch_command(pid, reference_tag, command) do
    Agent.update(pid, fn state ->
      %{
        state
        | batches:
            state.batches
            |> Map.update!(reference_tag, fn batch ->
              {opening_command, reversed_commands} = batch
              {opening_command, [command | reversed_commands]}
            end)
      }
    end)
  end

  @doc """
    Removes a batch and returns it as {opening_command, messages}
  """
  def pop_batch(pid, reference_tag) do
    Agent.get_and_update(pid, fn state ->
      {batch, batches} = Map.pop(state.batches, reference_tag)
      state = %{state | batches: batches}

      # reverse commands so they are in chronological order
      {opening_command, reversed_commands} = batch
      batch = {opening_command, Enum.reverse(reversed_commands)}

      {batch, state}
    end)
  end
end
