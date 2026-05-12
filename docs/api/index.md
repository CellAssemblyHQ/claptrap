# API reference

Claptrap exposes a REST API at `/api/v1` for managing all catalog
resources. The full OpenAPI specification lives at
[`openapi/v1.json`](../openapi/v1.json).

## Base URL

```
https://docs.claptrap.dev/api/v1
```

## Resources

| Resource | Description |
| --- | --- |
| [Entries](../catalog/entries.md) | Normalized content records |
| [Sources](../catalog/sources.md) | Upstream content origins |
| [Sinks](../catalog/sinks.md) | Delivery targets |
| [Subscriptions](../catalog/subscriptions.md) | Tag-based routing rules |

## Response format

All responses are JSON. Successful responses return the resource or
list of resources directly. Error responses include a structured error
object.
