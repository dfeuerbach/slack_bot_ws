# Slash Command Grammar DSL

SlackBot ships with a grammar-oriented DSL that compiles to NimbleParsec parsers. Each
`slash/2` block lets you declare literals, values, optionals, choices, and repeats so that
handlers receive structured maps instead of ad-hoc token lists.

## Quick Reference

| Macro | Purpose | Example |
| --- | --- | --- |
| `literal value, opts \\ []` | Match a literal token, optionally tagging it | `literal "list", as: :mode, value: :list` |
| `value name, opts \\ []` | Capture a token and assign it to `name` | `value :service` |
| `optional do ... end` | Optional group; skipping it leaves previous values untouched | `optional literal("short", as: :short?)` |
| `repeat do ... end` | Repeat group until it no longer matches | `repeat do literal "team"; value :teams end` |
| `choice do ... end` | First matching branch wins | `choice do sequence ... end` |
| `sequence do ... end` | Explicit grouping (useful inside `choice`) | `sequence do literal "project"; literal "report" end` |
| `handle payload, ctx do ... end` | Handler that receives the enriched payload | `handle payload, ctx do ... end` |

## Examples

### Literal-Only Command

```elixir
slash "/cmd" do
  grammar do
    literal "project", as: :mode, value: :project_report
    literal "report"
  end

  handle payload, ctx do
    # payload["parsed"] => %{command: "cmd", mode: :project_report}
  end
end
```

Slack input: `/cmd project report`

Handler payload:

```elixir
%{command: "cmd", mode: :project_report}
```

### Literal with Named Value

```elixir
slash "/cmd" do
  grammar do
    literal "team", as: :mode, value: :team_show
    value :team_name
    literal "show"
  end

  handle payload, ctx do
    # payload["parsed"] => %{command: "cmd", mode: :team_show, team_name: "marketing"}
  end
end
```

Slack input: `/cmd team marketing show`

### Optional Literal + Value

```elixir
slash "/cmd" do
  grammar do
    literal "list", as: :mode, value: :list
    optional literal("short", as: :short?)
    value :app
  end

  handle payload, ctx do
    # payload["parsed"] => %{command: "cmd", mode: :list, short?: true, app: "foo"}
  end
end
```

Slack input: `/cmd list short foo`

### Repeating Segments

```elixir
slash "/cmd" do
  grammar do
    literal "report", as: :mode, value: :report_teams

    repeat do
      literal "team"
      value :teams
    end
  end

  handle payload, ctx do
    # payload["parsed"] => %{command: "cmd", mode: :report_teams, teams: ["one","two","three"]}
  end
end
```

Slack input: `/cmd report team one team two team three`

### Full Choice Grammar

```elixir
slash "/cmd" do
  grammar do
    choice do
      sequence do
        literal "list", as: :mode, value: :list
        optional literal("short", as: :short?)
        value :app
      end

      sequence do
        literal "project", as: :mode, value: :project_report
        literal "report"
      end
    end
  end

  handle payload, ctx do
    # handle whichever branch matched
  end
end
```

## Handler Payload

Every DSL handler receives `payload["parsed"]`, which contains:

```elixir
%{
  command: "cmd",
  mode: :list,
  short?: true,
  app: "foo",
  params: ["one", "two"],
  teams: ["alpha", "beta"],
  extra_args: ["leftover", "tokens"] # only if tokens remain unmatched
}
```

- Repeated `value` definitions become lists (e.g., `params`, `teams`).
- Optional literals store their `value:` option (default `true`) when matched.
- Any tokens left after the grammar completes land in `:extra_args` for custom handling.

## Tips

- Use `choice` to model top-level subcommands (e.g., `/cmd list`, `/cmd report`, `/cmd team ...`).
- Combine `literal "param"` with `value :params` inside `repeat` to support open-ended argument lists.
- If you need to expose the raw tokens as a fallback, you can also call `SlackBot.Command.lex/1`.

For a deeper dive, see `README.md` and the tests in `test/slack_bot/router_test.exs`.

