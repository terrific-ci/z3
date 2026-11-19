# Zee3 documentation

The user documentation of Zee3, an S3-compatible object store in one binary, as a
[Mintlify](https://mintlify.com) site: guides, the `zee3 admin` command line and the HTTP APIs.

Binaries are published on this repository's [releases](https://github.com/terrific-ci/z3/releases)
and the image on Docker Hub as [`terrificci/zee3`](https://hub.docker.com/r/terrificci/zee3).

## Preview

```bash
npx mint dev            # http://localhost:3000
npx mint broken-links
```

## Layout

- `docs.json`: navigation, theme and links
- `index.mdx`, `get-started/`, `deploy/`, `durability/`, `replication/`, `storage/`, `access/`,
  `security/`, `events/`, `audit/`, `operations/`, `protocols/`: the Guide tab
- `cli/`: the CLI tab
- `api/`: the API tab
- `changelog.mdx`: the Changelog tab
- `images/`: console screenshots

Pages are MDX. Link between pages with root-relative paths without the extension
(`/storage/buckets`), and keep `<` and `{` inside backticks in prose.

## Contributing

Enable the repository's hooks once after cloning:

```bash
git config core.hooksPath .githooks
```
