defmodule Claptrap.Producer.Adapter do
  @moduledoc """
  Defines the contract implemented by sink-specific producer adapters.

  A producer worker delegates sink delivery to an adapter selected from the
  sink type. Adapters expose one of two operating modes:

  - `:push` adapters send each delivered batch to an external system.
  - `:pull` adapters materialize sink output that Claptrap serves later.

  The callbacks in this behaviour mirror that split:

  - `mode/0` declares which delivery path the worker should use.
  - `push/2` handles push-mode delivery.
  - `materialize/2` handles pull-mode rendering or storage.
  - `validate_config/1` validates sink adapter configuration.

  The delivery and validation callbacks return `:ok` on success or
  `{:error, reason}` on failure.
  """

  @callback mode() :: :push | :pull

  @callback push(sink :: %Claptrap.Catalog.Sink{}, entries :: [%Claptrap.Catalog.Entry{}]) ::
              :ok | {:error, term()}

  @callback materialize(
              sink :: %Claptrap.Catalog.Sink{},
              entries :: [%Claptrap.Catalog.Entry{}]
            ) ::
              :ok | {:error, term()}

  @callback get_output(sink_id :: Ecto.UUID.t()) ::
              {:ok, body :: binary(), content_type :: binary()} | {:error, term()}

  @callback validate_config(config :: map()) ::
              :ok | {:error, String.t()}

  @optional_callbacks get_output: 1

  @spec for_type(String.t()) :: {:ok, module()} | {:error, String.t()}
  def for_type("rss"), do: {:ok, Claptrap.Producer.Adapters.RssFeed}
  def for_type(other), do: {:error, "unknown sink type: #{other}"}
end
