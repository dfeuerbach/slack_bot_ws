defmodule SlackBot.Router do
  @moduledoc """
  Declarative handler DSL and middleware pipeline for SlackBot bots.

  By `use`-ing `SlackBot` (which delegates to this module), a bot gains macros to
  register event handlers, slash-command handlers, and middleware callbacks. At runtime,
  the `SlackBot.ConnectionManager` consults those definitions to dispatch incoming Socket
  Mode events.

  ## Example
  For a deeper tour of the DSL, see `docs/slash_grammar.md`.

      defmodule MyBot do
        use SlackBot

        middleware SlackBot.Middleware.Logger

        handle_event "message", event, ctx do
          respond(event["channel"], "Hello from \#{ctx.assigns.bot_name}")
        end

        slash "/deploy" do
          grammar do
            value :service
            optional literal("short", as: :short?)
            repeat do
              literal "param"
              value :params
            end
          end

          handle payload, ctx do
            parsed = payload["parsed"]
            Deployments.kick(parsed.service, parsed.params, ctx)
          end
        end
      end
  """

  require Logger

  alias SlackBot.SlashAck

  defmacro __using__(opts) do
    quote location: :keep do
      Module.register_attribute(__MODULE__, :slackbot_handlers, accumulate: true)
      Module.register_attribute(__MODULE__, :slackbot_middlewares, accumulate: true)

      import SlackBot.Router,
        only: [
          handle_event: 3,
          handle_event: 4,
          middleware: 1,
          slash: 2,
          slash: 3,
          grammar: 1,
          handle: 3,
          literal: 2,
          literal: 1,
          value: 2,
          value: 1,
          optional: 1,
          repeat: 1,
          choice: 1,
          sequence: 1
        ]

      @before_compile SlackBot.Router

      @slackbot_router_opts unquote(opts)
    end
  end

  @doc """
  Declares a handler for a given Slack event `type`.

  Accepts either `handle_event "message", payload do ... end` or the three-argument form
  where you can pattern-match on both the payload and the context (`ctx`).
  """
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

  @doc """
  Declares a slash command with a grammar + handler pair.

  Supports `:ack` option (`:inherit`, `:silent`, `:ephemeral`, or `{:custom, fun}`) to
  override the configured auto-ack strategy.
  """
  defmacro slash(command, do: block) when is_binary(command) do
    build_slash(command, [], block, __CALLER__)
  end

  defmacro slash(command, opts, do: block) when is_binary(command) and is_list(opts) do
    build_slash(command, opts, block, __CALLER__)
  end

  @doc """
  Wraps the grammar block for a given slash command.
  """
  defmacro grammar(do: block) do
    nodes = __eval_nodes__(block, __CALLER__)
    Macro.escape({:grammar, nodes})
  end

  @doc """
  Declares the handler that receives the enriched payload and context.
  """
  defmacro handle(payload, ctx, do: block) do
    quote do
      {:handle, unquote(payload), unquote(ctx), unquote(block)}
    end
  end

  defp build_slash(command, opts, block, env) do
    expanded = Macro.prewalk(block, &Macro.expand(&1, env))

    entries = __normalize_block__(expanded)
    grammar = fetch_section(entries, :grammar, env)
    handler = fetch_section(entries, :handle, env)

    grammar_nodes = expand_grammar(grammar)
    {payload, ctx, body} = handler
    fun = String.to_atom("__slackbot_slash_dsl_#{:erlang.unique_integer([:positive])}")
    normalized = normalize_command_literal(command)
    ack = Keyword.get(opts, :ack, :inherit)

    quote do
      @slackbot_handlers {:slash_dsl, unquote(normalized), unquote(fun),
                          unquote(Macro.escape(grammar_nodes)), unquote(ack)}

      def unquote(fun)(unquote(payload), unquote(ctx)) do
        unquote(body)
      end
    end
  end

  @doc """
  Matches a literal token in the grammar. Use `as:` to toggle booleans or tag metadata.
  """
  defmacro literal(value, opts \\ []) do
    Macro.escape({:literal, value, opts})
  end

  @doc """
  Captures the next token and assigns it to `name`.
  """
  defmacro value(name, opts \\ []) do
    Macro.escape({:value, name, opts})
  end

  @doc """
  Declares an optional group. If the block fails to match, the grammar continues.
  """
  defmacro optional(arg)

  defmacro optional(do: block) do
    nodes = __eval_nodes__(block, __CALLER__)
    Macro.escape({:optional, nodes})
  end

  defmacro optional(expr) do
    quote do
      SlackBot.Router.optional do
        unquote(expr)
      end
    end
  end

  @doc """
  Repeats the nested grammar until it no longer matches, collecting values into lists.
  """
  defmacro repeat(do: block) do
    nodes = __eval_nodes__(block, __CALLER__)
    Macro.escape({:repeat, nodes})
  end

  @doc """
  Evaluates each branch in order until one matches. Useful for subcommands.
  """
  defmacro choice(do: block) do
    branches =
      block
      |> __eval_nodes__(__CALLER__)
      |> Enum.map(&List.wrap/1)

    Macro.escape({:choice, branches})
  end

  @doc """
  Groups a sequence of literals/values. Handy inside `choice`.
  """
  defmacro sequence(do: block) do
    nodes = __eval_nodes__(block, __CALLER__)
    Macro.escape(nodes)
  end

  @doc """
  Registers middleware that will run before a handler.

  Middleware can be an MFA tuple, a module implementing `call/3`, or an anonymous
  function. Each middleware receives `{type, payload, ctx}` and must return either:

    * `{:cont, payload, ctx}` to continue the pipeline
    * `{:halt, response}` to stop execution
  """
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

      {:slash_dsl, command, fun, grammar, opts} ->
        handle_dsl_command(module, fun, command, grammar, opts, payload, ctx, middlewares)
    end
  end

  defp match_handler?({:event, type, _}, type, _payload), do: true

  defp match_handler?({:slash_dsl, command, _fun, _grammar, _opts}, "slash_commands", payload) do
    payload_command(payload) == command
  end

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

  @doc false
  def __normalize_block__({:__block__, _, exprs}), do: exprs
  def __normalize_block__(expr), do: [expr]

  @doc false
  def __normalize_branch__({:sequence, nodes}), do: nodes
  def __normalize_branch__(expr), do: [expr]

  @doc false
  def __eval_nodes__(block, env) do
    block
    |> __normalize_block__()
    |> Enum.map(fn expr ->
      expanded = Macro.expand(expr, env)
      {value, _} = Code.eval_quoted(expanded, [], env)
      value
    end)
  end

  defp fetch_section(entries, :grammar, env) do
    case Enum.find(entries, &match_ast?(:grammar, &1)) do
      nil ->
        raise ArgumentError, "missing grammar block"

      expr ->
        {value, _} = Code.eval_quoted(expr, [], env)

        case value do
          {:grammar, nodes} -> nodes
          _ -> raise ArgumentError, "invalid grammar definition"
        end
    end
  end

  defp fetch_section(entries, :handle, _env) do
    case Enum.find(entries, &match_ast?(:handle, &1)) do
      nil ->
        raise ArgumentError, "missing handle block"

      {:handle, payload, ctx, body} ->
        {payload, ctx, body}

      {:{}, _, [:handle, payload, ctx, body]} ->
        {payload, ctx, body}
    end
  end

  defp expand_grammar({:grammar, nodes}), do: expand_grammar(nodes)

  defp expand_grammar(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, &expand_node/1)
  end

  defp expand_node(list) when is_list(list), do: expand_grammar(list)
  defp expand_node({:literal, value, opts}), do: [{:literal, value, opts}]
  defp expand_node({:value, name, opts}), do: [{:value, name, opts}]
  defp expand_node({:optional, nodes}), do: [{:optional, expand_grammar(nodes)}]
  defp expand_node({:repeat, nodes}), do: [{:repeat, expand_grammar(nodes)}]

  defp expand_node({:choice, branches}) do
    [{:choice, Enum.map(branches, &expand_grammar/1)}]
  end

  defp expand_node(other), do: [other]

  defp normalize_command_literal(command) do
    command
    |> to_string()
    |> String.trim()
    |> String.trim_leading("/")
    |> String.downcase()
  end

  defp payload_command(payload) do
    case payload["command"] do
      nil -> nil
      cmd -> normalize_command_literal(cmd)
    end
  end

  defp handle_dsl_command(module, fun, command, grammar, opts, payload, ctx, middlewares) do
    case payload_command(payload) do
      ^command ->
        text = (payload["text"] || "") |> String.trim()

        with %{tokens: tokens} <- SlackBot.Command.lex(text),
             {:ok, parsed} <- SlackBot.CommandGrammar.match(grammar, tokens) do
          enriched = Map.put(parsed, :command, command)
          runner = fn payload, ctx -> apply(module, fun, [payload, ctx]) end
          ack_mode = resolve_ack_mode(opts, ctx)
          maybe_ack(ack_mode, payload, ctx)

          run_middlewares(
            middlewares,
            "slash_commands",
            Map.put(payload, "parsed", enriched),
            ctx,
            runner
          )
        else
          {:error, reason} ->
            Logger.warning("[SlackBot] slash DSL parse error: #{inspect(reason)}")
            :ok

          _ ->
            Logger.warning("[SlackBot] unable to lex slash command input")
            :ok
        end

      _ ->
        :ok
    end
  end

  defp resolve_ack_mode(option, ctx) do
    base = ctx_ack_mode(ctx)

    case option do
      :inherit -> base
      nil -> base
      other -> other
    end
  end

  defp ctx_ack_mode(%{config: %{ack_mode: mode}}), do: mode
  defp ctx_ack_mode(_), do: :silent

  defp maybe_ack(mode, payload, %{config: config}) do
    SlashAck.maybe_ack(mode, payload, config)
  end

  defp maybe_ack(_mode, _payload, _ctx), do: :ok

  defp match_ast?(label, {label, _, _}), do: true
  defp match_ast?(label, {label, _}), do: true

  defp match_ast?(label, {:{}, _, [label | _]}), do: true

  defp match_ast?(_, _), do: false
end
