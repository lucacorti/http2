defmodule Ankh.TCP do
  @moduledoc "TCP transport implementation"

  require Logger

  alias Ankh.Transport

  @opaque t :: %__MODULE__{socket: :gen_tcp.socket()}
  defstruct socket: nil

  defimpl Transport do
    alias Ankh.TCP

    @default_connect_options [:binary, active: false]

    def new(%TCP{} = transport, socket), do: {:ok, %{transport | socket: socket}}

    def connect(%TCP{} = transport, %URI{host: host, port: port}, timeout, options \\ []) do
      hostname = String.to_charlist(host)
      options = @default_connect_options ++ options

      with {:ok, socket} <- :gen_tcp.connect(hostname, port, options, timeout),
           :ok <- :inet.setopts(socket, active: :once) do
        {:ok, %{transport | socket: socket}}
      end
    end

    def accept(%TCP{socket: socket} = transport, options \\ []) do
      options = Keyword.merge(options, active: :once)

      with :ok <- :gen_tcp.controlling_process(socket, self()),
           :ok <- :inet.setopts(socket, options) do
        {:ok, %{transport | socket: socket}}
      end
    end

    def send(%TCP{socket: socket}, data), do: :gen_tcp.send(socket, data)

    def recv(%TCP{socket: socket}, size, timeout), do: :gen_tcp.recv(socket, size, timeout)

    def close(%TCP{socket: socket} = transport) do
      with :ok <- :gen_tcp.close(socket), do: {:ok, %{transport | socket: nil}}
    end

    def handle_msg(_tcp, {:tcp, socket, data}) do
      with :ok <- :inet.setopts(socket, active: :once), do: {:ok, data}
    end

    def handle_msg(%TCP{socket: socket}, {:tcp_error, socket, reason}), do: {:error, reason}
    def handle_msg(%TCP{socket: socket}, {:tcp_closed, socket}), do: {:error, :closed}
    def handle_msg(_tcp, msg), do: {:other, msg}

    def negotiated_protocol(_tcp), do: {:error, :protocol_not_negotiated}
  end
end
