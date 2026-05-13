defmodule Claptrap.API.Auth do
  @moduledoc """
  Plug that enforces bearer-token authentication.

  Requests to paths in the allowlist bypass authentication. By default, only
  `/health` and `/ready` are exempt.

  All other requests must include `Authorization: Bearer <token>`. The expected
  value comes from `:api_key` plug options or `Application.get_env(:claptrap,
  :api_key)`. Token comparison uses `Plug.Crypto.secure_compare/2` to avoid
  leaking timing information.

  Unauthorized requests receive a halted `401` JSON response.
  """

  @behaviour Plug

  import Plug.Conn

  @default_except ["/health", "/ready"]

  @impl Plug
  def init(opts) do
    %{
      except: Keyword.get(opts, :except, @default_except),
      api_key: Keyword.get(opts, :api_key)
    }
  end

  @impl Plug
  def call(conn, %{except: except} = opts) do
    if conn.request_path in except or public_sink_output_request?(conn) do
      conn
    else
      authenticate(conn, opts)
    end
  end

  defp authenticate(conn, opts) do
    with [header | _] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- header,
         true <- valid_token?(token, opts) do
      conn
    else
      _ -> unauthorized(conn)
    end
  end

  defp valid_token?(token, opts) do
    key = opts[:api_key] || Application.get_env(:claptrap, :api_key)

    case key do
      k when is_binary(k) and byte_size(k) > 0 ->
        Plug.Crypto.secure_compare(token, k)

      _ ->
        false
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end

  defp public_sink_output_request?(conn) do
    conn.method == "GET" and sink_show_request?(conn.request_path) and
      accepts_media_type?(conn, "application/rss+xml")
  end

  defp sink_show_request?(request_path) do
    case String.split(request_path, "/", trim: true) do
      ["api", "v1", "sinks", sink_id] when sink_id != "" -> true
      _ -> false
    end
  end

  defp accepts_media_type?(conn, content_type) do
    normalized_content_type = normalize_media_type(content_type)

    conn
    |> get_req_header("accept")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&normalize_media_type/1)
    |> Enum.any?(&(&1 == normalized_content_type))
  end

  defp normalize_media_type(media_type) do
    media_type
    |> String.trim()
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> List.first()
  end
end
