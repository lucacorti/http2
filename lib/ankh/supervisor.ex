defmodule Ankh.Supervisor do
  @moduledoc false

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    [
      {Registry, keys: :unique, name: Ankh.Frame.Registry},
      {Registry, keys: :unique, name: Ankh.Stream.Registry}
    ]
    |> Supervisor.init(strategy: :one_for_one)
  end
end
