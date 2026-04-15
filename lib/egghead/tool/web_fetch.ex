defmodule Egghead.Tool.WebFetch do
  @moduledoc """
  HTTP GET/POST tool for agents.

  Capability scoping: invocation's host is checked against the
  agent's `net.get` / `net.post` host allow-list at dispatch time
  (in `Tools.execute/3` via `Capability.check/3`).

  Content handling: HTML responses are stripped to readable text
  with links preserved by default. Pass `raw: true` in the input
  to preserve raw HTML. Non-text responses (binary) are refused
  with a size-only notice via `Egghead.Tool.Output`.
  """

  alias Egghead.Capability.Request
  alias Egghead.Tool.Output

  @default_timeout 30_000
  @default_max_redirects 5

  @doc """
  Builds the capability request this call would make. Branches on
  HTTP method: GET → `net.get`, POST → `net.post`, etc.
  """
  @spec request_for(map()) :: [Request.t()]
  def request_for(%{"url" => url} = input) do
    method = method_from_input(input)
    host = url_host(url)

    [
      %Request{
        resource: :net,
        verb: method,
        scope: %{host: host},
        tool: "web_fetch"
      }
    ]
  end

  def request_for(_), do: []

  @doc """
  Executes the HTTP call. Returns `{:ok, body}` or
  `{:error, reason}`. Content-type-aware: HTML is stripped, JSON is
  pretty-printed, text is returned as-is, binary is refused.
  """
  @spec run(map()) :: {:ok, String.t()} | {:error, String.t()}
  def run(%{"url" => url} = input) do
    method = method_from_input(input)
    timeout = input["timeout"] || @default_timeout
    headers = input["headers"] || []
    body = input["body"]

    req_opts = [
      url: url,
      method: method,
      headers: headers,
      receive_timeout: timeout,
      max_redirects: @default_max_redirects
    ]

    req_opts = if body, do: Keyword.put(req_opts, :body, body), else: req_opts

    case Req.request(req_opts) do
      {:ok, %{status: status, body: resp_body, headers: resp_headers}} when status in 200..299 ->
        format_body(resp_body, resp_headers, input["raw"] == true)

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{excerpt(body)}"}

      {:error, reason} ->
        {:error, "request failed: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "web_fetch error: #{Exception.message(e)}"}
  end

  def run(_), do: {:error, "web_fetch requires a url"}

  # --- helpers ---

  defp method_from_input(input) do
    case String.downcase(to_string(input["method"] || "GET")) do
      "get" -> :get
      "post" -> :post
      "put" -> :put
      "patch" -> :patch
      "delete" -> :delete
      "head" -> :head
      "options" -> :options
      _ -> :get
    end
  end

  defp url_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> ""
    end
  end

  defp url_host(_), do: ""

  defp format_body(body, headers, raw?) do
    content_type = content_type(headers)

    cond do
      raw? ->
        cap(body_to_string(body))

      content_type =~ "application/json" ->
        cap(json_pretty(body))

      content_type =~ "text/html" or content_type =~ "application/xhtml" ->
        cap(html_to_text(body_to_string(body)))

      content_type =~ "text/" or content_type =~ "application/xml" ->
        cap(body_to_string(body))

      true ->
        # Unknown or binary — let Output.apply decide (it validates UTF-8)
        cap(body_to_string(body))
    end
  end

  defp content_type(headers) do
    headers
    |> Enum.find_value("", fn
      {"content-type", v} -> v
      {"Content-Type", v} -> v
      _ -> nil
    end)
    |> to_string()
    |> String.downcase()
  end

  defp body_to_string(body) when is_binary(body), do: body
  defp body_to_string(body) when is_map(body), do: Jason.encode!(body, pretty: true)
  defp body_to_string(body), do: inspect(body)

  defp json_pretty(body) when is_map(body) or is_list(body), do: Jason.encode!(body, pretty: true)

  defp json_pretty(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> Jason.encode!(parsed, pretty: true)
      _ -> body
    end
  end

  defp json_pretty(body), do: inspect(body)

  defp cap(body) do
    case Output.apply(body) do
      {:ok, text} -> {:ok, text}
      {:truncated, text, _} -> {:ok, text}
      {:binary, notice} -> {:ok, notice}
    end
  end

  # Minimal HTML → text conversion: strips scripts/styles, converts
  # structural tags to markdown-ish, collapses whitespace. Not a full
  # readability implementation — good enough for most articles. Users
  # who need rich extraction can install a skill for it.
  defp html_to_text(html) do
    html
    |> strip_tags(~r/<script\b[^>]*>.*?<\/script>/si)
    |> strip_tags(~r/<style\b[^>]*>.*?<\/style>/si)
    |> strip_tags(~r/<noscript\b[^>]*>.*?<\/noscript>/si)
    |> strip_tags(~r/<!--.*?-->/s)
    |> convert_links()
    |> String.replace(~r/<h1[^>]*>(.*?)<\/h1>/si, "\n# \\1\n")
    |> String.replace(~r/<h2[^>]*>(.*?)<\/h2>/si, "\n## \\1\n")
    |> String.replace(~r/<h3[^>]*>(.*?)<\/h3>/si, "\n### \\1\n")
    |> String.replace(~r/<h[4-6][^>]*>(.*?)<\/h[4-6]>/si, "\n#### \\1\n")
    |> String.replace(~r/<li[^>]*>(.*?)<\/li>/si, "\n- \\1")
    |> String.replace(~r/<(p|div|br)[^>]*>/i, "\n")
    |> String.replace(~r/<\/p>|<\/div>/i, "\n")
    |> strip_all_tags()
    |> decode_entities()
    |> collapse_whitespace()
  end

  defp strip_tags(html, regex), do: Regex.replace(regex, html, "")
  defp strip_all_tags(html), do: Regex.replace(~r/<[^>]+>/s, html, "")

  defp convert_links(html) do
    Regex.replace(
      ~r/<a\s+[^>]*href=["']([^"']+)["'][^>]*>(.*?)<\/a>/si,
      html,
      "[\\2](\\1)"
    )
  end

  defp decode_entities(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&apos;", "'")
    |> String.replace("&nbsp;", " ")
    |> String.replace(~r/&#(\d+);/, fn _, n ->
      n |> String.to_integer() |> List.wrap() |> List.to_string()
    end)
  end

  defp collapse_whitespace(text) do
    text
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n[ \t]+/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp excerpt(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp excerpt(body), do: inspect(body) |> String.slice(0, 200)
end
