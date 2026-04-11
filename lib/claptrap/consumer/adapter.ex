defmodule Claptrap.Consumer.Adapter do
  @moduledoc """
  Defines the adapter contract for the Consumer subsystem.

  A consumer adapter translates a source-specific protocol into the normalized
  entry attributes consumed by `Claptrap.Catalog.create_entry/1`.

  The worker model in `Claptrap.Consumer.Worker` expects adapters to expose
  both their ingestion mode and the functions needed for that mode:

    * `mode/0` declares whether the adapter is `:pull` or `:push`.
    * `fetch/1` is used by pull-based workers.
    * `ingest/2` is reserved for push-based ingestion entrypoints.
    * `validate_config/1` checks source configuration before work starts.

  ## Return shape and failure semantics

  `ingest/2` callbacks return one of:

    * `:ignore` when the adapter does not recognize the input and the worker
      should silently discard it.
    * `{:error, reason}` when the adapter recognized the input but failed to
      normalize it. The worker logs a warning.
    * `{:ok, [map()]}` with normalized entry attribute maps.

  In the current implementation, `Claptrap.Consumer.Worker` retries on
  `{:error, reason}` from `fetch/1`. Exceptions raised by adapters are not
  rescued by the worker and therefore crash that worker process, allowing OTP
  supervision to restart it.
  """

  alias Claptrap.Catalog.Source

  @callback mode() :: :pull | :push

  @callback fetch(source :: Source.t()) :: {:ok, [map()]} | {:error, term()}

  @callback ingest(source :: Source.t(), input :: term()) ::
              {:ok, [map()]} | {:error, term()} | :ignore

  @callback validate_config(config :: map()) :: :ok | {:error, String.t()}
end
