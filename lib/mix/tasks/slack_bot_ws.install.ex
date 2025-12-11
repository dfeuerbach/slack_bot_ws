defmodule Mix.Tasks.SlackBotWs.Install do
  @moduledoc """
  Installs a minimal SlackBot instance into the current OTP application.

  This task:

    * Creates a bot module using `use SlackBot, otp_app: :your_app`.
    * Adds a config stub under `config/config.exs`.
    * Appends the bot module to your application supervisor's children.

  It relies on Igniter when available. When Igniter is not present, the task
  will print a short message explaining the manual steps instead of modifying
  files.
  """

  use Mix.Task

  # Igniter is an optional dependency; suppress warnings when it is not present.
  @compile {:no_warn_undefined, [Igniter, Igniter.Project.Application, Rewrite.Source]}
  alias Rewrite.Source

  @shortdoc "Scaffolds a SlackBot instance using Igniter when available"

  @impl true
  def run(_argv) do
    Mix.Task.run("app.start", [])

    app = Mix.Project.config()[:app] || raise "unable to determine :app from mix.exs"
    base_mod = app |> Atom.to_string() |> Macro.camelize()
    bot_module = Module.concat([base_mod, "SlackBot"])

    case Code.ensure_loaded(Igniter) do
      {:module, _} ->
        run_with_igniter(app, bot_module)

      _ ->
        run_without_igniter(app, bot_module)
    end
  end

  defp run_with_igniter(app, bot_module) do
    Mix.shell().info("""
    > Detected Igniter - generating #{inspect(bot_module)} and wiring it into your app.
    """)

    igniter = Igniter.new()

    igniter =
      igniter
      |> create_bot_module(app, bot_module)
      |> ensure_config(app, bot_module)
      |> ensure_supervisor_child(app, bot_module)
      |> ensure_agents_doc()

    case Igniter.do_or_dry_run(igniter, title: "SlackBot installer") do
      result when result in [:changes_made, :no_changes, :dry_run_with_no_changes] ->
        Mix.shell().info("""
        SlackBot install complete.

        Next steps:

          1. Set SLACK_APP_TOKEN and SLACK_BOT_TOKEN in your environment.
          2. Start your application with `iex -S mix`.
          3. Invite your bot to a channel and @mention it.

        Guides:
          - Getting Started: https://hexdocs.pm/slack_bot_ws/getting-started.html
          - Slash Grammar:   https://hexdocs.pm/slack_bot_ws/slash-grammar.html
          - Diagnostics:     https://hexdocs.pm/slack_bot_ws/diagnostics.html
        """)

      other ->
        Mix.shell().error("SlackBot install aborted: #{inspect(other)}")
    end
  end

  defp run_without_igniter(app, bot_module) do
    Mix.shell().info("""
    Igniter is not available, so SlackBot cannot auto-edit your project.

    To wire SlackBot manually:

      1. Create a bot module at lib/#{app}/slack_bot.ex:

           defmodule #{inspect(bot_module)} do
             use SlackBot, otp_app: :#{app}

             handle_event "app_mention", event, _ctx do
               SlackBot.push({"chat.postMessage", %{
                 "channel" => event["channel"],
                 "text" => "Hi <@\#{event["user"]}>!"
               }})
             end
           end

      2. Add config in config/config.exs:

           config :#{app}, #{inspect(bot_module)},
             app_token: System.fetch_env!("SLACK_APP_TOKEN"),
             bot_token: System.fetch_env!("SLACK_BOT_TOKEN")

      3. Add #{inspect(bot_module)} to your application supervisor's children list.

    For a complete walkthrough, see the Getting Started guide:
    https://hexdocs.pm/slack_bot_ws/getting-started.html
    """)
  end

  defp create_bot_module(igniter, app, bot_module) do
    file =
      app
      |> Atom.to_string()
      |> then(&Path.join(["lib", &1, "slack_bot.ex"]))

    contents = """
    defmodule #{inspect(bot_module)} do
      use SlackBot, otp_app: :#{app}
    end
    """

    Igniter.create_new_file(igniter, file, contents, on_exists: :skip)
  end

  defp ensure_config(igniter, app, bot_module) do
    config_file = "config/config.exs"

    snippet = """

    config :#{app}, #{inspect(bot_module)},
      app_token: System.fetch_env!("SLACK_APP_TOKEN"),
      bot_token: System.fetch_env!("SLACK_BOT_TOKEN")
    """

    append_once(igniter, config_file, snippet)
  end

  defp ensure_supervisor_child(igniter, _app, bot_module) do
    Igniter.Project.Application.add_new_child(igniter, bot_module)
  end

  defp ensure_agents_doc(igniter) do
    case library_agents_content() do
      {:ok, contents} ->
        snippet = """

        ## SlackBot

        #{contents}
        """

        target =
          if File.exists?("AGENTS.md") do
            "AGENTS.md"
          else
            "SLACK_BOT_AGENTS.md"
          end

        append_once(igniter, target, snippet)

      :error ->
        igniter
    end
  end

  defp append_once(igniter, path, snippet) do
    trimmed = String.trim(snippet)

    igniter
    |> Igniter.include_or_create_file(path, "")
    |> Igniter.update_file(path, &maybe_append(&1, trimmed))
  end

  defp maybe_append(source, trimmed) do
    content = Source.get(source, :content)

    content
    |> contains_snippet?(trimmed)
    |> maybe_update_source(source, content, trimmed)
  end

  defp contains_snippet?(content, snippet), do: String.contains?(content, snippet)

  defp maybe_update_source(true, source, _content, _trimmed), do: source

  defp maybe_update_source(false, source, content, trimmed) do
    new_content = content <> separator_for(content) <> trimmed <> "\n"
    Source.update(source, :content, new_content)
  end

  defp separator_for(content) do
    flags = {
      String.trim(content) == "",
      String.ends_with?(content, "\n\n"),
      String.ends_with?(content, "\n")
    }

    separator_from_flags(flags)
  end

  defp separator_from_flags({true, _double, _single}), do: ""
  defp separator_from_flags({_blank, true, _single}), do: ""
  defp separator_from_flags({_blank, _double, true}), do: "\n"
  defp separator_from_flags({_blank, _double, _single}), do: "\n\n"

  defp library_agents_content do
    deps_paths = Mix.Project.deps_paths()

    case Map.get(deps_paths, :slack_bot_ws) do
      nil ->
        :error

      path ->
        path
        |> Path.join("AGENTS.md")
        |> File.read()
        |> case do
          {:ok, contents} -> {:ok, contents}
          _ -> :error
        end
    end
  end
end
