defmodule SquatchMail.Test.SubscribeTestEndpoint do
  @moduledoc """
  A tiny Bandit-hosted Plug used only by `SquatchMail.SNS.ProcessorTest` to
  assert that `SubscriptionConfirmation` handling really performs an HTTP GET
  against the (in real life, AWS-hosted) `SubscribeURL`.

  Started per-test on a random port via `start_link/1`; every request it
  receives is forwarded to the given test process as
  `{:subscribe_request, path}` so the test can assert on it without coupling
  to Finch internals.
  """

  use Plug.Router

  plug :match
  plug :dispatch

  get "/confirm" do
    if pid = conn.assigns[:test_pid] do
      send(pid, {:subscribe_request, conn.request_path})
    end

    send_resp(conn, 200, "ok")
  end

  @doc """
  Starts the endpoint on a random free port, forwarding every request it
  receives to `test_pid`. Returns the port.
  """
  def start_link(test_pid) do
    port = free_port()

    {:ok, _pid} =
      Bandit.start_link(
        plug: {__MODULE__, test_pid: test_pid},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port
      )

    port
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    conn
    |> assign(:test_pid, opts[:test_pid])
    |> super(opts)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
