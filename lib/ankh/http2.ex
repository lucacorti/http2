defmodule Ankh.HTTP2 do
  @moduledoc false

  alias Ankh.{HTTP2, Protocol, Transport}
  alias HPack.Table
  alias HTTP2.Frame
  alias HTTP2.Stream, as: HTTP2Stream

  @opaque t :: %__MODULE__{
            buffer: iodata(),
            concurrent_streams: non_neg_integer(),
            last_stream_id: HTTP2Stream.id(),
            last_local_stream_id: HTTP2Stream.id(),
            last_remote_stream_id: HTTP2Stream.id(),
            recv_hbf_type: HTTP2Stream.hbf_type(),
            recv_hpack: Table.t(),
            recv_settings: Keyword.t(),
            references: %{HTTP2Stream.id() => reference()},
            send_hpack: Table.t(),
            send_queue: :queue.queue(Frame.t()),
            send_settings: Keyword.t(),
            streams: %{HTTP2Stream.id() => HTTP2Stream.t()},
            transport: Transport.t(),
            uri: URI.t(),
            window_size: integer()
          }
  defstruct buffer: <<>>,
            concurrent_streams: 0,
            last_stream_id: 0,
            last_local_stream_id: 0,
            last_remote_stream_id: 0,
            recv_hbf_type: nil,
            recv_hpack: nil,
            recv_settings: [],
            references: %{},
            send_hpack: nil,
            send_queue: :queue.new(),
            send_settings: [],
            streams: %{},
            transport: nil,
            uri: nil,
            window_size: 0

  defimpl Protocol do
    alias Ankh.Transport
    alias Ankh.HTTP.{Request, Response}
    alias Ankh.HTTP2.Frame
    alias Ankh.HTTP2.Stream, as: HTTP2Stream

    alias Frame.{
      Data,
      GoAway,
      Headers,
      Ping,
      Priority,
      RstStream,
      Settings,
      Splittable,
      WindowUpdate
    }

    alias HPack.Table

    import Ankh.HTTP2.Stream, only: [is_local_stream: 2]

    require Logger

    @active_stream_states [:open, :half_closed_local, :half_closed_remote]

    @connection_preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

    @initial_header_table_size 4_096
    @initial_concurrent_streams 128
    @initial_frame_size 16_384
    @initial_window_size 65_535
    @max_window_size 2_147_483_647
    @max_frame_size 16_777_215

    @default_settings [
      header_table_size: @initial_header_table_size,
      enable_push: true,
      max_concurrent_streams: @initial_concurrent_streams,
      initial_window_size: @initial_window_size,
      max_frame_size: @initial_frame_size,
      max_header_list_size: 128
    ]

    def new(protocol, options) do
      settings = Keyword.get(options, :settings, [])
      recv_settings = Keyword.merge(@default_settings, settings)
      header_table_size = Keyword.get(recv_settings, :header_table_size)

      with send_hpack <- Table.new(@initial_header_table_size),
           recv_hpack <- Table.new(header_table_size) do
        {:ok,
         %{
           protocol
           | send_hpack: send_hpack,
             send_settings: @default_settings,
             recv_hpack: recv_hpack,
             recv_settings: recv_settings,
             window_size: @initial_window_size
         }}
      end
    end

    def accept(protocol, uri, transport, options) do
      {timeout, options} = Keyword.pop(options, :connect_timeout, 5_000)

      with {:ok, @connection_preface} <- Transport.recv(transport, 24, timeout),
           {:ok, transport} <- Transport.accept(transport, options),
           {:ok, protocol} <- send_settings(%{protocol | transport: transport}) do
        {:ok, %{protocol | uri: uri}}
      else
        _ ->
          {:error, :protocol_error}
      end
    end

    def connect(protocol, uri, transport) do
      with :ok <- Transport.send(transport, @connection_preface),
           {:ok, protocol} <-
             send_settings(%{protocol | last_local_stream_id: -1, transport: transport, uri: uri}) do
        {:ok, protocol}
      end
    end

    def error(protocol) do
      with {:ok, protocol} <- send_error(protocol, :protocol_error) do
        {:ok, protocol}
      end
    end

    def stream(%{buffer: buffer, transport: transport} = protocol, msg) do
      with {:ok, data} <- Transport.handle_msg(transport, msg),
           {:ok, protocol, responses} <- process_buffer(%{protocol | buffer: buffer <> data}) do
        {:ok, protocol, Enum.reverse(responses)}
      end
    end

    def request(
          %{uri: %{authority: authority, scheme: scheme}} = protocol,
          %{method: method, path: path} = request
        ) do
      request =
        request
        |> Request.put_header(":method", Atom.to_string(method))
        |> Request.put_header(":authority", authority)
        |> Request.put_header(":scheme", scheme)
        |> Request.put_header(":path", path)

      with {:ok, protocol, %{reference: reference} = stream} <- get_stream(protocol, nil),
           {:ok, protocol} <- send_headers(protocol, stream, request),
           {:ok, protocol} <- send_data(protocol, stream, request),
           {:ok, protocol} <- send_trailers(protocol, stream, request) do
        {:ok, protocol, reference}
      end
    end

    def respond(protocol, reference, %{status: status} = response) do
      response = Response.put_header(response, ":status", Integer.to_string(status))

      with {:ok, protocol, stream} <- get_stream(protocol, reference),
           {:ok, protocol} <- send_headers(protocol, stream, response),
           {:ok, protocol} <- send_data(protocol, stream, response),
           {:ok, protocol} <- send_trailers(protocol, stream, response) do
        {:ok, protocol}
      end
    end

    defp process_buffer(%{buffer: buffer, recv_settings: recv_settings} = protocol) do
      max_frame_size =
        recv_settings
        |> Keyword.fetch!(:max_frame_size)
        |> min(@max_frame_size)

      buffer
      |> Frame.stream()
      |> Enum.reduce_while({:ok, protocol, []}, fn
        {rest, nil}, {:ok, protocol, responses} ->
          {:halt, {:ok, %{protocol | buffer: rest}, responses}}

        {_rest, {length, _type, _id, _data}}, {:ok, protocol, _responses}
        when length > max_frame_size ->
          {:halt, send_error(protocol, :frame_size_error)}

        {_rest, {_length, _type, id, _data}},
        {:ok, %{last_local_stream_id: llid, last_remote_stream_id: lrid}, _responses}
        when not is_local_stream(llid, id) and id < lrid ->
          {:halt, send_error(protocol, :protocol_error)}

        {rest, {_length, type, _id, data}},
        {:ok, %{recv_hbf_type: recv_hbf_type} = protocol, responses} ->
          with {:ok, type} <- Frame.Registry.frame_for_type(protocol, type),
               {:ok, frame} <- Frame.decode(struct(type), data),
               {:ok, protocol, responses} <- recv_frame(protocol, frame, responses) do
            {:cont, {:ok, %{protocol | buffer: rest}, responses}}
          else
            {:error, :not_found} when not is_nil(recv_hbf_type) ->
              {:halt, {:error, :protocol_error}}

            {:error, :not_found} ->
              {:cont, {:ok, %{protocol | buffer: rest}, responses}}

            {:error, reason} ->
              send_error(protocol, reason)
              {:halt, {:error, reason}}
          end
      end)
    end

    defp get_stream(%{references: references} = protocol, reference)
         when is_reference(reference),
         do: get_stream(protocol, Map.get(references, reference))

    defp get_stream(%{last_local_stream_id: last_local_stream_id} = protocol, nil = _id) do
      stream_id = last_local_stream_id + 2

      with {:ok, protocol, stream} <- new_stream(protocol, stream_id) do
        {:ok, %{protocol | last_local_stream_id: stream_id}, stream}
      end
    end

    defp get_stream(
           %{
             last_local_stream_id: last_local_stream_id,
             streams: streams
           } = protocol,
           stream_id
         ) do
      case Map.get(streams, stream_id) do
        stream when not is_nil(stream) ->
          {:ok, protocol, stream}

        nil when not is_local_stream(last_local_stream_id, stream_id) ->
          with {:ok, protocol, stream} <- new_stream(protocol, stream_id) do
            {:ok, protocol, stream}
          end

        _ ->
          {:error, :protocol_error}
      end
    end

    defp new_stream(
           %{references: references, send_settings: send_settings, streams: streams} = protocol,
           stream_id
         ) do
      window_size = Keyword.get(send_settings, :initial_window_size)
      %HTTP2Stream{reference: reference} = stream = HTTP2Stream.new(stream_id, window_size)

      {
        :ok,
        %{
          protocol
          | references: Map.put(references, reference, stream_id),
            streams: Map.put(streams, stream_id, stream)
        },
        stream
      }
    end

    defp send_frame(%{transport: transport} = protocol, %{stream_id: 0} = frame) do
      with {:ok, frame, data} <- Frame.encode(frame),
           :ok <- Transport.send(transport, data) do
        Logger.debug(fn -> "SENT #{inspect(frame)}" end)
        {:ok, protocol}
      end
    end

    defp send_frame(%{send_queue: send_queue} = protocol, frame),
      do: process_send_queue(%{protocol | send_queue: :queue.in(frame, send_queue)})

    defp process_send_queue(%{send_queue: send_queue} = protocol) do
      fn -> {protocol, send_queue} end
      |> Stream.resource(
        fn {protocol, queue} ->
          with {:value, frame} <- :queue.peek(queue),
               max_frame_size when max_frame_size > 0 <- frame_size_for(protocol, frame),
               {{:value, frame}, queue} <- :queue.out(queue),
               {:ok, protocol, []} <-
                 process_queued_frame(%{protocol | send_queue: queue}, frame, max_frame_size) do
            {[protocol], {protocol, queue}}
          else
            {:ok, protocol, frames} ->
              protocol =
                Enum.reduce(frames, protocol, fn frame, %{send_queue: queue} = protocol ->
                  %{protocol | send_queue: :queue.in_r(frame, queue)}
                end)

              {[protocol], {protocol, :queue.new()}}

            max_frame_size when is_integer(max_frame_size) and max_frame_size <= 0 ->
              {:halt, protocol}

            :empty ->
              {:halt, protocol}

            {:empty, _queue} ->
              {:halt, protocol}

            {:error, _reason} ->
              {:halt, protocol}
          end
        end,
        fn _protocol -> :ok end
      )
      |> Enum.reduce({:ok, protocol}, fn protocol, _acc -> {:ok, protocol} end)
    end

    defp process_queued_frame(
           %{send_hpack: send_hpack} = protocol,
           %Headers{payload: %{hbf: headers} = payload} = frame,
           size
         )
         when is_list(headers) do
      headers
      |> HPack.encode(send_hpack)
      |> case do
        {:ok, send_hpack, hbf} ->
          process_queued_frame(
            %{protocol | send_hpack: send_hpack},
            %{frame | payload: %{payload | hbf: hbf}},
            size
          )

        _ ->
          {:error, :compression_error}
      end
    end

    defp process_queued_frame(%{send_queue: send_queue} = protocol, %Data{} = frame, size)
         when size <= 0 do
      {:ok, %{protocol | send_queue: :queue.in_r(frame, send_queue)}}
    end

    defp process_queued_frame(protocol, %{stream_id: stream_id} = frame, size) do
      frame
      |> Splittable.split(size)
      |> Enum.reduce_while({:ok, protocol, []}, fn
        %Data{length: length} = frame, {:ok, protocol, frames} ->
          with {:ok, %{window_size: window_size} = protocol, %{window_size: stream_window_size}}
               when window_size - length >= 0 and stream_window_size - length >= 0 <-
                 get_stream(protocol, stream_id),
               {:ok, protocol} <- send_stream_frame(protocol, frame) do
            {:cont, {:ok, protocol, frames}}
          else
            {:ok, protocol, _stream} ->
              {:cont, {:ok, protocol, [frame | frames]}}

            {:error, _reason} = error ->
              {:halt, error}
          end

        frame, {:ok, protocol, frames} ->
          case send_stream_frame(protocol, frame) do
            {:ok, protocol} ->
              {:cont, {:ok, protocol, frames}}

            {:error, _reason} = error ->
              {:halt, error}
          end
      end)
    end

    defp send_stream_frame(
           %{streams: streams, transport: transport} = protocol,
           %{stream_id: stream_id} = frame
         ) do
      with {:ok, frame, data} <- Frame.encode(frame),
           {:ok, protocol, stream} <- get_stream(protocol, stream_id),
           {:ok, stream} <- HTTP2Stream.send(stream, frame),
           :ok <- Transport.send(transport, data),
           {:ok, protocol} <- reduce_window_size_after_send(protocol, frame) do
        {:ok, %{protocol | streams: Map.put(streams, stream_id, stream)}}
      else
        {:error, _reason} = error ->
          error
      end
    end

    defp frame_size_for(
           %{send_settings: send_settings, window_size: window_size} = protocol,
           %Data{stream_id: stream_id}
         ) do
      with {:ok, _protocol, %{window_size: stream_window_size}} <- get_stream(protocol, stream_id) do
        send_settings
        |> Keyword.fetch!(:max_frame_size)
        |> min(@max_frame_size)
        |> min(window_size)
        |> min(stream_window_size)
      end
    end

    defp frame_size_for(%{send_settings: send_settings}, _frame) do
      send_settings
      |> Keyword.fetch!(:max_frame_size)
      |> min(@max_frame_size)
    end

    defp reduce_window_size_after_send(%{window_size: window_size} = protocol, %Data{
           length: length
         }) do
      new_window_size = window_size - length

      Logger.debug(fn ->
        "window_size after send: #{window_size} - #{length} = #{new_window_size}"
      end)

      {:ok, %{protocol | window_size: new_window_size}}
    end

    defp reduce_window_size_after_send(protocol, _frame), do: {:ok, protocol}

    defp send_settings(%{send_hpack: send_hpack, recv_settings: recv_settings} = protocol) do
      header_table_size = Keyword.get(recv_settings, :header_table_size)

      with {:ok, send_hpack} <- Table.resize(header_table_size, send_hpack),
           {:ok, protocol} <-
             send_frame(protocol, %Settings{payload: %Settings.Payload{settings: recv_settings}}) do
        {:ok, %{protocol | send_hpack: send_hpack}}
      else
        _ ->
          {:error, :compression_error}
      end
    end

    defp send_error(%{last_stream_id: last_stream_id, transport: transport} = protocol, reason) do
      with {:ok, _protocol} <-
             send_frame(protocol, %GoAway{
               payload: %GoAway.Payload{
                 last_stream_id: last_stream_id,
                 error_code: reason
               }
             }),
           {:ok, _transport} <- Transport.close(transport) do
        {:error, reason}
      end
    end

    defp send_stream_error(protocol, stream_id, reason) do
      send_frame(protocol, %RstStream{
        stream_id: stream_id,
        payload: %RstStream.Payload{error_code: reason}
      })
    end

    defp recv_frame(protocol, %{stream_id: 0} = frame, responses) do
      Logger.debug(fn -> "RECVD #{inspect(frame)}" end)
      do_recv_frame(protocol, frame, responses)
    end

    defp recv_frame(protocol, frame, responses), do: do_recv_frame(protocol, frame, responses)

    defp do_recv_frame(
           %{send_settings: send_settings} = protocol,
           %Settings{stream_id: 0, flags: %{ack: false}, payload: %{settings: settings}},
           responses
         ) do
      new_send_settings = Keyword.merge(send_settings, settings)
      old_header_table_size = Keyword.get(send_settings, :header_table_size)
      new_header_table_size = Keyword.get(new_send_settings, :header_table_size)
      old_window_size = Keyword.get(send_settings, :initial_window_size)
      new_window_size = Keyword.get(new_send_settings, :initial_window_size)

      with {:ok, protocol} <-
             send_frame(protocol, %Settings{flags: %Settings.Flags{ack: true}, payload: nil}),
           {:ok, protocol} <-
             adjust_header_table_size(protocol, old_header_table_size, new_header_table_size),
           {:ok, protocol} <-
             adjust_streams_window_size(protocol, old_window_size, new_window_size),
           {:ok, protocol} <- process_send_queue(%{protocol | send_settings: new_send_settings}) do
        {:ok, protocol, responses}
      else
        _ ->
          {:error, :compression_error}
      end
    end

    defp do_recv_frame(
           protocol,
           %Settings{stream_id: 0, length: 0, flags: %{ack: true}},
           responses
         ),
         do: {:ok, protocol, responses}

    defp do_recv_frame(_protocol, %Settings{stream_id: 0, flags: %{ack: true}}, _responses),
      do: {:error, :frame_size_error}

    defp do_recv_frame(protocol, %Ping{stream_id: 0, length: 8, flags: %{ack: true}}, responses),
      do: {:ok, protocol, responses}

    defp do_recv_frame(_protocol, %Ping{stream_id: 0, length: length}, _responses)
         when length != 8,
         do: {:error, :frame_size_error}

    defp do_recv_frame(
           protocol,
           %Ping{stream_id: 0, flags: %{ack: false} = flags} = frame,
           responses
         ) do
      with {:ok, protocol} <- send_frame(protocol, %Ping{frame | flags: %{flags | ack: true}}),
           do: {:ok, protocol, responses}
    end

    defp do_recv_frame(_protocol, %WindowUpdate{stream_id: 0, length: length}, _responses)
         when length != 4,
         do: {:error, :frame_size_error}

    defp do_recv_frame(
           protocol,
           %WindowUpdate{stream_id: 0, payload: %{increment: 0}},
           _responses
         ),
         do: send_error(protocol, :protocol_error)

    defp do_recv_frame(
           %{window_size: window_size} = _protocol,
           %WindowUpdate{stream_id: 0, payload: %{increment: increment}},
           _responses
         )
         when window_size + increment > @max_window_size do
      new_window_size = window_size + increment

      Logger.error(fn ->
        "WINDOW_UPDATE window_size: #{new_window_size} larger than max_window_size #{
          @max_window_size
        }"
      end)

      {:error, :flow_control_error}
    end

    defp do_recv_frame(
           %{window_size: window_size} = protocol,
           %WindowUpdate{stream_id: 0, payload: %{increment: increment}},
           responses
         ) do
      new_window_size = window_size + increment

      Logger.debug(fn ->
        "WINDOW_UPDATE window_size: #{window_size} + #{increment} = #{new_window_size}"
      end)

      with {:ok, protocol} <- process_send_queue(%{protocol | window_size: new_window_size}) do
        {:ok, protocol, responses}
      end
    end

    defp do_recv_frame(
           _protocol,
           %GoAway{stream_id: 0, payload: %{error_code: reason}},
           _responses
         ),
         do: {:error, reason}

    defp do_recv_frame(%{stream_id: 0} = _frame, _protocol, _responses),
      do: {:error, :protocol_error}

    defp do_recv_frame(protocol, %{stream_id: stream_id} = frame, responses) do
      with {:ok, %{streams: streams} = protocol, %{state: old_state} = stream} <-
             get_stream(protocol, stream_id),
           {:ok, %{state: new_state, recv_hbf_type: recv_hbf_type} = stream, response} <-
             HTTP2Stream.recv(stream, frame),
           {:ok, protocol} <-
             check_stream_limit(
               %{
                 protocol
                 | recv_hbf_type: recv_hbf_type,
                   streams: Map.put(streams, stream_id, stream)
               },
               old_state,
               new_state
             ),
           {:ok, protocol} <-
             calculate_last_stream_ids(protocol, frame),
           {:ok, protocol, responses} <-
             process_stream_response(protocol, frame, responses, response),
           {:ok, protocol} <- process_window_update(protocol, frame) do
        {:ok, protocol, responses}
      else
        {:error, reason}
        when reason in [:protocol_error, :compression_error, :stream_closed, :refused_stream] ->
          {:error, reason}

        {:error, reason} ->
          send_stream_error(protocol, stream_id, reason)
          {:ok, protocol, responses}
      end
    end

    defp check_stream_limit(
           %{send_settings: send_settings, concurrent_streams: concurrent_streams} = protocol,
           :idle,
           new_state
         )
         when new_state in @active_stream_states do
      send_settings
      |> Keyword.get(:max_concurrent_streams)
      |> case do
        max_concurrent_streams when max_concurrent_streams > concurrent_streams ->
          {:ok, %{protocol | concurrent_streams: concurrent_streams + 1}}

        _ ->
          {:error, :refused_stream}
      end
    end

    defp check_stream_limit(
           %{concurrent_streams: concurrent_streams} = protocol,
           old_state,
           _new_state
         )
         when old_state in @active_stream_states,
         do: {:ok, %{protocol | concurrent_streams: concurrent_streams - 1}}

    defp check_stream_limit(protocol, _old_state, _new_state), do: {:ok, protocol}

    defp calculate_last_stream_ids(
           %{last_stream_id: lsid, last_local_stream_id: llid} = protocol,
           %{stream_id: stream_id} = _frame
         )
         when is_local_stream(llid, stream_id) do
      llid = max(llid, stream_id)
      {:ok, %{protocol | last_local_stream_id: llid, last_stream_id: max(llid, lsid)}}
    end

    defp calculate_last_stream_ids(protocol, %Priority{} = _frame), do: {:ok, protocol}

    defp calculate_last_stream_ids(
           %{last_stream_id: lsid, last_remote_stream_id: lrid} = protocol,
           %{stream_id: stream_id} = _frame
         ) do
      lrid = max(lrid, stream_id)
      {:ok, %{protocol | last_remote_stream_id: lrid, last_stream_id: max(lrid, lsid)}}
    end

    defp process_window_update(protocol, %WindowUpdate{}), do: process_send_queue(protocol)
    defp process_window_update(protocol, _frame), do: {:ok, protocol}

    defp process_stream_response(
           protocol,
           %{length: 0},
           responses,
           {:data, _ref, _hbf, _end_stream} = response
         ),
         do: {:ok, protocol, [response | responses]}

    defp process_stream_response(
           protocol,
           %{length: length, stream_id: stream_id},
           responses,
           {:data, _ref, _hbf, _end_stream} = response
         ) do
      window_update = %WindowUpdate{payload: %WindowUpdate.Payload{increment: length}}

      with {:ok, protocol} <- send_frame(protocol, window_update),
           {:ok, protocol} <- send_frame(protocol, %{window_update | stream_id: stream_id}) do
        {:ok, protocol, [response | responses]}
      end
    end

    defp process_stream_response(
           protocol,
           _frame,
           responses,
           {_type, _ref, [<<>>], _end_stream} = response
         ),
         do: {:ok, protocol, [response | responses]}

    defp process_stream_response(
           %{recv_hpack: recv_hpack, send_settings: send_settings} = protocol,
           _frame,
           responses,
           {type, ref, hbf, end_stream}
         )
         when type in [:headers, :push_promise] do
      max_header_table_size = Keyword.get(send_settings, :header_table_size)

      hbf
      |> Enum.join()
      |> HPack.decode(recv_hpack, max_header_table_size)
      |> case do
        {:ok, recv_hpack, headers} ->
          {
            :ok,
            %{protocol | recv_hpack: recv_hpack},
            [{type, ref, headers, end_stream} | responses]
          }

        _ ->
          {:error, :compression_error}
      end
    end

    defp process_stream_response(protocol, _frame, responses, nil),
      do: {:ok, protocol, responses}

    defp process_stream_response(protocol, _frame, responses, response),
      do: {:ok, protocol, [response | responses]}

    defp send_headers(protocol, %{id: stream_id}, %{
           headers: headers,
           body: body
         }) do
      send_frame(protocol, %Headers{
        stream_id: stream_id,
        flags: %Headers.Flags{end_stream: IO.iodata_length(body) == 0},
        payload: %Headers.Payload{hbf: headers}
      })
    end

    defp send_data(protocol, _stream, %{body: []}), do: {:ok, protocol}

    defp send_data(protocol, %{id: stream_id}, %{body: body, trailers: trailers}) do
      send_frame(protocol, %Data{
        stream_id: stream_id,
        flags: %Data.Flags{end_stream: Enum.empty?(trailers)},
        payload: %Data.Payload{data: body}
      })
    end

    defp send_trailers(protocol, _stream, %{trailers: []}), do: {:ok, protocol}

    defp send_trailers(protocol, %{id: stream_id}, %{trailers: trailers}) do
      send_frame(protocol, %Headers{
        stream_id: stream_id,
        flags: %Headers.Flags{end_stream: true},
        payload: %Headers.Payload{hbf: trailers}
      })
    end

    defp adjust_header_table_size(%{send_hpack: send_hpack} = protocol, old_size, new_size) do
      new_size
      |> Table.resize(send_hpack, old_size)
      |> case do
        {:ok, send_hpack} -> {:ok, %{protocol | send_hpack: send_hpack}}
        _ -> {:error, :compression_error}
      end
    end

    defp adjust_streams_window_size(
           %{streams: streams} = protocol,
           old_window_size,
           new_window_size
         ) do
      streams =
        Enum.reduce(streams, streams, fn {id, stream}, streams ->
          stream = HTTP2Stream.adjust_window_size(stream, old_window_size, new_window_size)
          Map.put(streams, id, stream)
        end)

      {:ok, %{protocol | streams: streams}}
    end
  end
end
