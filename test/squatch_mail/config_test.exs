defmodule SquatchMail.ConfigTest do
  use ExUnit.Case, async: true

  alias SquatchMail.Config

  test "repo/0 returns the configured repo" do
    assert Config.repo() == SquatchMail.Test.Repo
  end

  test "prefix/0 defaults to \"squatch_mail\"" do
    Application.delete_env(:squatch_mail, :prefix)
    assert Config.prefix() == "squatch_mail"
  after
    Application.delete_env(:squatch_mail, :prefix)
  end

  test "prefix/0 reads the configured value" do
    Application.put_env(:squatch_mail, :prefix, "custom_schema")
    assert Config.prefix() == "custom_schema"
  after
    Application.delete_env(:squatch_mail, :prefix)
  end

  test "enabled?/0 defaults to true" do
    assert Config.enabled?()
  end

  test "otp_app/0 returns the configured otp_app" do
    assert Config.otp_app() == :squatch_mail
  end
end
