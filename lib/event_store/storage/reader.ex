defmodule EventStore.Storage.Reader do
  @moduledoc """
  Reads events for a given stream identity
  """

  require Logger

  alias EventStore.RecordedEvent
  alias EventStore.Sql.Statements
  alias EventStore.Storage.Reader

  @doc """
  Read events appended to a single stream forward from the given starting version
  """
  def read_forward(conn, stream_id, start_version, count) do
    case Reader.Query.read_events_forward(conn, stream_id, start_version, count) do
      {:ok, []} = reply -> reply
      {:ok, rows} -> map_rows_to_event_data(rows)
      {:error, reason} -> failed_to_read(stream_id, reason)
    end
  end

  @doc """
  Read events appended to all streams forward from the given start event id inclusive
  """
  def read_all_forward(conn, start_event_number, count) do
    case Reader.Query.read_all_events_forward(conn, start_event_number, count) do
      {:ok, []} = reply -> reply
      {:ok, rows} -> map_rows_to_event_data(rows)
      {:error, reason} -> failed_to_read_all_stream(reason)
    end
  end

  defp map_rows_to_event_data(rows) do
    {:ok, Reader.EventAdapter.to_event_data(rows)}
  end

  defp failed_to_read(stream_id, reason) do
    _ = Logger.warn(fn -> "Failed to read events from stream id #{stream_id} due to #{inspect reason}" end)
    {:error, reason}
  end

  defp failed_to_read_all_stream(reason) do
    _ = Logger.warn(fn -> "Failed to read events from all streams due to #{inspect reason}" end)
    {:error, reason}
  end

  defmodule EventAdapter do
    @moduledoc """
    Map event data from the database to `RecordedEvent` struct
    """

    def to_event_data(rows),
      do: Enum.map(rows, &to_event_data_from_row/1)

    def to_event_data_from_row([
      event_id,
      event_number,
      stream_uuid,
      stream_version,
      event_type,
      correlation_id,
      causation_id,
      data,
      metadata,
      created_at])
    do
      %RecordedEvent{
        event_id: event_id |> from_uuid(),
        event_number: event_number,
        stream_uuid: stream_uuid,
        stream_version: stream_version,
        event_type: event_type,
        correlation_id: correlation_id |> from_uuid(),
        causation_id: causation_id |> from_uuid(),
        data: data,
        metadata: metadata,
        created_at: created_at |> to_naive(),
      }
    end

    defp from_uuid(nil), do: nil
    defp from_uuid(uuid), do: UUID.binary_to_string!(uuid)

    defp to_naive(%NaiveDateTime{} = naive), do: naive
    defp to_naive(%Postgrex.Timestamp{year: year, month: month, day: day, hour: hour, min: minute, sec: second, usec: microsecond}) do
      with {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second, {microsecond,  6}) do
        naive
      end
    end
  end

  defmodule Query do
    def read_events_forward(conn, stream_id, start_version, count) do
      conn
      |> Postgrex.query(Statements.read_events_forward, [stream_id, start_version, count], pool: DBConnection.Poolboy)
      |> handle_response
    end

    def read_all_events_forward(conn, start_event_number, count) do
      conn
      |> Postgrex.query(Statements.read_all_events_forward, [start_event_number, count], pool: DBConnection.Poolboy)
      |> handle_response
    end

    defp handle_response({:ok, %Postgrex.Result{num_rows: 0}}) do
      {:ok, []}
    end

    defp handle_response({:ok, %Postgrex.Result{rows: rows}}) do
      {:ok, rows}
    end

    defp handle_response({:error, %Postgrex.Error{postgres: %{message: reason}}}) do
      _ = Logger.warn(fn -> "Failed to read events from stream due to: #{inspect reason}" end)
      {:error, reason}
    end
  end
end
