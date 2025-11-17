defmodule SlackBot.Router do
  @moduledoc """
  Provides handler DSL and middleware pipeline for SlackBot modules.
  """

  require Logger

  defmacro __using__(opts) do
    quote location: :keep do
      Module.register_attribute(__MODULE__, :slackbot_handlers, accumulate: true)
      Module.register_attribute(__MODULE__, :slackbot_middlewares, accumulate: true)

      import SlackBot.Router,
        only: [handle_event: 3, handle_event: 4, handle_slash: 3, handle_slash: 4, middleware: 1]

      @before_compile SlackBot.Router

      @slackbot_router_opts unquote(opts)
    end
  end

  defmacro handle_event(type, payload, ctx \\ Macro.var(:_ctx, __CALLER__.module), do: block)
           when is_binary(type) do
    handler = String.to_atom("__slackbot_event_#{:erlang.unique_integer([:positive])}")

    quote do
      @slackbot_handlers {:event, unquote(type), unquote(handler)}

      def unquote(handler)(unquote(payload), unquote(ctx)) do
        unquote(block)
      end
    end
  end

  defmacro handle_slash(command, payload, ctx \\ Macro.var(:_ctx, __CALLER__.module), do: block)
           when is_binary(command) do
    handler = String.to_atom("__slackbot_slash_#{:erlang.unique_integer([:positive])}")

    quote do
      @slackbot_handlers {:slash, unquote(command), unquote(handler)}

      def unquote(handler)(unquote(payload), unquote(ctx)) do
        unquote(block)
      end
    end
  end

  defmacro middleware(fun) when is_atom(fun) or is_tuple(fun) do
    quote do
      @slackbot_middlewares unquote(fun)
    end
  end

  defmacro __before_compile__(env) do
    handlers = Module.get_attribute(env.module, :slackbot_handlers)
    middlewares = Module.get_attribute(env.module, :slackbot_middlewares)

    quote do
      @behaviour SlackBot.Router.Handler

      @impl true
      def __slackbot_handlers__, do: unquote(Macro.escape(handlers))

      @impl true
      def __slackbot_middlewares__, do: unquote(Macro.escape(middlewares))

      @impl true
      def handle_event(type, payload, ctx) do
        SlackBot.Router.dispatch(__MODULE__, type, payload, ctx)
      end
    end
  end

  defmodule Handler do
    @callback handle_event(String.t(), map(), map()) :: any()
    @callback __slackbot_handlers__() :: list()
    @callback __slackbot_middlewares__() :: list()
  end

  def dispatch(module, type, payload, ctx) do
    handlers = module.__slackbot_handlers__()
    middlewares = module.__slackbot_middlewares__()

    case Enum.find(handlers, &match_handler?(&1, type, payload)) do
      nil ->
        :ok

      {:event, _type, fun} ->
        runner = fn payload, ctx -> apply(module, fun, [payload, ctx]) end
        run_middlewares(middlewares, type, payload, ctx, runner)

      {:slash, command, fun} ->
        text = (payload["text"] || "") |> String.trim()
        composed =
          case payload["command"] do
            nil -> text
            cmd -> String.trim("#{cmd} #{text}")
          end

        case SlackBot.Command.parse_slash(composed) do
          {:error, reason, _rest, _context, _line, _column} ->
            Logger.warning("[SlackBot] slash parse error: #{inspect(reason)}")
            :ok

          parsed ->
            normalized = String.trim_leading(command, "/")

            if Map.get(parsed, :command) == normalized do
              runner = fn payload, ctx -> apply(module, fun, [payload, ctx]) end
              run_middlewares(middlewares, type, Map.put(payload, "parsed", parsed), ctx, runner)
            else
              :ok
            end
        end
    end
  end

  defp match_handler?({:event, type, _}, type, _payload), do: true
  defp match_handler?({:slash, _command, _}, "slash_commands", _payload), do: true
  defp match_handler?(_, _, _), do: false

  defp run_middlewares([], _type, payload, ctx, fun) do
    fun.(payload, ctx)
  end

  defp run_middlewares([middleware | rest], type, payload, ctx, fun) do
    case apply_middleware(middleware, type, payload, ctx) do
      {:cont, new_payload, new_ctx} ->
        run_middlewares(rest, type, new_payload, new_ctx, fun)

      {:halt, response} ->
        response
    end
  end

  defp apply_middleware({mod, func}, type, payload, ctx),
    do: apply(mod, func, [type, payload, ctx])

  defp apply_middleware(fun, type, payload, ctx) when is_function(fun, 3),
    do: fun.(type, payload, ctx)

  defp apply_middleware(fun, type, payload, ctx) when is_atom(fun),
    do: apply(fun, :call, [type, payload, ctx])
end
