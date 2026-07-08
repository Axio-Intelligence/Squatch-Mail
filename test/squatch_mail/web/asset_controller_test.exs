defmodule SquatchMail.Web.AssetControllerTest do
  use SquatchMail.Web.WebCase, async: false

  describe "GET /squatch/assets/css-:md5" do
    test "serves the CSS bundle with the correct content-type and immutable cache headers", %{
      conn: conn
    } do
      path = "/squatch/assets/" <> SquatchMail.Web.AssetController.asset_path(:css)
      conn = get(conn, path)

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/css"

      assert get_resp_header(conn, "cache-control") == [
               "public, max-age=31536000, immutable"
             ]

      assert conn.resp_body =~ "--sq-accent"
    end

    test "is reachable without any auth configured (allow_unauthenticated left unset)", %{
      conn: conn
    } do
      Application.delete_env(:squatch_mail, :allow_unauthenticated)
      Application.delete_env(:squatch_mail, :basic_auth)

      path = "/squatch/assets/" <> SquatchMail.Web.AssetController.asset_path(:css)
      conn = get(conn, path)

      assert conn.status == 200
    end

    test "is reachable even when basic_auth is configured, without credentials", %{conn: conn} do
      Application.put_env(:squatch_mail, :basic_auth, username: "squatch", password: "secret")

      path = "/squatch/assets/" <> SquatchMail.Web.AssetController.asset_path(:css)
      conn = get(conn, path)

      assert conn.status == 200
    end
  end

  describe "GET /squatch/assets/js-:md5" do
    test "serves the JS bundle with the correct content-type and immutable cache headers", %{
      conn: conn
    } do
      path = "/squatch/assets/" <> SquatchMail.Web.AssetController.asset_path(:js)
      conn = get(conn, path)

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/javascript"

      assert get_resp_header(conn, "cache-control") == [
               "public, max-age=31536000, immutable"
             ]

      assert conn.resp_body =~ "LiveSocket"
    end
  end

  test "asset_path/1 returns a stable hash derived from file contents" do
    assert SquatchMail.Web.AssetController.asset_path(:css) ==
             SquatchMail.Web.AssetController.asset_path(:css)

    assert String.starts_with?(SquatchMail.Web.AssetController.asset_path(:css), "css-")
    assert String.starts_with?(SquatchMail.Web.AssetController.asset_path(:js), "js-")
  end
end
