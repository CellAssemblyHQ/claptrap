# Entries

Normalized content entries, type system, timestamps, provenance,
deduplication, and typed payloads.

Entries are Claptrap's normalized representation of content discovered
from external systems. They are the durable content records persisted
by the Catalog and consumed by downstream subsystems.

An entry answers two questions:

- What content object does Claptrap believe this is?
- What stable metadata do other subsystems need to index, route,
  display, and process it?

## Resource shape

Every entry has:

- A stable Claptrap ID
- A `type` describing the content
- Provenance fields identifying where it came from
- Common metadata fields used across all content types
- Lifecycle timestamps
- An optional typed payload nested under `data`

```
Entry
├── common fields
├── provenance and identity
├── lifecycle timestamps
└── data
    └── exactly one typed payload matching entry.type
```

## Entry types

In v1, `entries.type` is constrained to:

| Type | Description |
| --- | --- |
| `:article` | Blog posts, essays, documentation, newsletters |
| `:video` | YouTube videos, Vimeo videos |
| `:podcast` | Podcast episodes with audio enclosures |
| `:book` | Goodreads books, Zotero book items |
| `:paper` | Journal articles, conference papers, preprints |

`type` describes **what the thing is**, not **how it arrived**. A
podcast episode discovered through RSS is still `:podcast`. A YouTube
recording of a podcast is still `:video`.

## Type resolution

Type is determined **per entry by the consumer adapter**, not per
source. A single source may emit multiple entry types.

### Protocol-specific resolution

- **RSS/Atom**: `<enclosure>` with audio MIME → `:podcast`, otherwise
  → `:article`
- **YouTube**: always `:video`
- **Zotero**: `journalArticle`/`conferencePaper` → `:paper`, `book` →
  `:book`
- **Webhook**: determined by payload structure or explicit type field
- **Goodreads**: always `:book`

When ambiguous, use the source protocol's native representation as the
tiebreaker. If the adapter cannot determine a type, default to
`:article`.

## Common fields

### Identity and provenance

| Field | Description |
| --- | --- |
| `id` | Claptrap-generated primary key |
| `type` | Normalized entry type enum |
| `source_id` | Claptrap ID of the source |
| `external_id` | Upstream identifier within the source's namespace |

### Cross-type metadata

| Field | Description |
| --- | --- |
| `title` | Primary display title |
| `summary` | Short normalized summary or abstract |
| `url` | Canonical destination URL |
| `author` | Primary author or creator |
| `language` | Normalized language tag |
| `image_url` | Primary representative image |
| `tags` | Normalized tag list for indexing and filtering |

## Timestamp semantics

Entries carry two classes of time information:

### Row lifecycle timestamps

| Timestamp | Meaning |
| --- | --- |
| `created_at` | When Claptrap first inserted the row (immutable) |
| `updated_at` | When Claptrap last modified the row |

### Content lifecycle timestamps

| Timestamp | Meaning |
| --- | --- |
| `ingested_at` | When Claptrap observed the item from a source |
| `published_at` | When upstream claims the content was published |

**Fallback rules:**
- If `published_at` is missing, fall back to `ingested_at`
- If upstream `published_at` is in the future, clamp to
  `DateTime.utc_now()` at consume time

## Deduplication

The v1 deduplication key is `(source_id, external_id)`.

- Same source + same external ID → duplicate, insert ignored
- Different source + same external ID → both records allowed

A unique index on `(source_id, external_id)` supports
`INSERT ... ON CONFLICT DO NOTHING`.

## Typed payloads

Entries may include an embedded `data` payload with type-specific
fields.

### Article payload

| Field | Type | Description |
| --- | --- | --- |
| `site_name` | string | Publication or site name |
| `byline` | string | Article-specific author line |
| `word_count` | integer | Approximate word count |
| `canonical_url` | string | Canonical URL if different from `url` |

### Video payload

| Field | Type | Description |
| --- | --- | --- |
| `platform` | string | Platform identifier (e.g., `"youtube"`) |
| `video_id` | string | Provider-specific video ID |
| `channel_id` | string | Upstream channel identifier |
| `channel_title` | string | Human-readable channel name |
| `duration_seconds` | integer | Normalized runtime in seconds |

### Podcast payload

| Field | Type | Description |
| --- | --- | --- |
| `podcast_title` | string | Show title |
| `episode_guid` | string | Episode GUID |
| `episode_number` | integer | Episode number |
| `season_number` | integer | Season number |
| `audio_url` | string | Canonical audio enclosure URL |
| `duration_seconds` | integer | Normalized runtime in seconds |

### Book payload

| Field | Type | Description |
| --- | --- | --- |
| `isbn10` | string | ISBN-10 |
| `isbn13` | string | ISBN-13 |
| `publisher` | string | Publisher name |
| `published_year` | integer | Year of publication |

### Paper payload

| Field | Type | Description |
| --- | --- | --- |
| `doi` | string | DOI |
| `arxiv_id` | string | arXiv identifier |
| `venue` | string | Conference, journal, or venue name |
| `pdf_url` | string | Direct PDF URL |

## Validation rules

### Required and structural

- `type` is required and must be a v1 enum value
- `data`, when present, must contain exactly one typed payload
- The typed payload must match `type`

### Identity

- `(source_id, external_id)` must be unique
- Enforced with a named unique index

### Timestamps

- `published_at` must not be in the future after normalization
- `ingested_at` should be set by the consume path, not trusted from
  upstream input
