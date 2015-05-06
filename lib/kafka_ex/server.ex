defmodule KafkaEx.Server do
  @client_id "kafka_ex"

  ### GenServer Callbacks
  use GenServer

  def start_link(uris, name \\ __MODULE__) do
    GenServer.start_link(__MODULE__, uris, [name: name])
  end

  def init(uris) do
    client = KafkaEx.NetworkClient.new(@client_id)
    metadata = KafkaEx.Metadata.new(uris)
    send(self, :metadata)
    {:ok, {metadata, client, nil}}
  end

  def handle_call({:produce, topic, partition, value, key, required_acks, timeout}, _from, {metadata, client, event_pid}) do
    data = [topic, partition, value, key, required_acks, timeout]
    {metadata, client, response} = send_request(metadata, client, topic, partition, KafkaEx.Protocol.Produce, data, timeout)
    response = case required_acks do
      0 -> :ok
      _ -> response
    end
    {:reply, response, {metadata, client, event_pid}}
  end

  def handle_call({:fetch, topic, partition, offset, wait_time, min_bytes, max_bytes}, _from, {metadata, client, event_pid}) do
    data = [topic, partition, offset, wait_time, min_bytes, max_bytes]
    {metadata, client, response} = send_request(metadata, client, topic, partition, KafkaEx.Protocol.Fetch, data)
    {:reply, response, {metadata, client, event_pid}}
  end

  def handle_call({:offset, topic, partition, time}, _from, {metadata, client, event_pid}) do
    data = [topic, partition, time]
    {metadata, client, response} = send_request(metadata, client, topic, partition, KafkaEx.Protocol.Offset, data)
    {:reply, response, {metadata, client, event_pid}}
  end

  def handle_call({:metadata, topic}, _from, {metadata, client, event_pid}) do
    {metadata, client} = KafkaEx.Metadata.add_topic(metadata, client, topic)
    {:reply, metadata, {metadata, client, event_pid}}
  end

  def handle_call({:create_stream, handler}, _from, {metadata, client, event_pid}) do
    unless event_pid && Process.alive?(event_pid) do
      {:ok, event_pid}  = GenEvent.start_link
    end
    GenEvent.add_handler(event_pid, handler, [])
    {:reply, GenEvent.stream(event_pid), {metadata, client, event_pid}}
  end

  @wait_time 10
  @min_bytes 1
  @max_bytes 1_000_000
  def handle_info({:start_streaming, topic, partition, offset, handler}, {metadata, client, event_pid}) do
    {metadata, client} = start_stream(event_pid, metadata, client, handler, topic, partition, offset)
    {:noreply, {metadata, client, event_pid}}
  end

  def handle_info(:metadata, {metadata, client, event_pid}) do
    {metadata, client} = KafkaEx.Metadata.update(metadata, client)
    {:noreply, {metadata, client, event_pid}}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  def terminate(_, {_, client, nil}) do
    KafkaEx.NetworkClient.shutdown(client)
  end

  def terminate(_, {_, client, event_pid}) do
    KafkaEx.NetworkClient.shutdown(client)
    Process.exit(event_pid, :kill)
  end

  defp notify_handler([], _handler_pid, offset), do: offset

  defp notify_handler([message_set|message_sets], handler_pid, _offset) do
    GenEvent.notify(handler_pid, message_set)
    notify_handler(message_sets, handler_pid, message_set.offset)
  end

  defp handle_message_sets([], pid, metadata, client, handler, topic, partition, offset) do
    :timer.sleep(1000)
    start_stream(pid, metadata, client, handler, topic, partition, offset)
  end

  defp handle_message_sets(message_sets, pid, metadata, client, handler, topic, partition, offset) do
    last_offset = notify_handler(message_sets, pid, offset)
    start_stream(pid, metadata, client, handler, topic, partition, last_offset+1)
  end

  defp start_stream(pid, metadata, client, handler, topic, partition, offset) do
    data = [topic, partition, offset, @wait_time, @min_bytes, @max_bytes]
    {metadata, client} = send_request(metadata, client, topic, partition, KafkaEx.Protocol.Fetch, data, 100, false)
    receive do
      {:tcp, _, data} ->
        {:ok, response} = KafkaEx.Protocol.Fetch.parse_response(data)
        message_sets = response[topic][partition].message_set
        handle_message_sets(message_sets, pid, metadata, client, handler, topic, partition, offset)
      :stop_streaming ->
        {metadata, client}
    end
  end

  defp send_request(metadata, client, topic, partition, protocol_mod, data, timeout \\ 100, require_response \\ true) do
    {metadata, client} = KafkaEx.Metadata.add_topic(metadata, client, topic)

    broker = KafkaEx.Metadata.broker_for_topic(metadata, topic, partition)
    if broker == nil, do: raise "No broker found for topic #{topic}"

    client = KafkaEx.NetworkClient.send_request(client, [broker], data, protocol_mod)
    if require_response do
      {client, response} = KafkaEx.NetworkClient.get_response(client, timeout)
      {metadata, client, protocol_mod.parse_response(response)}
    else
      {metadata, client}
    end
  end
end
