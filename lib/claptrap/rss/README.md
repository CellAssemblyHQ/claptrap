# RSS

A self-contained RSS 2.0 library for parsing, generating, and
validating feeds. It has no dependencies on the rest of
Claptrap and models the RSS 2.0 specification as a tree of
typed Elixir structs.

This is deliberately a library rather than a subsystem.
Claptrap's consumer uses it to parse incoming RSS, and the
producer uses it to generate RSS bodies for sinks, but neither
caller is special — the library could be lifted out and used
elsewhere unchanged.

## Architecture

```
XML binary ──▶ Parser ──▶ Feed struct ──▶ Validator
                                │
                                ▼
                           Generator ──▶ XML binary
```

The public API is the facade module `Claptrap.RSS` (in
`../rss.ex`), which exposes `parse/2`, `generate/2`,
`validate/1`, and their bang variants. Everything in this
directory is internal except the structs themselves, which
callers construct and read directly.

## Structs and builders

Every RSS element is a typed struct with enforced keys matching
the spec's required fields. `Feed` and `Item` provide a fluent
builder API for pipeline-style construction:

```elixir
Feed.new("Title", "https://example.com", "A feed")
|> Feed.put_language("en-us")
|> Feed.add_category(Category.new("tech"))
|> Feed.add_item(Item.new(title: "Hello"))
```

Builders do not validate — that's deferred to `generate/2` or
an explicit `validate/1` call. This lets callers build up a
feed across multiple steps without paying validation cost on
each one.

## Parsing

The parser uses `:xmerl` by default and accepts a pluggable
backend via the `:xml_backend` option (mainly for tests).

Strict mode surfaces missing required fields and malformed
dates as `ParseError`s; lenient mode (the default) silently
drops them. Lenient is the right default because real-world
feeds frequently violate the spec, and refusing to parse them
would make the consumer useless.

CamelCase XML tag names are normalized to snake_case struct
fields via a compile-time map. For scalar elements the parser
uses `Map.put_new/3`, so the first occurrence of a duplicate
element wins. Extensions are keyed by namespace URI (not
prefix), so different prefixes pointing to the same namespace
collapse correctly.

## Generation

`Generator` builds the full XML document as iodata without
intermediate string concatenation, collapsing once at the end.
Text content is wrapped in `<![CDATA[...]]>` only when it
contains `<` or `&`; if the text itself contains `]]>`, the
generator falls back to entity escaping to keep the output
well-formed.

## Validation

`validate/1` returns `:ok` or `{:error, [ValidationError.t()]}`.
It is *not* fail-fast — all errors are reported at once. This
matters for editing workflows where a caller wants to see every
problem with a feed in one pass rather than playing
whack-a-mole. Checks cover required fields, URL formats,
numeric ranges, enumerated values, and duplicates.

## Dates

Date parsing tries four strategies in order: RFC 822, ISO 8601,
full month names (`"October 4, 2007"`), and Unix timestamps.
All parsed dates are normalized to UTC. The date module is
itself behind a behaviour (`Claptrap.RSS.DateBehaviour`) for
testability.

## Notes

- The parser converts input via `:binary.bin_to_list/1` rather
  than `String.to_charlist/1` to avoid xmerl rejecting
  codepoints above 127.
- Error types: `ParseError` (reason, line, column),
  `GenerateError` (reason, path), `ValidationError` (message,
  path, rule).
