defmodule EventStore.Storage.Stream do
  @moduledoc """
  Streams are an abstraction around a stream of events for a given stream identity
  """

  require Logger

  alias EventStore.Sql.Statements
  alias EventStore.Storage.{QueryLatestEventNumber,QueryLatestStreamVersion,QueryStreamInfo,Reader}

  def create_stream(conn, stream_uuid) do
    _ = Logger.debug(fn -> "Attempting to create stream \"#{stream_uuid}\"" end)

    conn
    |> Postgrex.query(Statements.create_stream, [stream_uuid], pool: DBConnection.Poolboy)
    |> handle_create_response(stream_uuid)
  end

  def read_stream_forward(conn, stream_uuid, start_version, count \\ nil) do
    execute_with_stream_id(conn, stream_uuid, fn stream_id ->
      Reader.read_forward(conn, stream_id, start_version, count)
    end)
  end

  def read_all_streams_forward(conn, start_event_number, count \\ nil) do
    Reader.read_all_forward(conn, start_event_number, count)
  end

  def latest_event_number(conn),
    do: QueryLatestEventNumber.execute(conn)

  def stream_info(conn, stream_uuid),
    do: QueryStreamInfo.execute(conn, stream_uuid)

  def latest_stream_version(conn, stream_uuid) do
    execute_with_stream_id(conn, stream_uuid, fn stream_id ->
      QueryLatestStreamVersion.execute(conn, stream_id)
    end)
  end

  defp execute_with_stream_id(conn, stream_uuid, execute_fn) do
    case lookup_stream_id(conn, stream_uuid) do
      {:ok, stream_id} -> execute_fn.(stream_id)
      response -> response
    end
  end

  defp handle_create_response({:ok, %Postgrex.Result{rows: [[stream_id]]}}, stream_uuid) do
    _ = Logger.debug(fn -> "Created stream \"#{stream_uuid}\" (id: #{stream_id})" end)
    {:ok, stream_id}
  end

  defp handle_create_response({:error, %Postgrex.Error{postgres: %{code: :unique_violation}}}, stream_uuid) do
    _ = Logger.warn(fn -> "Failed to create stream \"#{stream_uuid}\", already exists" end)
    {:error, :stream_exists}
  end

  defp handle_create_response({:error, error}, stream_uuid) do
    _ = Logger.warn(fn -> "Failed to create stream \"#{stream_uuid}\"" end)
    {:error, error}
  end

  defp lookup_stream_id(conn, stream_uuid) do
    conn
    |> Postgrex.query(Statements.query_stream_id, [stream_uuid], pool: DBConnection.Poolboy)
    |> handle_lookup_response(stream_uuid)
  end

  defp handle_lookup_response({:ok, %Postgrex.Result{num_rows: 0}}, stream_uuid) do
    _ = Logger.warn(fn -> "Attempted to access unknown stream \"#{stream_uuid}\"" end)
    {:error, :stream_not_found}
  end

  defp handle_lookup_response({:ok, %Postgrex.Result{rows: [[stream_id]]}}, _) do
    {:ok, stream_id}
  end
end
