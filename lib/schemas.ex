defmodule KaufmannEx.Schemas do
  @moduledoc """
    Handles registration, retrieval, validation and parsing of Avro Schemas.

    Schemas are cached to ETS table using `Memoize`. Does not handle schema changes while running. Best practice is to redeploy all services using a message schema if the schema changes.

    Depends on
     - `Schemex` - calls to Confluent Schema Registry
     - `AvroEx` - serializing and deserializing avro encoded messages
     - `Memoize` - Cache loading schemas to an ETS table, prevent performance bottleneck at schema registry.
  """

  use Memoize
  require Logger
  require Map.Helpers
  alias KaufmannEx.Config

  @spec encode_message(String.t(), Map) :: {atom, any}
  def encode_message(message_name, payload) do
    with {:ok, schema} <- parsed_schema(message_name) do
      stringified = Map.Helpers.stringify_keys(payload)
      encode_message_with_schema(schema, stringified)
    else
      {:error, error_message} ->
        Logger.debug(fn -> "Error Encoding #{message_name}, #{inspect(payload)}" end)

        {:error, {:schema_encoding_error, error_message}}
    end
  end

  @spec decode_message(String.t(), binary) :: {atom, any}
  def decode_message(message_name, encoded) do
    with {:ok, schema} <- parsed_schema(message_name) do
      schema
      |> decode_message_with_schema(encoded)
      |> atomize_keys()
    else
      {:error, error_message} ->
        {:error, {:schema_decoding_error, error_message}}
    end
  end

  @doc """
  Load schema from registry, inject metadata schema, parse into AvroEx schema

  Memoized with permament caching.
  """
  defmemo parsed_schema(message_name), expires_in: Config.schema_cache_expires_in_ms() do
    with {:ok, schema_name} <- if_partial_schema(message_name),
         {:ok, %{"schema" => raw_schema}} <- get(schema_name) do
      AvroEx.parse_schema(raw_schema)
    end
  end

  defp if_partial_schema(message_name) do
    event_string = message_name |> to_string

    schema_name =
      cond do
        Regex.match?(~r/^query\./, event_string) ->
          String.slice(event_string, 0..8)

        Regex.match?(~r/^event\.error\./, event_string) ->
          String.slice(event_string, 0..10)

        true ->
          event_string
      end

    {:ok, schema_name}
  end

  defp encode_message_with_schema(schema, message) do
    AvroEx.encode(schema, message)
  rescue
    # avro_ex can become confused when trying to encode some schemas.
    error ->
      Logger.debug(["Could not encode schema \n\t", inspect(error)])
      {:error, :unmatching_schema}
  end

  defp decode_message_with_schema(schema, encoded) do
    AvroEx.decode(schema, encoded)
  rescue
    # avro_ex can become confused when trying to decode some schemas.
    _ ->
      {:error, :unmatching_schema}
  end

  defp atomize_keys({:ok, args}) do
    {:ok, Map.Helpers.atomize_keys(args)}
  end

  defp atomize_keys(args), do: args

  @doc """
  Get schema from registry

  memoized permanetly
  """
  defmemo get(subject), expires_in: Config.schema_cache_expires_in_ms() do
    schema_registry_uri()
    |> Schemex.latest(subject)
  end

  def register(subject, schema) do
    schema_registry_uri()
    |> Schemex.register(subject, schema)
  end

  def register({subject, schema}), do: register(subject, schema)

  def check(subject, schema) do
    schema_registry_uri()
    |> Schemex.check(subject, schema)
  end

  def test(subject, schema) do
    schema_registry_uri()
    |> Schemex.test(subject, schema)
  end

  def subjects do
    schema_registry_uri()
    |> Schemex.subjects()
  end

  def delete(subject) do
    schema_registry_uri()
    |> Schemex.delete(subject)
  end

  def defined_event?(subject) do
    {:ok, _} =
      schema_registry_uri()
      |> Schemex.latest(subject)
  end

  def encodable?(subject, payload) do
    {:ok, schema} = parsed_schema(subject |> to_string())
    AvroEx.encodable?(schema, payload)
  end

  defp schema_registry_uri do
    KaufmannEx.Config.schema_registry_uri()
  end
end
