defmodule Kafka.SimpleConsumer.Test do
  use ExUnit.Case
  import Mock

  test "new returns a valid consumer" do
    response = TestHelper.generate_metadata_response(1,
      [%{:node_id => 0, :host => "localhost", :port => 9092},
       %{:node_id => 1, :host => "foo",       :port => 9092}],
      [%{:error_code => 0, :name => "test", partitions:
          [%{:error_code => 0, :id => 0, :leader => 0, :replicas => [0,1], :isrs => [0,1]},
           %{:error_code => 0, :id => 1, :leader => 0, :replicas => [0,1], :isrs => [0,1]}]},
       %{:error_code => 0, :name => "fnord", partitions:
          [%{:error_code => 0, :id => 0, :leader => 1, :replicas => [0,1], :isrs => [0,1]},
           %{:error_code => 0, :id => 1, :leader => 1, :replicas => [0,1], :isrs => [0,1]}]}])

    connection = %{:correlation_id => 1, :client_id => "client_id"}
    with_mock Kafka.Connection, [send_and_return_response: fn(_, _) -> {:ok, connection, response} end,
                                 connect: fn(_, _) -> {:ok, connection} end] do
      {:ok, consumer} = Kafka.SimpleConsumer.new([["localhost", 9092]], "foo", "test", 0)
      assert consumer.connection == connection
      assert consumer.broker == %{:host => "localhost", :port => 9092}
    end
  end

  test "new returns an error when the topic doesn't exist" do
    response = TestHelper.generate_metadata_response(1,
      [%{:node_id => 0, :host => "localhost", :port => 9092},
       %{:node_id => 1, :host => "foo",       :port => 9092}],
      [%{:error_code => 0, :name => "test", partitions:
          [%{:error_code => 0, :id => 0, :leader => 0, :replicas => [0,1], :isrs => [0,1]},
           %{:error_code => 0, :id => 1, :leader => 0, :replicas => [0,1], :isrs => [0,1]}]},
       %{:error_code => 0, :name => "fnord", partitions:
          [%{:error_code => 0, :id => 0, :leader => 1, :replicas => [0,1], :isrs => [0,1]},
           %{:error_code => 0, :id => 1, :leader => 1, :replicas => [0,1], :isrs => [0,1]}]}])

    connection = %{:correlation_id => 1, :client_id => "client_id"}
    with_mock Kafka.Connection, [send_and_return_response: fn(_, _) -> {:ok, connection, response} end,
                                 connect: fn(_, _) -> {:ok, connection} end] do
      assert {:error, _, _} = Kafka.SimpleConsumer.new([["localhost", 9092]], "foo", "non-existent", 0)
    end
  end

  test "new returns an error when the broker can't be found" do
    with_mock Kafka.Connection, [connect: fn(_, _) -> {:error, "some error"} end] do
      assert {:error, _} = Kafka.SimpleConsumer.new([["localhost", 9092]], "foo", "non-existent", 0)
    end
  end

  test "fetch connects to the broker and returns data" do
    connection = %{:correlation_id => 1, :client_id => "client_id"}
    topic = "test"
    message_set = Kafka.Util.create_message_set("message")
    binary_response = << 1 :: 32, 1 :: 32, byte_size(topic) :: 16, topic :: binary, 1 :: 32, 0 :: 32, 0 :: 16, 0 :: 64, byte_size(message_set) :: 32, message_set :: binary >>
    response = %{"test" => %{0 => %{error_code: 0, hw_mark_offset: 0, message_set: [%{attributes: 0, crc: 3235376061, key: nil, offset: 0, value: "message"}]}}}
    consumer = %{:connection => connection, :broker => %{:host => "foo", :port => 9092}, :metadata => %{:timestamp => Kafka.Helper.get_timestamp},
      :topic => topic, :partition => 0}
    with_mock Kafka.Connection, [send_and_return_response: fn(_, _) -> {:ok, connection, binary_response} end,
                                 connect: fn(_, _) -> {:ok, connection} end] do
      assert {:ok, response, consumer} == Kafka.SimpleConsumer.fetch(consumer, 0)
    end
  end

  test "fetch returns error when it can't send to broker" do
    connection = %{:correlation_id => 1, :client_id => "client_id"}
    consumer = %{:connection => connection, :broker => %{:host => "foo", :port => 9092}, :metadata => %{:timestamp => Kafka.Helper.get_timestamp},
      :topic => "test", :partition => 0}
    with_mock Kafka.Connection, [send_and_return_response: fn(_, _) -> {:error, :boom} end] do
      assert {:error, :boom} == Kafka.SimpleConsumer.fetch(consumer, 0)
    end
  end

  test "fetch updates metadata after 5 minutes and doesn't rebalance if not necessary" do
    topic = "test"
    message_set = Kafka.Util.create_message_set("message")
    binary_response = << 1 :: 32, 1 :: 32, byte_size(topic) :: 16, topic :: binary, 1 :: 32, 0 :: 32, 0 :: 16, 0 :: 64, byte_size(message_set) :: 32, message_set :: binary >>
    response = %{:topic => %{0 => %{error_code: 0, hw_mark_offset: 0, message_set: [%{attributes: 0, crc: 3235376061, key: nil, offset: 0, value: "message"}]}}}
    connection = %{:correlation_id => 1, :client_id => "client_id"}
    consumer = %{:connection => connection, :broker => %{:host => "localhost", :port => 9092},
      :metadata => %{:connection => connection, :timestamp => Kafka.Helper.get_timestamp - 5 * 60 * 1000},
      :topic => topic, :partition => 0}
    with_mock Kafka.Connection, [connect: fn(_, _) -> {:ok, connection} end,
                                 send_and_return_response: fn(_, _) -> {:ok, connection, binary_response} end,
                                 close: fn(_) -> :ok end] do
      with_mock Kafka.Metadata, [update: fn(_) -> {:ok, :updated, %{}} end,
                                 get_broker: fn(_, _, _) -> {:ok, %{:host => "localhost", :port => 9092}, %{}} end] do
        Kafka.SimpleConsumer.fetch(consumer, 0)
        assert !called Kafka.Connection.connect(%{host: "foo", port: 9092}, "client_id")
      end
    end
  end

  test "fetch updates metadata after 5 minutes and rebalances if necessary" do
    topic = "test"
    message_set = Kafka.Util.create_message_set("message")
    binary_response = << 1 :: 32, 1 :: 32, byte_size(topic) :: 16, topic :: binary, 1 :: 32, 0 :: 32, 0 :: 16, 0 :: 64, byte_size(message_set) :: 32, message_set :: binary >>
    response = %{:topic => %{0 => %{error_code: 0, hw_mark_offset: 0, message_set: [%{attributes: 0, crc: 3235376061, key: nil, offset: 0, value: "message"}]}}}
    connection = %{:correlation_id => 1, :client_id => "client_id"}
    consumer = %{:connection => connection, :broker => %{:host => "localhost", :port => 9092},
      :metadata => %{:connection => connection, :timestamp => Kafka.Helper.get_timestamp - 5 * 60 * 1000},
      :topic => topic, :partition => 0}
    with_mock Kafka.Connection, [connect: fn(_, _) -> {:ok, connection} end,
                                 send_and_return_response: fn(_, _) -> {:ok, connection, binary_response} end,
                                 close: fn(_) -> :ok end] do
      with_mock Kafka.Metadata, [update: fn(_) -> {:ok, :updated, %{}} end,
                                 get_broker: fn(_, _, _) -> {:ok, %{:host => "foo", :port => 9092}, %{}} end] do
        Kafka.SimpleConsumer.fetch(consumer, 0)
        assert called Kafka.Connection.connect(%{host: "foo", port: 9092}, "client_id")
      end
    end
  end
end