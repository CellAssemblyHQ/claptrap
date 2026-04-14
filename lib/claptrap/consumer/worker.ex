defmodule Claptrap.Consumer.Worker do
  @moduledoc """
  Runs ingestion for a single source as an isolated GenServer process.

  A consumer worker owns the ingestion lifecycle for one source. Depending on
  adapter mode, it either polls on an interval (`:pull`) or receives adapter
  pushed messages (`:push`). In both paths it persists normalized entries via
  `Claptrap.Catalog`, and broadcasts newly inserted entries on PubSub so
  downstream producers can route and deliver them.

  The process is registered under `Claptrap.Registry` with the key
  `{:source_worker, source_id}` and is supervised dynamically under
  `Claptrap.Consumer.WorkerSupervisor`.

  ## Lifecycle

    1. Load source from the catalog.
    2. Resolve adapter from `source.type` (`"rss"` and `"imap"`).
    3. Validate source config with the adapter.
    4. Branch by adapter mode:
       * `:pull` schedules the initial poll timer and consumes fetch events.
       * `:push` starts the adapter listener and consumes inbound messages.
    5. Persist each normalized item as an entry.
    6. Broadcast successful inserts.

  ## Scheduling model (`:pull`)

  The worker uses a tokenized timer to avoid stale timer events causing
  overlapping poll chains. Every new schedule call cancels the previous timer,
  stores a fresh token, and only processes timer messages that match the active
  token.

  Manual polling through `poll/1` is supported and reuses the same consume path
  as scheduled polls.

  ## Retry behavior (`:pull`)

  Retry behavior is driven by `fetch/1` return values:

    * `{:ok, items}` resets retry count and schedules the normal poll interval.
    * `{:error, reason}` schedules exponential backoff retry while
      `retry_count < max_retries`.
    * After retries are exhausted, the worker logs an error, resets retry
      count, and resumes the normal poll interval.

  Backoff delay is `base * 2^(attempt - 1) + jitter`, capped by
  `max_retry_delay`.

  ## Push message handling (`:push`)

  Push-mode adapters own listener lifecycle and deliver arbitrary messages to
  the worker process. For each message, the worker delegates to
  `adapter.ingest/2` and:

    * persists entries when `{:ok, items}` is returned
    * ignores `:ignore`
    * logs warning and continues on `{:error, reason}`

  No retry chain is used in push mode because each message is independent.

  ## Persistence and broadcast semantics

  For each consumed item, the worker:

    * injects `source_id`
    * defaults entry `status` to `"unread"` when missing
    * merges source tags with item tags
    * calls `Catalog.create_entry/1`

  Failed inserts are logged and skipped. Successful inserts are collected and
  only entries with a persisted `id` are broadcast in
  `{:entries_ingested, source_id, entries}` on
  `Claptrap.PubSub.topic_entries_new/0`.

  After a successful pull fetch or push ingest, the worker updates
  `source.last_consumed_at` to current UTC time truncated to seconds.

  ## Failure boundaries

  Adapter validation and unsupported source types raise `ArgumentError` during
  initialization. Adapter exceptions during fetch/ingest are not rescued in
  this module; they crash this worker process and rely on OTP supervision for
  restart.
  """

  use GenServer

  require Logger

  alias Claptrap.Catalog
  alias Claptrap.Catalog.Source
  alias Claptrap.Consumer.Adapters.IMAP
  alias Claptrap.Consumer.Adapters.RSS
  alias Claptrap.PubSub
  alias Claptrap.Registry

  @default_poll_interval :timer.minutes(15)
  @default_retry_base_interval 500
  @default_max_retry_delay :timer.seconds(30)
  @default_retry_jitter 100
  @default_max_retries 5
  @default_initial_poll_delay 0

  def start_link(source_id) when is_binary(source_id) do
    start_link(source_id: source_id)
  end

  def start_link(opts) when is_list(opts) do
    source_id = Keyword.fetch!(opts, :source_id)
    name = Registry.via_tuple(:source_worker, source_id)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def poll(source_id) do
    case Registry.whereis(:source_worker, source_id) do
      pid when is_pid(pid) ->
        send(pid, :poll)
        :ok

      _ ->
        {:error, :not_found}
    end
  end

  @impl true
  def init(opts) do
    source = opts |> Keyword.fetch!(:source_id) |> Catalog.get_source!()
    adapter = adapter_for_source_type!(source.type)
    validate_source_config!(adapter, source)

    state =
      case adapter.mode() do
        :pull ->
          %{
            source: source,
            adapter: adapter,
            mode: :pull,
            poll_interval: Keyword.get(opts, :poll_interval, @default_poll_interval),
            retry_count: 0,
            max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
            retry_base_interval: Keyword.get(opts, :retry_base_interval, @default_retry_base_interval),
            max_retry_delay: Keyword.get(opts, :max_retry_delay, @default_max_retry_delay),
            retry_jitter: Keyword.get(opts, :retry_jitter, @default_retry_jitter),
            timer_ref: nil,
            timer_token: nil
          }
          |> schedule(:poll, initial_poll_delay(opts))

        :push ->
          _ = adapter.start_listener(source)

          %{
            source: source,
            adapter: adapter,
            mode: :push
          }

        mode ->
          raise ArgumentError, "unsupported adapter mode #{inspect(mode)} for source=#{source.id}"
      end

    {:ok, state}
  end

  @impl true
  def handle_info(message, %{mode: :push} = state) do
    case state.adapter.ingest(state.source, message) do
      {:ok, raw_items} ->
        {:noreply, push_consume(state, raw_items)}

      :ignore ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Consumer.Worker push ingest failed source=#{state.source.id}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(message, state) when message in [:poll, :retry] do
    {:noreply, consume(state)}
  end

  def handle_info({:timer, token, message}, %{timer_token: token} = state) when message in [:poll, :retry] do
    {:noreply, state |> clear_timer() |> consume()}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  defp consume(state) do
    case state.adapter.fetch(state.source) do
      {:ok, raw_items} ->
        entries = Enum.map(raw_items, &create_entry(state.source, &1))
        new_entries = Enum.filter(entries, &match?(%{id: id} when not is_nil(id), &1))
        source = mark_consumed!(state.source)

        if new_entries != [] do
          PubSub.broadcast(PubSub.topic_entries_new(), {:entries_ingested, source.id, new_entries})
        end

        state
        |> Map.put(:source, source)
        |> Map.put(:retry_count, 0)
        |> schedule(:poll, state.poll_interval)

      {:error, reason} ->
        retry_or_reschedule(state, reason)
    end
  end

  defp push_consume(state, raw_items) do
    entries = Enum.map(raw_items, &create_entry(state.source, &1))
    new_entries = Enum.filter(entries, &match?(%{id: id} when not is_nil(id), &1))
    source = mark_consumed!(state.source)

    if new_entries != [] do
      PubSub.broadcast(PubSub.topic_entries_new(), {:entries_ingested, source.id, new_entries})
    end

    %{state | source: source}
  end

  defp create_entry(%Source{} = source, attrs) do
    attrs =
      attrs
      |> Map.put(:source_id, source.id)
      |> Map.put_new(:status, "unread")
      |> Map.update(:tags, source.tags || [], &merge_tags(source.tags || [], &1))

    case Catalog.create_entry(attrs) do
      {:ok, entry} ->
        entry

      {:error, changeset} ->
        Logger.error(
          "Consumer.Worker failed to persist entry for source=#{source.id}: #{inspect(changeset.errors)} attrs=#{inspect(attrs)}"
        )

        nil
    end
  end

  defp merge_tags(source_tags, item_tags) do
    (source_tags ++ List.wrap(item_tags))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp mark_consumed!(%Source{} = source) do
    source = Catalog.get_source!(source.id)

    {:ok, updated_source} =
      Catalog.update_source(source, %{last_consumed_at: DateTime.utc_now() |> DateTime.truncate(:second)})

    updated_source
  end

  defp retry_or_reschedule(state, reason) do
    if state.retry_count < state.max_retries do
      attempt = state.retry_count + 1
      delay = retry_delay(state, attempt)

      Logger.warning(
        "Consumer.Worker retrying source=#{state.source.id} attempt=#{attempt} delay_ms=#{delay} reason=#{inspect(reason)}"
      )

      state
      |> Map.put(:retry_count, attempt)
      |> schedule(:retry, delay)
    else
      Logger.error("Consumer.Worker exhausted retries for source=#{state.source.id}: #{inspect(reason)}")

      state
      |> Map.put(:retry_count, 0)
      |> schedule(:poll, state.poll_interval)
    end
  end

  defp retry_delay(state, attempt) do
    jitter = if state.retry_jitter > 0, do: :rand.uniform(state.retry_jitter), else: 0
    min(state.retry_base_interval * trunc(:math.pow(2, attempt - 1)) + jitter, state.max_retry_delay)
  end

  defp schedule(state, message, delay) do
    cancel_timer(state.timer_ref)

    timer_token = make_ref()
    timer_ref = Process.send_after(self(), {:timer, timer_token, message}, delay)

    %{state | timer_ref: timer_ref, timer_token: timer_token}
  end

  defp clear_timer(state) do
    %{state | timer_ref: nil, timer_token: nil}
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp initial_poll_delay(opts) do
    Keyword.get(
      opts,
      :initial_poll_delay,
      Application.get_env(:claptrap, :consumer_initial_poll_delay, @default_initial_poll_delay)
    )
  end

  defp validate_source_config!(adapter, %Source{} = source) do
    case adapter.validate_config(source.config || %{}) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "invalid source config for #{source.id}: #{reason}"
    end
  end

  defp adapter_for_source_type!("rss"), do: RSS
  defp adapter_for_source_type!("imap"), do: IMAP

  defp adapter_for_source_type!(type) do
    raise ArgumentError, "unsupported consumer source type: #{inspect(type)}"
  end
end
