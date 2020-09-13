defmodule Ankh.HTTP1 do
  @moduledoc false

  alias Ankh.{HTTP, Protocol, Transport}
  alias HTTP.Response

  @typep state :: :status | :headers | :body | :trailers

  @opaque t :: %__MODULE__{
            reference: reference(),
            state: state(),
            transport: Transport.t(),
            uri: URI.t()
          }
  defstruct reference: nil, transport: nil, uri: nil, state: :status

  defimpl Protocol do
    alias Ankh.HTTP.{Request, Response}

    @crlf "\r\n"

    def new(protocol, _options), do: {:ok, protocol}

    def accept(protocol, uri, transport, options) do
      with {:ok, transport} <- Transport.accept(transport, options),
           do: {:ok, %{protocol | transport: transport, uri: uri}}
    end

    def connect(protocol, uri, transport), do: {:ok, %{protocol | transport: transport, uri: uri}}
    def error(_protocol), do: :ok

    def request(%{transport: transport, uri: %URI{host: host}} = protocol, request) do
      %Request{method: method, path: path, headers: headers, body: body, trailers: trailers} =
        Request.put_header(request, "host", host)

      reference = make_ref()

      with :ok <-
             Transport.send(transport, [Atom.to_string(method), " ", path, " ", "HTTP/1.1", @crlf]),
           :ok <- send_headers(transport, headers),
           :ok <- send_body(transport, body),
           :ok <- send_trailers(transport, trailers),
           :ok <- Transport.send(transport, @crlf),
           do: {:ok, %{protocol | reference: reference}, reference}
    end

    def respond(%{transport: transport} = protocol, _request_reference, %Response{
          status: status,
          headers: headers,
          body: body,
          trailers: trailers
        }) do
      with :ok <-
             Transport.send(transport, ["HTTP/1.1 ", Integer.to_string(status), " OK", @crlf]),
           :ok <- send_headers(transport, headers),
           :ok <- Transport.send(transport, @crlf),
           :ok <- send_body(transport, body),
           :ok <- Transport.send(transport, @crlf),
           :ok <- send_trailers(transport, trailers),
           :ok <- Transport.send(transport, @crlf),
           do: {:ok, %{protocol | reference: make_ref()}}
    end

    def stream(%{transport: transport} = protocol, msg) do
      with {:ok, data} <- Transport.handle_msg(transport, msg),
           {:ok, protocol, responses} <- process_data(protocol, data) do
        {:ok, protocol, Enum.reverse(responses)}
      end
    end

    defp send_headers(transport, headers) do
      Enum.reduce(headers, :ok, fn {name, value}, _acc ->
        Transport.send(transport, [name, ": ", value, @crlf])
      end)
    end

    defp send_body(transport, body), do: Transport.send(transport, body)

    defp send_trailers(transport, trailers) do
      Enum.reduce(trailers, :ok, fn {name, value}, _acc ->
        Transport.send(transport, [name, ": ", value, @crlf])
      end)
    end

    defp process_data(protocol, data) do
      data
      |> String.split(@crlf)
      |> process_lines(protocol, [])
    end

    defp process_lines([], protocol, responses), do: {:ok, protocol, Enum.reverse(responses)}

    defp process_lines(["HTTP/1.1 " <> status | rest], %{state: :status} = protocol, responses) do
      case String.split(status, " ", parts: 2) do
        [status, _string] ->
          process_headers(rest, %{protocol | state: :headers}, [{":status", status}], responses)

        _ ->
          {:error, :invalid_status}
      end
    end

    defp process_lines([request | rest], %{state: :status} = protocol, responses) do
      case String.split(request, " ", parts: 3) do
        [method, path, "HTTP/1.1"] ->
          process_headers(
            rest,
            %{protocol | state: :headers},
            [{":method", method}, {":path", path}],
            responses
          )

        _ ->
          {:error, :invalid_request}
      end
    end

    defp process_headers(
           [] = lines,
           %{reference: reference, state: :trailers} = protocol,
           headers,
           responses
         ),
         do: process_lines(lines, protocol, [{:headers, reference, headers, true} | responses])

    defp process_headers(
           ["" | rest],
           %{reference: reference, state: :headers} = protocol,
           headers,
           responses
         ),
         do:
           process_body(rest, %{protocol | state: :body}, [], [
             {:headers, reference, Enum.reverse(headers), false} | responses
           ])

    defp process_headers(
           [header | rest],
           %{state: state} = protocol,
           headers,
           responses
         )
         when state in [:headers, :trailers] do
      case String.split(header, ":", parts: 2) do
        [name, value] ->
          process_headers(rest, protocol, [{name, value} | headers], responses)

        _body ->
          {:error, :invalid_headers}
      end
    end

    defp process_body([] = lines, %{reference: reference} = protocol, [_ | body], responses),
      do:
        process_lines(lines, protocol, [
          {:data, reference, Enum.reverse(body), true} | responses
        ])

    defp process_body(
           ["" | rest],
           %{reference: reference, state: :body} = protocol,
           [_ | body],
           responses
         ),
         do:
           process_headers(rest, %{protocol | state: :trailers}, [], [
             {:data, reference, Enum.reverse(body), false} | responses
           ])

    defp process_body(
           [data | rest],
           %{state: :body} = protocol,
           body,
           responses
         ) do
      process_body(rest, protocol, [@crlf, data | body], responses)
    end
  end
end