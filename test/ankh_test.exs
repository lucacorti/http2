defmodule AnkhTest do
  use ExUnit.Case

  require Logger

  doctest Ankh

  test "Ankh HTTP request" do
    url = "https://localhost:8000"
    # url = "https://www.google.com"

    assert {:ok, protocol} = Ankh.HTTP.connect(URI.parse(url))
    assert {:ok, protocol, reference} = Ankh.HTTP.request(protocol, %Ankh.HTTP.Request{})

    receive_response(protocol, reference)

    assert {:ok, protocol, reference} = Ankh.HTTP.request(protocol, %Ankh.HTTP.Request{})

    receive_response(protocol, reference)
  end

  defp receive_response(protocol, reference) do
    receive do
      msg ->
        case Ankh.HTTP.stream(protocol, msg) do
          {:other, msg} ->
            Logger.error("unknown message: #{inspect(msg)}")

          {:ok, protocol, []} ->
            receive_response(protocol, reference)

          {:ok, protocol, responses} ->
            end_stream =
              Enum.find(responses, fn
                {_type, ^reference, _data, _end_stream = true} -> true
                _ -> false
              end)

            unless end_stream do
              receive_response(protocol, reference)
            end

          error ->
            Logger.error("#{inspect(error)}")
            error
        end
    end
  end
end
