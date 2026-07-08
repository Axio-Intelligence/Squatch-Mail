defmodule SquatchMail.Test.AWSStub do
  @moduledoc """
  A test double implementing the `AWS.HTTPClient` behaviour.

  Lets `SquatchMail.SES` tests inject canned AWS responses and inspect the
  requests that were made, without any real network access.

  ## Usage

      stub = AWSStub.new()
      AWSStub.stub(stub, :post, ~r"amazonaws\\.com/?$", fn _req ->
        {:ok, 200, xml_body}
      end)

      client =
        AWS.Client.create("AKIA", "secret", "us-east-1")
        |> AWS.Client.put_http_client({AWSStub, agent: stub})

  Each matcher is `{method, url_matcher, responder}` where:

    * `method` is an atom (`:get`, `:post`, ...) or `:any`.
    * `url_matcher` is a `Regex`, a substring `String`, or `:any`.
    * `responder` is a 1-arity fun receiving a request map
      `%{method:, url:, body:, headers:, options:}` and returning either
      `{:ok, status, body}` (an iodata/binary body), `{:error, reason}`, or
      `:pass` to decline and let the next registered matcher try (useful when
      several matchers share a URL — e.g. every SNS action hits the same host —
      and each responder dispatches on the request body's `Action`).

  Matchers are tried in registration order; the first that both matches the
  method/URL and does not return `:pass` wins. An otherwise-unmatched request
  returns `{:error, {:no_stub, method, url}}` so tests fail loudly rather than
  hitting the network.
  """

  @behaviour AWS.HTTPClient

  ## ---- Agent lifecycle -----------------------------------------------------

  @doc "Starts a stub state agent and returns its pid."
  def new do
    {:ok, pid} = Agent.start_link(fn -> %{matchers: [], calls: []} end)
    pid
  end

  @doc """
  Registers a matcher. Later-registered matchers are tried after earlier ones.
  """
  def stub(agent, method, url_matcher, responder)
      when is_function(responder, 1) do
    Agent.update(agent, fn state ->
      Map.update!(state, :matchers, &(&1 ++ [{method, url_matcher, responder}]))
    end)

    agent
  end

  @doc "Returns the list of recorded request maps, in the order they were made."
  def calls(agent), do: Agent.get(agent, & &1.calls) |> Enum.reverse()

  @doc "Returns recorded requests filtered to those whose URL matches `matcher`."
  def calls(agent, matcher) do
    agent
    |> calls()
    |> Enum.filter(&url_match?(matcher, &1.url))
  end

  @doc "Returns how many recorded requests match `matcher`."
  def call_count(agent, matcher), do: length(calls(agent, matcher))

  ## ---- AWS.HTTPClient callback ---------------------------------------------

  @impl AWS.HTTPClient
  def request(method, url, body, headers, options) do
    agent = Keyword.fetch!(options, :agent)
    url = IO.iodata_to_binary(url)

    request = %{
      method: method,
      url: url,
      body: IO.iodata_to_binary(body || ""),
      headers: headers,
      options: options
    }

    Agent.update(agent, fn state ->
      Map.update!(state, :calls, &[request | &1])
    end)

    matchers = Agent.get(agent, & &1.matchers)

    case respond(matchers, method, url, request) do
      :no_match ->
        {:error, {:no_stub, method, url}}

      {:ok, status, resp_body} ->
        {:ok, %{status_code: status, headers: [], body: IO.iodata_to_binary(resp_body || "")}}

      {:error, _reason} = error ->
        error
    end
  end

  ## ---- Matching ------------------------------------------------------------

  # Tries each candidate matcher in order. A responder returning `:pass` declines
  # and the next matcher is tried; anything else short-circuits.
  defp respond([], _method, _url, _request), do: :no_match

  defp respond([{m, url_matcher, responder} | rest], method, url, request) do
    if method_match?(m, method) and url_match?(url_matcher, url) do
      case responder.(request) do
        :pass -> respond(rest, method, url, request)
        result -> result
      end
    else
      respond(rest, method, url, request)
    end
  end

  defp method_match?(:any, _method), do: true
  defp method_match?(expected, actual), do: expected == actual

  defp url_match?(:any, _url), do: true
  defp url_match?(%Regex{} = re, url), do: Regex.match?(re, url)
  defp url_match?(substr, url) when is_binary(substr), do: String.contains?(url, substr)
end
