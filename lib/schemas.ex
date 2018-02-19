defmodule Kaufmann.Schemas do
  @moduledoc """
    Handles registration, retrieval, validation and parsing of Avro Schemas


    Depends on 
     - Schemex - calls to Confluent Schema Registry
     - avro_ex - serializing and deserializing avro encoded messages
  """

  # Todo: Convert this module into a service that can cache loaded schemas

  require Logger
  require Map.Helpers

  @spec encode_message(String.t(), Map) :: {atom, any}
  def encode_message(message_name, payload) do
    with {:ok, schema} <- parsed_schema(message_name) do
      stringified = Map.Helpers.stringify_keys(payload)
      encode_message_with_schema(schema, stringified)
    else
      {:error, error_message} ->
        {:error, error_message}
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
        {:error, error_message}
    end
  end

  def atomize_keys({:ok, args}) do
    {:ok, Map.Helpers.atomize_keys(args)}
  end

  def atomize_keys(args), do: args

  def get(subject) do
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
    Kaufmann.Config.schema_registry_uri()
  end

  defp encode_message_with_schema(schema, message) do
    AvroEx.encode(schema, message)
  rescue
    # avro_ex can become confused when trying to encode some schemas. 
    _ ->
      {:error, :unmatching_schema}
  end

  defp decode_message_with_schema(schema, encoded) do
    AvroEx.decode(schema, encoded)
  rescue
    # avro_ex can become confused when trying to decode some schemas. 
    _ ->
      {:error, :unmatching_schema}
  end

  defp parsed_schema(message_name) do
    with {:ok, schema_name} <- if_partial_schema(message_name),
         {:ok, %{"schema" => raw_schema}} <- get(schema_name),
         {:ok, %{"schema" => metadata_schema}} <- get('event_metadata') do
      AvroEx.parse_schema("[#{metadata_schema}, #{raw_schema}]")
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
end