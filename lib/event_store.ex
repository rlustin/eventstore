defmodule EventStore do
  @moduledoc """
  EventStore is CQRS event store implemented in Elixir.

  It uses PostgreSQL (v9.5 or later) as the underlying storage engine.

  The `EventStore` module provides the public API to read and write events to an event stream, and subscribe to event notifications.

  Please check the [getting started](getting-started.html) and [usage](usage.html) guides to learn more.

  ## Example usage

      # append events to a stream
      :ok = EventStore.append_to_stream(stream_uuid, expected_version, events)

      # read all events from a stream, starting at the beginning
      {:ok, recorded_events} = EventStore.read_stream_forward(stream_uuid)

  """

  @type expected_version :: :any_version | :no_stream | :stream_exists | non_neg_integer()
  @type start_from :: :origin | :current | non_neg_integer()

  alias EventStore.Snapshots.{SnapshotData,Snapshotter}
  alias EventStore.{EventData,RecordedEvent,Subscriptions}
  alias EventStore.Subscriptions.Subscription
  alias EventStore.Streams.{AllStream,Stream}

  @all_stream "$all"

  @doc """
  Append one or more events to a stream atomically.

    - `stream_uuid` is used to uniquely identify a stream.

    - `expected_version` is used for optimistic concurrency checks.
      You can provide a non-negative integer to specify the expected stream
      version. This is used to ensure you can only append to the stream if it is
      at exactly that version.

      You can also provide one of the following values to affect the concurrency
      check behaviour:

      - `:any_version` - No concurrency checking; allow any stream version
        (including no stream).
      - `:no_stream` - Ensure the stream does not exist.
      - `:stream_exists` - Ensure the stream exists.

    - `events` is a list of `%EventStore.EventData{}` structs.

  Returns `:ok` on success, or an `{:error, reason}` tagged tuple. The returned
  error may be due to one of the following reasons:

    - `{:error, :wrong_expected_version}` when the actual stream version differs
      from the provided expected version.
    - `{:error, :stream_exists}` when the stream exists, but expected version
      was `:no_stream`.
    - `{:error, :stream_does_not_exist}` when the stream does not exist, but
      expected version was `:stream_exists`.

  """
  @spec append_to_stream(String.t, expected_version, list(EventData.t), timeout()) :: :ok |
    {:error, :wrong_expected_version} |
    {:error, :stream_exists} |
    {:error, :stream_does_not_exist} |
    {:error, reason :: term}
  def append_to_stream(stream_uuid, expected_version, events, timeout \\ 5_000)
  def append_to_stream(@all_stream, _expected_version, _events, _timeout), do: {:error, :cannot_append_to_all_stream}
  def append_to_stream(stream_uuid, expected_version, events, timeout) do
    with {:ok, _stream} <- EventStore.Streams.Supervisor.open_stream(stream_uuid) do
      Stream.append_to_stream(stream_uuid, expected_version, events, timeout)
    else
      reply -> reply
    end
  end

  @doc """
  Reads the requested number of events from the given stream, in the order in which they were originally written.

    - `stream_uuid` is used to uniquely identify a stream.

    - `start_version` optionally, the version number of the first event to read.
      Defaults to the beginning of the stream if not set.

    - `count` optionally, the maximum number of events to read.
      If not set it will be limited to returning 1,000 events from the stream.
  """
  @spec read_stream_forward(String.t, non_neg_integer, non_neg_integer) :: {:ok, list(RecordedEvent.t)} | {:error, reason :: term}
  def read_stream_forward(stream_uuid, start_version \\ 0, count \\ 1_000) do
    with {:ok, _stream} <- EventStore.Streams.Supervisor.open_stream(stream_uuid) do
      Stream.read_stream_forward(stream_uuid, start_version, count)
    else
      reply -> reply
    end
  end

  @doc """
  Streams events from the given stream, in the order in which they were originally written.

    - `start_version` optionally, the version number of the first event to read.
      Defaults to the beginning of the stream if not set.

    - `read_batch_size` optionally, the number of events to read at a time from storage.
      Defaults to reading 1,000 events per batch.
  """
  @spec stream_forward(String.t, non_neg_integer, non_neg_integer) :: Enumerable.t | {:error, reason :: term}
  def stream_forward(stream_uuid, start_version \\ 0, read_batch_size \\ 1_000) do
    with {:ok, _stream} <- EventStore.Streams.Supervisor.open_stream(stream_uuid) do
      Stream.stream_forward(stream_uuid, start_version, read_batch_size)
    else
      reply -> reply
    end
  end

  @doc """
  Reads the requested number of events from all streams, in the order in which they were originally written.

    - `start_event_number` optionally, the number of the first event to read.
      Defaults to the beginning of the stream if not set.

    - `count` optionally, the maximum number of events to read.
    If not set it will be limited to returning 1,000 events from all streams.
  """
  @spec read_all_streams_forward(non_neg_integer, non_neg_integer) :: {:ok, list(RecordedEvent.t)} | {:error, reason :: term}
  def read_all_streams_forward(start_event_number \\ 0, count \\ 1_000) do
    AllStream.read_stream_forward(start_event_number, count)
  end

  @doc """
  Streams events from all streams, in the order in which they were originally written.

    - `start_event_number` optionally, the number of the first event to read.
      Defaults to the beginning of the stream if not set.

    - `read_batch_size` optionally, the number of events to read at a time from storage.
      Defaults to reading 1,000 events per batch.
  """
  @spec stream_all_forward(non_neg_integer, non_neg_integer) :: Enumerable.t
  def stream_all_forward(start_event_number \\ 0, read_batch_size \\ 1_000) do
    AllStream.stream_forward(start_event_number, read_batch_size)
  end

  @doc """
  Subscriber will be notified of each batch of events persisted to a single stream.

    - `stream_uuid` is the stream to subscribe to.
      Use the `$all` identifier to subscribe to events from all streams.

    - `subscription_name` is used to uniquely identify the subscription.

    - `subscriber` is a process that will be sent `{:events, events}` notification messages.

    - `opts` is an optional map providing additional subscription configuration:
      - `start_from` is a pointer to the first event to receive. It must be one of:
          - `:origin` for all events from the start of the stream (default).
          - `:current` for any new events appended to the stream after the subscription has been created.
          - any positive integer for a stream version to receive events after.
      - `mapper` to define a function to map each recorded event before sending to the subscriber.

  Returns `{:ok, subscription}` when subscription succeeds.
  """
  @spec subscribe_to_stream(String.t, String.t, pid, keyword) :: {:ok, subscription :: pid}
    | {:error, :subscription_already_exists}
    | {:error, reason :: term}
  def subscribe_to_stream(stream_uuid, subscription_name, subscriber, opts \\ [])
  def subscribe_to_stream(stream_uuid, subscription_name, subscriber, opts) do
    with {:ok, _stream} <- EventStore.Streams.Supervisor.open_stream(stream_uuid) do
      Stream.subscribe_to_stream(stream_uuid, subscription_name, subscriber, opts)
    else
      reply -> reply
    end
  end

  @doc """
  Subscriber will be notified of every event persisted to any stream.

    - `subscription_name` is used to uniquely identify the subscription.

    - `subscriber` is a process that will be sent `{:events, events}` notification messages.

    - `opts` is an optional map providing additional subscription configuration:
      - `start_from` is a pointer to the first event to receive. It must be one of:
          - `:origin` for all events from the start of the stream (default).
          - `:current` for any new events appended to the stream after the subscription has been created.
          - any positive integer for an event id to receive events after that exact event.
      - `mapper` to define a function to map each recorded event before sending to the subscriber.

  Returns `{:ok, subscription}` when subscription succeeds.
  """
  @spec subscribe_to_all_streams(String.t, pid, keyword) :: {:ok, subscription :: pid}
    | {:error, :subscription_already_exists}
    | {:error, reason :: term}
  def subscribe_to_all_streams(subscription_name, subscriber, opts \\ [])
  def subscribe_to_all_streams(subscription_name, subscriber, opts) do
    AllStream.subscribe_to_stream(subscription_name, subscriber, opts)
  end

  @doc """
  Acknowledge receipt of the given events received from a single stream, or all streams, subscription.
  """
  @spec ack(pid, RecordedEvent.t | list(RecordedEvent.t) | non_neg_integer()) :: :ok | {:error, reason :: term}
  def ack(subscription, ack) do
    Subscription.ack(subscription, ack)
  end

  @doc """
  Unsubscribe an existing subscriber from event notifications.

    - `stream_uuid` is the stream to unsubscribe from.

    - `subscription_name` is used to identify the existing subscription to remove.

  Returns `:ok` on success.
  """
  @spec unsubscribe_from_stream(String.t, String.t) :: :ok
  def unsubscribe_from_stream(stream_uuid, subscription_name) do
    Subscriptions.unsubscribe_from_stream(stream_uuid, subscription_name)
  end

  @doc """
  Unsubscribe an existing subscriber from all event notifications.

    - `subscription_name` is used to identify the existing subscription to remove.

  Returns `:ok` on success.
  """
  @spec unsubscribe_from_all_streams(String.t) :: :ok
  def unsubscribe_from_all_streams(subscription_name) do
    Subscriptions.unsubscribe_from_stream(@all_stream, subscription_name)
  end

  @doc """
  Read a snapshot, if available, for a given source.

  Returns `{:ok, %EventStore.Snapshots.SnapshotData{}}` on success, or `{:error, :snapshot_not_found}` when unavailable.
  """
  @spec read_snapshot(String.t) :: {:ok, SnapshotData.t} | {:error, :snapshot_not_found}
  def read_snapshot(source_uuid) do
    Snapshotter.read_snapshot(source_uuid, configured_serializer())
  end

  @doc """
  Record a snapshot of the data and metadata for a given source

  Returns `:ok` on success
  """
  @spec record_snapshot(SnapshotData.t) :: :ok | {:error, reason :: term}
  def record_snapshot(%SnapshotData{} = snapshot) do
    Snapshotter.record_snapshot(snapshot, configured_serializer())
  end

  @doc """
  Delete a previously recorded snapshop for a given source

  Returns `:ok` on success, or when the snapshot does not exist
  """
  @spec delete_snapshot(String.t) :: :ok | {:error, reason :: term}
  def delete_snapshot(source_uuid) do
    Snapshotter.delete_snapshot(source_uuid)
  end

  @doc """
  Get the serializer configured for the environment
  """
  def configured_serializer do
    configuration()[:serializer] || raise ArgumentError, "EventStore storage configuration expects :serializer to be configured in environment"
  end

  @doc """
  Get the event store configuration for the environment
  """
  def configuration do
    Application.get_env(:eventstore, EventStore.Storage) || raise ArgumentError, "EventStore storage configuration not specified in environment"
  end
end
