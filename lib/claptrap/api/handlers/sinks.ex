defmodule Claptrap.API.Handlers.Sinks do
  @moduledoc """
  Router for `/api/v1/sinks` resource endpoints.

  This handler provides CRUD operations for sinks through `Claptrap.Catalog`.
  List responses use pagination helpers and all successful responses are shaped
  by `Claptrap.API.Serializers`.

  Validation failures from changesets are returned as `422` JSON payloads.
  """

  use Plug.Router

  alias Claptrap.API.Serializers
  alias Claptrap.Catalog
  alias Claptrap.Pagination
  alias Claptrap.Producer.Adapter
  import Claptrap.API.Helpers

  plug(:match)
  plug(:dispatch)

  get "/" do
    opts = Pagination.params_to_opts(conn.query_params)
    page = Catalog.list_sinks(opts)
    response = Pagination.to_response(page)
    json(conn, 200, %{response | items: Enum.map(response.items, &Serializers.serialize/1)})
  end

  post "/" do
    case Catalog.create_sink(conn.body_params) do
      {:ok, sink} -> json(conn, 201, Serializers.serialize(sink))
      {:error, changeset} -> json(conn, 422, %{errors: changeset_errors(changeset)})
    end
  end

  get "/:id" do
    sink = Catalog.get_sink!(id)

    if accepts_json?(conn) do
      json(conn, 200, Serializers.serialize(sink))
    else
      serve_output(conn, sink)
    end
  end

  patch "/:id" do
    sink = Catalog.get_sink!(id)

    case Catalog.update_sink(sink, conn.body_params) do
      {:ok, updated} -> json(conn, 200, Serializers.serialize(updated))
      {:error, changeset} -> json(conn, 422, %{errors: changeset_errors(changeset)})
    end
  end

  delete "/:id" do
    sink = Catalog.get_sink!(id)
    {:ok, _} = Catalog.delete_sink(sink)
    send_resp(conn, 204, "")
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not found"}))
  end

  defp accepts_json?(conn) do
    case accepted_media_types(conn) do
      [] -> true
      media_types -> Enum.any?(media_types, &(&1 in ["*/*", "application/json"]))
    end
  end

  defp serve_output(conn, sink) do
    with {:ok, adapter} <- Adapter.for_type(sink.type),
         {:ok, body, content_type} <- get_output(adapter, sink.id),
         true <- accepts_media_type?(conn, content_type) do
      conn
      |> put_resp_content_type(content_type)
      |> send_resp(200, body)
    else
      {:error, :not_supported} ->
        send_resp(conn, 406, Jason.encode!(%{error: "not acceptable"}))

      {:error, :not_found} ->
        send_resp(conn, 404, Jason.encode!(%{error: "not found"}))

      {:error, reason} when is_binary(reason) ->
        send_resp(conn, 406, Jason.encode!(%{error: "not acceptable"}))

      false ->
        send_resp(conn, 406, Jason.encode!(%{error: "not acceptable"}))
    end
  end

  defp get_output(adapter, sink_id) do
    case Code.ensure_loaded(adapter) do
      {:module, _} ->
        if function_exported?(adapter, :get_output, 1) do
          adapter.get_output(sink_id)
        else
          {:error, :not_supported}
        end

      _ ->
        {:error, :not_supported}
    end
  end

  defp accepts_media_type?(conn, content_type) do
    normalized_content_type = normalize_media_type(content_type)

    accepted_media_types(conn)
    |> Enum.any?(fn media_type ->
      media_type in [normalized_content_type, "*/*"]
    end)
  end

  defp accepted_media_types(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&normalize_media_type/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_media_type(media_type) do
    media_type
    |> String.trim()
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> List.first()
  end
end
