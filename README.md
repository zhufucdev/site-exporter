# Site Exporter

A Prometheus exporter for my [personal site](https://github.com/zhufucdev/site)
written in Zig.

## Getting Started

Pass in `DB_URL` environment variable for PostgreSQL connection,
address and port for listening on.

```bash
DB_URL="postgresql://localhost/db" zig build run --release=fast 0.0.0.0 61239
```
