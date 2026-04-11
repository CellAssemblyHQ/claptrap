defmodule Claptrap.Producer.Worker do
  @moduledoc """
  Executes delivery work for a single sink.

  `Claptrap.Producer.Worker` is started per sink and registered as
  `{:sink_worker, sink_id}` through `Claptrap.Registry`. The router sends entry
  batches to this process with `{:deliver, entries}` messages.

  On initialization, the worker:

  - loads the sink from `Claptrap.Catalog`
  - resolves an adapter from the sink type
  - initializes retry state
  - seeds pull-mode sinks by calling `adapter.materialize(sink, [])`

  At present, adapter resolution supports `"rss"` sinks only.

  ## Delivery behavior

  For each delivered batch, the worker emits a telemetry span:

  - event: `[:claptrap, :producer, :delivery]`
  - measurements: none (span timing is provided by telemetry)
  - metadata: `sink_id`, `entry_count`, and final `status`

  The adapter call path depends on adapter mode:

  - `:push` -> `adapter.push/2`
  - `:pull` -> `adapter.materialize/2`

  Successful delivery resets retry tracking for new failures.

  ## Retry behavior

  Failed deliveries are queued and retried with exponential backoff plus jitter.
  Queue items are `{entries, attempt}` tuples, where `attempt` starts at `0`.

  Delay formula:

      min(500 * 2^attempt + random(1..100), 30_000)

  Retrying is driven by internal `:retry` messages. On each retry:

  - success removes the batch and emits retry telemetry with `status: :ok`
  - failure increments attempt, emits retry telemetry with `status: :error`,
    and re-enqueues unless retry limit is reached

  Batches are dropped after `@max_retries` attempts, with an error log.

  Retry telemetry event:

  - event: `[:claptrap, :producer, :retry]`
  - measurements: `%{count: 1}`
  - metadata: `sink_id`, `attempt`, `status`

  `{:resource_changed, :sink, ...}` handling is currently a logging stub.
  """
  use GenServer
  require Logger

  alias Claptrap.Catalog
  alias Claptrap.Producer.Adapter
  alias Claptrap.Registry, as: Reg

  @max_retries 5

  def start_link(sink_id) do
    GenServer.start_link(__MODULE__, sink_id, name: Reg.via_tuple(:sink_worker, sink_id))
  end

  @impl true
  def init(sink_id) do
    sink = Catalog.get_sink!(sink_id)

    case Adapter.for_type(sink.type) do
      {:ok, adapter} ->
        state = %{
          sink: sink,
          adapter: adapter,
          queue: :queue.new(),
          retry_count: 0,
          retry_timer: nil
        }

        seed_on_init(adapter, sink)

        Logger.info("Producer.Worker started for sink #{sink_id}")
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:deliver, entries}, state) do
    %{sink: sink, adapter: adapter} = state

    :telemetry.span(
      [:claptrap, :producer, :delivery],
      %{sink_id: sink.id, entry_count: length(entries)},
      fn ->
        case deliver(adapter, sink, entries) do
          :ok ->
            {
              :ok,
              %{sink_id: sink.id, entry_count: length(entries), status: :ok}
            }

          {:error, reason} ->
            {
              {:error, reason},
              %{sink_id: sink.id, entry_count: length(entries), status: :error}
            }
        end
      end
    )
    |> case do
      :ok ->
        {:noreply, %{state | retry_count: 0}}

      {:error, _reason} ->
        new_queue = :queue.in({entries, 0}, state.queue)
        {:noreply, schedule_retry(%{state | queue: new_queue})}
    end
  end

  @impl true
  def handle_info(:retry, state) do
    state = %{state | retry_timer: nil}

    case :queue.out(state.queue) do
      {{:value, {entries, attempt}}, rest} ->
        process_retry(entries, attempt, rest, state)

      {:empty, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:resource_changed, :sink, action, sink_id}, state) do
    Logger.debug("Producer.Worker received resource_changed: #{action} for sink #{sink_id} (stub)")

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("Producer.Worker received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp process_retry(entries, attempt, rest, state) do
    %{sink: sink, adapter: adapter} = state

    case deliver(adapter, sink, entries) do
      :ok ->
        emit_retry_telemetry(sink.id, attempt, :ok)
        new_state = %{state | queue: rest, retry_count: 0}
        {:noreply, schedule_retry(new_state)}

      {:error, _reason} ->
        handle_retry_failure(entries, attempt + 1, rest, state)
    end
  end

  defp handle_retry_failure(_entries, next_attempt, rest, state)
       when next_attempt >= @max_retries do
    emit_retry_telemetry(state.sink.id, next_attempt, :error)

    Logger.error("Producer.Worker dropping batch for sink #{state.sink.id} after #{@max_retries} retries")

    {:noreply, %{state | queue: rest}}
  end

  defp handle_retry_failure(entries, next_attempt, rest, state) do
    emit_retry_telemetry(state.sink.id, next_attempt, :error)
    new_queue = :queue.in({entries, next_attempt}, rest)
    {:noreply, schedule_retry(%{state | queue: new_queue})}
  end

  defp emit_retry_telemetry(sink_id, attempt, status) do
    :telemetry.execute(
      [:claptrap, :producer, :retry],
      %{count: 1},
      %{sink_id: sink_id, attempt: attempt, status: status}
    )
  end

  @dialyzer {:no_match, seed_on_init: 2}
  defp seed_on_init(adapter, sink) do
    if adapter.mode() == :pull, do: adapter.materialize(sink, [])
    :ok
  end

  defp deliver(adapter, sink, entries) do
    case adapter.mode() do
      :push -> adapter.push(sink, entries)
      :pull -> adapter.materialize(sink, entries)
    end
  end

  defp schedule_retry(%{queue: queue, retry_timer: existing} = state) do
    if existing, do: Process.cancel_timer(existing)

    case :queue.peek(queue) do
      {:value, {_entries, attempt}} ->
        delay = min(500 * Integer.pow(2, attempt) + :rand.uniform(100), 30_000)
        timer = Process.send_after(self(), :retry, delay)
        %{state | retry_timer: timer}

      :empty ->
        state
    end
  end
end
