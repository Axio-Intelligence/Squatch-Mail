defmodule SquatchMail.PublicId do
  @moduledoc """
  Generates prefixed, URL-safe public identifiers backed by random bytes.

  SquatchMail rows use opaque `bigserial` primary keys internally, but expose a
  stable, non-enumerable `public_id` (e.g. `"em_4f9Kd2..."`) in URLs and APIs so
  that internal row counts never leak. The random suffix is a base62 encoding of
  cryptographically strong random bytes, keeping ids short and copy/paste-safe
  (no `-`, `_`, `+`, or `/`).

  This module has no external dependencies; it relies only on
  `:crypto.strong_rand_bytes/1`.
  """

  @alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  @base 62

  @doc """
  Generates a prefixed public id, e.g. `generate("em")` => `"em_9aXd2Kf..."`.

  `bytes` controls the amount of entropy (default 16 bytes / 128 bits).
  """
  @spec generate(String.t(), pos_integer()) :: String.t()
  def generate(prefix, bytes \\ 16)
      when is_binary(prefix) and is_integer(bytes) and bytes > 0 do
    prefix <> "_" <> random_base62(bytes)
  end

  @doc """
  Returns a base62 string derived from `bytes` cryptographically random bytes.

  Useful for opaque tokens (e.g. per-source webhook tokens) that don't need a
  human-facing prefix.
  """
  @spec random_base62(pos_integer()) :: String.t()
  def random_base62(bytes) when is_integer(bytes) and bytes > 0 do
    bytes
    |> :crypto.strong_rand_bytes()
    |> encode()
  end

  @doc """
  Encodes a binary as a base62 string. An all-zero binary encodes to `"0"`.
  """
  @spec encode(binary()) :: String.t()
  def encode(binary) when is_binary(binary) do
    binary
    |> :binary.decode_unsigned()
    |> encode_integer()
  end

  defp encode_integer(0), do: <<Enum.at(@alphabet, 0)>>

  defp encode_integer(int) when is_integer(int) and int > 0 do
    int
    |> do_encode([])
    |> List.to_string()
  end

  defp do_encode(0, acc), do: acc

  defp do_encode(int, acc) do
    do_encode(div(int, @base), [Enum.at(@alphabet, rem(int, @base)) | acc])
  end
end
