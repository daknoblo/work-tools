# work-tools

Personal collection of self-hosted work tools — container images, MCP servers,
and web applications — built here and published to GitHub Container Registry so
they can be run on my VPS with docker compose.

## Tools

| Tool | Image | Pipeline | Docs |
| --- | --- | --- | --- |
| Azure Architecture Diagram Builder | `ghcr.io/<owner>/azure-diagram-builder` | [tool-azure-diagram-builder.yml](.github/workflows/tool-azure-diagram-builder.yml) | [docs](tools/azure-diagram-builder/README.md) |

## Layout

```
.github/workflows/tool-<name>.yml   one build pipeline per tool
tools/<name>/docker-compose.yml     deployment unit for the VPS
tools/<name>/.env.example           runtime configuration template
tools/<name>/README.md              build, deploy and update instructions
```

## Conventions

Each tool is independent: one workflow, one compose file, one image. Nothing is
shared between tools, so a broken build never blocks another tool.

Every pipeline follows the same shape:

- named `tool - <name>`, file `tool-<name>.yml`, with `concurrency` on the workflow;
- triggered by `workflow_dispatch` (with an upstream ref input), a weekly
  `schedule`, and pushes that touch the tool's own files;
- builds from an upstream checkout when the tool is third-party, so no foreign
  source is vendored here;
- publishes `latest` plus an immutable tag identifying the exact source commit,
  so a deployment can be pinned and rolled back;
- pushes with SBOM, provenance, and a build provenance attestation;
- keeps build-time configuration in repository **variables** and runtime secrets
  out of the image entirely.

## Adding a tool

1. Copy `.github/workflows/tool-azure-diagram-builder.yml` and adjust
   `UPSTREAM_REPOSITORY`, `IMAGE_NAME`, the build context, and the build-time
   configuration step.
2. Add `tools/<name>/` with `docker-compose.yml`, `.env.example`, and a
   `README.md` covering configuration, deployment, and updates.
3. Add the tool to the table above.

## Updating a deployment

```bash
cd /opt/<name>
docker compose pull && docker compose up -d
```

Images are rebuilt weekly; run the workflow manually to publish an upstream
change right away.