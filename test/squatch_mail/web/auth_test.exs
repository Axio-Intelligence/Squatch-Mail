defmodule SquatchMail.Web.AuthTest do
  @moduledoc """
  Exercises the three security layers documented on `SquatchMail.Web.Router`.
  """

  use SquatchMail.Web.WebCase, async: false

  describe "layer (c): safe default refusal" do
    test "refuses with a 403 and setup instructions when nothing is configured", %{conn: conn} do
      Application.delete_env(:squatch_mail, :basic_auth)
      Application.delete_env(:squatch_mail, :allow_unauthenticated)

      conn = get(conn, "/squatch")

      assert conn.status == 403
      assert conn.resp_body =~ "access refused"
      assert conn.resp_body =~ "allow_unauthenticated"
      assert conn.resp_body =~ "basic_auth"
    end

    test "mounts normally when allow_unauthenticated is true", %{conn: conn} do
      Application.delete_env(:squatch_mail, :basic_auth)
      Application.put_env(:squatch_mail, :allow_unauthenticated, true)

      conn = get(conn, "/squatch")

      assert conn.status == 200
      assert conn.resp_body =~ "Trail Log"
    end

    test "the refusal page's own CSS/JS assets still load", %{conn: conn} do
      Application.delete_env(:squatch_mail, :basic_auth)
      Application.delete_env(:squatch_mail, :allow_unauthenticated)

      css_path = "/squatch/assets/" <> SquatchMail.Web.AssetController.asset_path(:css)
      conn = get(conn, css_path)

      assert conn.status == 200
    end
  end

  describe "layer (b): basic_auth fallback" do
    test "401s without credentials when basic_auth is configured", %{conn: conn} do
      Application.put_env(:squatch_mail, :basic_auth, username: "squatch", password: "secret")
      Application.delete_env(:squatch_mail, :allow_unauthenticated)

      conn = get(conn, "/squatch")

      assert conn.status == 401
      assert ["Basic realm=" <> _] = get_resp_header(conn, "www-authenticate")
    end

    test "401s with the wrong credentials", %{conn: conn} do
      Application.put_env(:squatch_mail, :basic_auth, username: "squatch", password: "secret")

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", basic_auth_header("squatch", "wrong"))
        |> get("/squatch")

      assert conn.status == 401
    end

    test "mounts normally with the correct credentials", %{conn: conn} do
      Application.put_env(:squatch_mail, :basic_auth, username: "squatch", password: "secret")

      conn =
        conn
        |> Plug.Conn.put_req_header("authorization", basic_auth_header("squatch", "secret"))
        |> get("/squatch")

      assert conn.status == 200
      assert conn.resp_body =~ "Trail Log"
    end

    test "takes precedence over allow_unauthenticated when both are set", %{conn: conn} do
      Application.put_env(:squatch_mail, :basic_auth, username: "squatch", password: "secret")
      Application.put_env(:squatch_mail, :allow_unauthenticated, true)

      conn = get(conn, "/squatch")

      assert conn.status == 401
    end
  end

  describe "layer (a): host-owned on_mount" do
    test "mounts normally with no basic_auth/allow_unauthenticated configured", %{conn: conn} do
      Application.delete_env(:squatch_mail, :basic_auth)
      Application.delete_env(:squatch_mail, :allow_unauthenticated)

      conn = get(conn, "/host-authed/dash")

      assert conn.status == 200
      assert conn.resp_body =~ "Trail Log"
    end
  end

  describe "webhook route" do
    test "is not covered by any dashboard auth layer", %{conn: conn} do
      Application.delete_env(:squatch_mail, :basic_auth)
      Application.delete_env(:squatch_mail, :allow_unauthenticated)

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/squatch/webhooks/sns/some-token", "{}")

      # However the webhook controller itself responds, it must not be a
      # 403 refusal page or a 401 basic-auth challenge from the dashboard's
      # own auth layers.
      refute conn.status == 403
      refute conn.status == 401
    end
  end

  defp basic_auth_header(username, password) do
    "Basic " <> Base.encode64("#{username}:#{password}")
  end
end
