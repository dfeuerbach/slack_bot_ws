defmodule SlackBot.TestRedis do
  @moduledoc false

  @default_url "redis://localhost:6379/0"
  @container "slackbot-ws-test-redis"
  @image "redis:7-alpine"
  @wait_ms 15_000
  @poll_interval 200
  @cleanup_flag {__MODULE__, :cleanup_registered}

  @doc """
  Ensures Redis is reachable for the test suite.

  Returns the URL that should be used by tests.
  """
  @spec ensure!() :: String.t()
  def ensure! do
    url = redis_url()

    case ping(url) do
      :ok ->
        url

      {:error, reason} ->
        if default_url?() do
          ensure_docker!()
          ensure_container_running()
          wait_until_ready(url, reason)
        else
          raise """
          Unable to connect to Redis at #{url}.

          Original error: #{inspect(reason)}.
          Provide a reachable REDIS_URL or start Redis manually.
          """
        end
    end
  end

  @doc """
  Returns the Redis URL used for tests (default: #{@default_url}).
  """
  @spec redis_url() :: String.t()
  def redis_url do
    System.get_env("REDIS_URL") || @default_url
  end

  @doc """
  Returns keyword options suitable for `Redix.start_link/1` based on `REDIS_URL`.
  """
  @spec redis_start_opts() :: keyword()
  def redis_start_opts do
    redis_url()
    |> URI.parse()
    |> uri_to_redix_opts()
  end

  @doc """
  Returns a unique instance name for Redis-backed processes in tests.
  """
  @spec unique_instance(atom() | String.t()) :: atom()
  def unique_instance(prefix \\ "SlackBot.TestRedis") do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp default_url?, do: System.get_env("REDIS_URL") in [nil, ""]

  defp ping(url) do
    with {:ok, conn} <- Redix.start_link(url, timeout: 1_000),
         {:ok, "PONG"} <- Redix.command(conn, ["PING"]) do
      Redix.stop(conn)
      :ok
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp ensure_docker! do
    unless System.find_executable("docker") do
      raise """
      docker CLI is not available and REDIS_URL is not configured.
      Install Docker Desktop or provide REDIS_URL to an existing Redis instance.
      """
    end
  end

  defp ensure_container_running do
    cond do
      container_running?() ->
        :ok

      container_exists?() ->
        docker!(["rm", "-f", @container])
        start_container()

      true ->
        start_container()
    end
  end

  defp container_running? do
    {output, 0} = docker(["ps", "-q", "--filter", "name=^#{@container}$"])
    String.trim(output) != ""
  rescue
    _ -> false
  end

  defp container_exists? do
    {output, 0} = docker(["ps", "-aq", "--filter", "name=^#{@container}$"])
    String.trim(output) != ""
  rescue
    _ -> false
  end

  defp start_container do
    docker!(["run", "-d", "--name", @container, "-p", "6379:6379", @image])
    register_cleanup()
  end

  defp wait_until_ready(url, last_error) do
    deadline = System.monotonic_time(:millisecond) + @wait_ms
    do_wait(url, deadline, last_error)
  end

  defp do_wait(url, deadline, last_error) do
    if System.monotonic_time(:millisecond) >= deadline do
      raise """
      Timed out waiting for Redis container #{@container} to become healthy.
      Last error: #{inspect(last_error)}
      """
    else
      case ping(url) do
        :ok ->
          url

        {:error, reason} ->
          Process.sleep(@poll_interval)
          do_wait(url, deadline, reason)
      end
    end
  end

  defp register_cleanup do
    unless cleanup_registered?() do
      :persistent_term.put(@cleanup_flag, true)

      System.at_exit(fn _ ->
        stop_container()
      end)
    end
  end

  defp cleanup_registered? do
    case :persistent_term.get(@cleanup_flag) do
      true -> true
    end
  rescue
    ArgumentError -> false
  end

  defp stop_container do
    docker(["stop", @container])
  rescue
    _ -> :ok
  end

  defp docker(args) do
    System.cmd("docker", args, stderr_to_stdout: true)
  end

  defp docker!(args) do
    case docker(args) do
      {output, 0} ->
        output

      {output, status} ->
        raise """
        docker #{Enum.join(args, " ")} failed with status #{status}:
        #{output}
        """
    end
  end

  defp uri_to_redix_opts(%URI{scheme: "redis"} = uri) do
    opts = [
      host: uri.host || "localhost",
      port: uri.port || 6379
    ]

    opts
    |> maybe_put(:database, parse_database(uri.path))
    |> maybe_put_auth(uri.userinfo)
  end

  defp uri_to_redix_opts(%URI{host: host, port: port}) do
    [
      host: host || "localhost",
      port: port || 6379
    ]
  end

  defp uri_to_redix_opts(_other) do
    [host: "localhost", port: 6379]
  end

  defp parse_database(nil), do: nil

  defp parse_database(path) when path in ["", "/"], do: nil

  defp parse_database(path) do
    path
    |> String.trim_leading("/")
    |> case do
      "" -> nil
      value -> String.to_integer(value)
    end
  rescue
    ArgumentError -> nil
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_auth(opts, nil), do: opts

  defp maybe_put_auth(opts, userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] ->
        opts
        |> maybe_put(:username, blank_to_nil(user))
        |> maybe_put(:password, blank_to_nil(pass))

      [value] ->
        opts
        |> maybe_put(:password, blank_to_nil(value))
    end
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
