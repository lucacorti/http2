defmodule Ankh.Frame.RstStream do
  @moduledoc """
  HTTP/2 RST_STREAM frame struct
  """

  alias __MODULE__.Payload
  use Ankh.Frame, type: 0x3, flags: nil, payload: %Payload{}
end
