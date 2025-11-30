# Slash Command Grammar DSL

The `slash/2` DSL is built to make slash commands deterministic, easy to maintain, and fast. Instead of manually splitting strings or juggling regexes, you describe the format you expect and SlackBot generates a parser at compile time. This guide teaches the DSL in layers so you can follow along as the commands grow in complexity.

---

## Why use the DSL?

- **Deterministic parsing** – handlers receive structured maps, not ad-hoc token lists.
- **Readable expectations** – the command format lives next to the handler, making code
  reviews and maintenance straightforward.
- **Compile-time validation** – malformed definitions fail fast, before your bot ships.
- **Battle-tested parsing** – handles quoting, whitespace, and tricky edge cases without
  extra work on your part.

---

## 1. Literal-only commands

Great for “one-shot” commands that trigger behavior without arguments.

```elixir
slash "/cmd" do
  grammar do
    literal "project"
    literal "report"
  end

  handle payload, ctx do
    # payload["parsed"] => %{command: "cmd"}
    Reports.generate(ctx)
  end
end
```

**Slack input:** `/cmd project report`

---

## 2. Capturing values

Use `value/1` to bind user-provided tokens to names that show up in the parsed payload.

```elixir
slash "/cmd" do
  grammar do
    literal "team", as: :mode, value: :team_show
    value :team_name
    literal "show"
  end

  handle payload, ctx do
    %{team_name: name} = payload["parsed"]
    Teams.show(name, ctx)
  end
end
```

**Slack input:** `/cmd team marketing show`  
**Parsed payload:** `%{command: "cmd", mode: :team_show, team_name: "marketing"}`

---

## 3. Optional segments

Wrap anything that isn’t required in `optional`. Omitted segments simply don’t appear in
the parsed map.

```elixir
slash "/cmd" do
  grammar do
    literal "list", as: :mode, value: :list
    optional literal("short", as: :short?)
    value :app
  end

  handle payload, _ctx do
    payload["parsed"]
  end
end
```

**Slack input:** `/cmd list short foo`  
**Parsed payload:** `%{command: "cmd", mode: :list, short?: true, app: "foo"}`

---

## 4. Repeating segments

`repeat` lets you express “zero or more” patterns. Each `value` inside becomes a list.

```elixir
slash "/cmd" do
  grammar do
    literal "report", as: :mode, value: :report_teams

    repeat do
      literal "team"
      value :teams
    end
  end

  handle payload, _ctx do
    payload["parsed"]
  end
end
```

**Slack input:** `/cmd report team alpha team beta team gamma`  
**Parsed payload:** `%{teams: ["alpha", "beta", "gamma"], mode: :report_teams}`

---

## 5. Branching with `choice`

Many commands act like subcommands. `choice` lets you express each branch declaratively.

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
    parsed = payload["parsed"]
    handle_mode(parsed.mode, parsed, ctx)
  end
end
```

**Slack inputs covered:** `/cmd list app`, `/cmd list short app`, `/cmd project report`

---

## 6. End-to-end example

The tests (`test/slack_bot/router_test.exs`) contain a full “GrammarRouter” that combines
all the primitives. Here’s how a few Slack inputs map to payloads:

| Slack input | Parsed payload |
| --- | --- |
| `/cmd list short app param one param two` | `%{mode: :list, short?: true, app: "app", params: ["one","two"]}` |
| `/cmd project report` | `%{mode: :project_report}` |
| `/cmd team marketing show` | `%{mode: :team_show, team_name: "marketing"}` |
| `/cmd report team one team two team three` | `%{mode: :report_teams, teams: ["one","two","three"]}` |

Each branch is explicit, and the handler simply reacts to structured data.

---

## Handler payload structure

Every DSL handler receives an enriched payload under `payload["parsed"]`:

```elixir
%{
  command: "cmd",
  mode: :list,
  short?: true,
  app: "foo",
  params: ["one", "two"],
  teams: ["alpha", "beta"],
  extra_args: ["leftover"] # present only if tokens remain unmatched
}
```

- Repeated values become lists.
- Optional literals store the `value:` option (default `true`) when matched.
- Any leftover tokens land in `:extra_args`, allowing custom fallbacks.

---

## Quick reference

| Macro | Purpose | Example |
| --- | --- | --- |
| `literal value, opts \\ []` | Match a literal token, optionally tagging metadata | `literal "list", as: :mode, value: :list` |
| `value name, opts \\ []` | Capture a token and assign it to `name` | `value :service` |
| `optional do ... end` | Optional group; skipped segments leave previous values untouched | `optional literal("short", as: :short?)` |
| `repeat do ... end` | Repeat group until it no longer matches | `repeat do literal "team"; value :teams end` |
| `choice do ... end` | First matching branch wins | `choice do sequence ... end` |
| `sequence do ... end` | Explicit grouping (helpful inside `choice`) | `sequence do literal "project"; literal "report" end` |
| `handle payload, ctx do ... end` | Handler that receives the enriched payload | `handle payload, ctx do ... end` |

---

## Tips

- Use `SlackBot.Diagnostics.list/2` + `replay/2` to capture real commands and verify they parse as expected.
- Prefer small, focused `choice` branches over one giant handler with nested `case`.
- Need raw tokens? Call `SlackBot.Command.lex/1` yourself.
- See `test/slack_bot/router_test.exs` for more real-world examples.

---

## Next Steps

- [Getting Started](getting_started.md) — set up a Slack App and run your first handler
- [Rate Limiting](rate_limiting.md) — understand how SlackBot paces Web API calls
- [Diagnostics](diagnostics.md) — capture and replay commands for debugging
- [Telemetry Dashboard](telemetry_dashboard.md) — monitor handler execution and timing