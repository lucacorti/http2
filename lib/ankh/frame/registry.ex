defmodule Ankh.Frame.Registry do
  @moduledoc """
  Frame registry
  """

  alias Ankh.{Connection, Frame}

  alias Ankh.Frame.{
    Continuation,
    Data,
    GoAway,
    Headers,
    Ping,
    Priority,
    PushPromise,
    RstStream,
    Settings,
    WindowUpdate
  }

  @doc """
  Returns frame struct for the given HTTP/2 frame type code

  Codes 0-9 are reserved for standard frame types.
  """
  @spec frame_for_type(Connection.connection() | nil, integer) :: Frame.t() | nil
  def frame_for_type(_, 0x0), do: Data
  def frame_for_type(_, 0x1), do: Headers
  def frame_for_type(_, 0x2), do: Priority
  def frame_for_type(_, 0x3), do: RstStream
  def frame_for_type(_, 0x4), do: Settings
  def frame_for_type(_, 0x5), do: PushPromise
  def frame_for_type(_, 0x6), do: Ping
  def frame_for_type(_, 0x7), do: GoAway
  def frame_for_type(_, 0x8), do: WindowUpdate
  def frame_for_type(_, 0x9), do: Continuation

  def frame_for_type(connection, type) when is_integer(type) and type > 9 and type < 256 do
    case Registry.meta(__MODULE__, {connection, type}) do
      {:ok, type} ->
        type
      :error ->
        nil
    end
  end

  @doc """
  Registers a custom Frame struct for the given HTTP/2 frame type code

  Codes 0-9 are reserved for standard frame types.
  """
  @spec register(Connection.connection(), integer, Frame.t()) :: :ok
  def register(connection, type, frame)
      when is_integer(type) and type > 9 and type < 256 do
    Registry.put_meta(__MODULE__, {connection, type}, frame)
  end
end
